const std = @import("std");
const builtin = @import("builtin");
const defaults = @import("default_rules.zig");
const lists = @import("string_lists.zig");

pub const ConfirmToken = "REMOVE";

pub const ScanOptions = struct {
    roots: [][]const u8,
    match_dirs: [][]const u8,
    skip_dirs: [][]const u8,
    snapshot_path: []const u8,
    snapshot_explicit: bool,
    no_snapshot: bool,
    workers: usize,
    progress: bool,
    with_size: bool,

    pub fn deinit(self: *ScanOptions, allocator: std.mem.Allocator) void {
        lists.freeStringSlice(allocator, self.roots);
        lists.freeStringSlice(allocator, self.match_dirs);
        lists.freeStringSlice(allocator, self.skip_dirs);
        allocator.free(self.snapshot_path);
        self.* = undefined;
    }
};

pub const ApplyOptions = struct {
    snapshot_path: []const u8,
    confirm: []const u8,
    dry_run: bool,

    pub fn deinit(self: *ApplyOptions, allocator: std.mem.Allocator) void {
        allocator.free(self.snapshot_path);
        allocator.free(self.confirm);
        self.* = undefined;
    }
};

pub const Command = union(enum) {
    interactive: ScanOptions,

    pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .interactive => |*scan| scan.deinit(allocator),
        }
    }
};

pub const ParseError = error{ InvalidArgs, MissingValue };

pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !Command {
    if (args.len < 2) {
        return .{ .interactive = try parseInteractive(allocator, &.{}) };
    }
    return .{ .interactive = try parseInteractive(allocator, args[1..]) };
}

pub fn printUsage(writer: anytype) !void {
    try writer.print(
        \\rm-folders - safe directory cleanup
        \\Usage:
        \\  rm-folders [--dir <path>] [--path <path>] [scan options]
        \\      (default: scan + interactive delete prompt)
        \\      [--no-default-rules]
        \\
    , .{});
}

fn parseScan(allocator: std.mem.Allocator, raw: []const []const u8) !ScanOptions {
    var roots_list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer lists.freeArrayListStrings(allocator, &roots_list);

    var match_list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer lists.freeArrayListStrings(allocator, &match_list);

    var skip_list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer lists.freeArrayListStrings(allocator, &skip_list);

    const use_defaults = !lists.hasFlag(raw, "--no-default-rules");
    if (use_defaults) {
        for (defaults.match_dirs) |name| {
            try lists.appendDup(allocator, &match_list, name);
        }
        for (defaults.skip_dirs) |name| {
            try lists.appendDup(allocator, &skip_list, name);
        }
    }

    var snapshot_path: ?[]const u8 = null;
    errdefer if (snapshot_path) |p| allocator.free(p);

    var workers: usize = defaultWorkers();
    var progress = true;
    var with_size = false;
    var snapshot_explicit = false;
    var no_snapshot = false;

    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const arg = raw[i];
        if (std.mem.eql(u8, arg, "--root")) {
            i += 1;
            if (i >= raw.len) return error.MissingValue;
            const canonical = try canonicalizePath(allocator, raw[i]);
            try roots_list.append(allocator, canonical);
            continue;
        }
        if (std.mem.eql(u8, arg, "--match-dir")) {
            i += 1;
            if (i >= raw.len) return error.MissingValue;
            try lists.appendCsvOrSingle(allocator, &match_list, raw[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--skip-dir")) {
            i += 1;
            if (i >= raw.len) return error.MissingValue;
            try lists.appendCsvOrSingle(allocator, &skip_list, raw[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-default-rules")) {
            continue;
        }
        if (std.mem.eql(u8, arg, "--workers")) {
            i += 1;
            if (i >= raw.len) return error.MissingValue;
            if (std.mem.eql(u8, raw[i], "auto")) {
                workers = defaultWorkers();
            } else {
                workers = try std.fmt.parseInt(usize, raw[i], 10);
                workers = @max(@as(usize, 1), @min(workers, @as(usize, 128)));
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--snapshot")) {
            i += 1;
            if (i >= raw.len) return error.MissingValue;
            if (snapshot_path) |old| allocator.free(old);
            snapshot_path = try absolutePath(allocator, raw[i]);
            snapshot_explicit = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-snapshot")) {
            no_snapshot = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-progress")) {
            progress = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--with-size")) {
            with_size = true;
            continue;
        }
        return error.InvalidArgs;
    }

    if (roots_list.items.len == 0) return error.InvalidArgs;

    if (snapshot_path == null) {
        snapshot_path = try defaultSnapshotPath(allocator);
    }

    return .{
        .roots = try roots_list.toOwnedSlice(allocator),
        .match_dirs = try match_list.toOwnedSlice(allocator),
        .skip_dirs = try skip_list.toOwnedSlice(allocator),
        .snapshot_path = snapshot_path.?,
        .snapshot_explicit = snapshot_explicit,
        .no_snapshot = no_snapshot,
        .workers = workers,
        .progress = progress,
        .with_size = with_size,
    };
}

fn parseInteractive(allocator: std.mem.Allocator, raw: []const []const u8) !ScanOptions {
    var opts = try parseScan(allocator, &.{ "--root", "." });
    errdefer opts.deinit(allocator);

    lists.freeStringSlice(allocator, opts.roots);
    opts.roots = try allocator.alloc([]const u8, 0);

    var roots_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer roots_list.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const arg = raw[i];
        if (std.mem.eql(u8, arg, "--dir") or std.mem.eql(u8, arg, "--path")) {
            i += 1;
            if (i >= raw.len) return error.MissingValue;
            const canonical = try canonicalizePath(allocator, raw[i]);
            try roots_list.append(allocator, canonical);
            continue;
        }
        if (std.mem.eql(u8, arg, "--root")) {
            i += 1;
            if (i >= raw.len) return error.MissingValue;
            const canonical = try canonicalizePath(allocator, raw[i]);
            try roots_list.append(allocator, canonical);
            continue;
        }
        if (std.mem.eql(u8, arg, "--snapshot")) {
            i += 1;
            if (i >= raw.len) return error.MissingValue;
            allocator.free(opts.snapshot_path);
            opts.snapshot_path = try absolutePath(allocator, raw[i]);
            opts.snapshot_explicit = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-snapshot")) {
            opts.no_snapshot = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--workers")) {
            i += 1;
            if (i >= raw.len) return error.MissingValue;
            if (std.mem.eql(u8, raw[i], "auto")) {
                opts.workers = defaultWorkers();
            } else {
                opts.workers = try std.fmt.parseInt(usize, raw[i], 10);
                opts.workers = @max(@as(usize, 1), @min(opts.workers, @as(usize, 128)));
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--match-dir")) {
            i += 1;
            if (i >= raw.len) return error.MissingValue;
            opts.match_dirs = try lists.appendOwnedCsvOrSingle(allocator, opts.match_dirs, raw[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--skip-dir")) {
            i += 1;
            if (i >= raw.len) return error.MissingValue;
            opts.skip_dirs = try lists.appendOwnedCsvOrSingle(allocator, opts.skip_dirs, raw[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-default-rules")) {
            lists.freeStringSlice(allocator, opts.match_dirs);
            lists.freeStringSlice(allocator, opts.skip_dirs);
            opts.match_dirs = try allocator.alloc([]const u8, 0);
            opts.skip_dirs = try allocator.alloc([]const u8, 0);
            continue;
        }
        if (std.mem.eql(u8, arg, "--with-size")) {
            opts.with_size = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-progress")) {
            opts.progress = false;
            continue;
        }
        return error.InvalidArgs;
    }

    if (roots_list.items.len == 0) {
        try roots_list.append(allocator, try canonicalizePath(allocator, "."));
    }
    opts.roots = try roots_list.toOwnedSlice(allocator);

    return opts;
}

fn parseApply(allocator: std.mem.Allocator, raw: []const []const u8) !ApplyOptions {
    var snapshot_path: ?[]const u8 = null;
    errdefer if (snapshot_path) |p| allocator.free(p);

    var confirm: ?[]const u8 = null;
    errdefer if (confirm) |c| allocator.free(c);

    var dry_run = false;

    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const arg = raw[i];
        if (std.mem.eql(u8, arg, "--snapshot")) {
            i += 1;
            if (i >= raw.len) return error.MissingValue;
            if (snapshot_path) |old| allocator.free(old);
            snapshot_path = try absolutePath(allocator, raw[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--confirm")) {
            i += 1;
            if (i >= raw.len) return error.MissingValue;
            if (confirm) |old| allocator.free(old);
            confirm = try allocator.dupe(u8, raw[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
            continue;
        }
        return error.InvalidArgs;
    }

    if (snapshot_path == null or confirm == null) return error.InvalidArgs;

    return .{
        .snapshot_path = snapshot_path.?,
        .confirm = confirm.?,
        .dry_run = dry_run,
    };
}

fn defaultWorkers() usize {
    const cpu = std.Thread.getCpuCount() catch 1;
    return @max(@as(usize, 1), @min(cpu, @as(usize, 32)));
}

fn canonicalizePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return try std.fs.cwd().realpathAlloc(allocator, path);
}

fn absolutePath(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(input)) return try allocator.dupe(u8, input);

    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    return try std.fs.path.join(allocator, &.{ cwd, input });
}

fn defaultSnapshotPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = try resolveHomeDir(allocator);
    defer allocator.free(home);
    const now = std.time.timestamp();
    const filename = try std.fmt.allocPrint(allocator, "{d}.json", .{now});
    defer allocator.free(filename);
    return try std.fs.path.join(allocator, &.{ home, ".rm-folders", "snapshots", filename });
}

fn resolveHomeDir(allocator: std.mem.Allocator) ![]const u8 {
    return std.process.getEnvVarOwned(allocator, "HOME") catch |home_err| switch (home_err) {
        error.EnvironmentVariableNotFound => {
            return std.process.getEnvVarOwned(allocator, "USERPROFILE") catch |up_err| switch (up_err) {
                error.EnvironmentVariableNotFound => blk: {
                    const drive = try std.process.getEnvVarOwned(allocator, "HOMEDRIVE");
                    defer allocator.free(drive);
                    const path = try std.process.getEnvVarOwned(allocator, "HOMEPATH");
                    defer allocator.free(path);
                    break :blk try std.fs.path.join(allocator, &.{ drive, path });
                },
                else => |e| return e,
            };
        },
        else => |e| return e,
    };
}

test "parse scan with defaults" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "rm-folders", "scan", "--root", "." };
    var cmd = try parseArgs(allocator, &args);
    defer cmd.deinit(allocator);

    switch (cmd) {
        .scan => |scan| {
            try std.testing.expect(scan.roots.len == 1);
            try std.testing.expect(scan.match_dirs.len >= 2);
            try std.testing.expect(scan.skip_dirs.len >= 3);
            try std.testing.expect(scan.workers >= 1);
            try std.testing.expect(scan.progress);
            try std.testing.expect(!scan.with_size);
            try std.testing.expect(!scan.snapshot_explicit);
            try std.testing.expect(!scan.no_snapshot);
            try std.testing.expect(scan.match_dirs.len >= 2);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse defaults to interactive with current directory" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{"rm-folders"};
    var cmd = try parseArgs(allocator, &args);
    defer cmd.deinit(allocator);

    switch (cmd) {
        .interactive => |scan| {
            try std.testing.expect(scan.roots.len == 1);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse scan with no default rules and csv args" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{
        "rm-folders",
        "--dir",
        ".",
        "--no-default-rules",
        "--match-dir",
        "dist,build",
        "--skip-dir",
        ".cache,temp",
    };
    var cmd = try parseArgs(allocator, &args);
    defer cmd.deinit(allocator);

    switch (cmd) {
        .interactive => |scan| {
            try std.testing.expectEqual(@as(usize, 2), scan.match_dirs.len);
            try std.testing.expectEqual(@as(usize, 2), scan.skip_dirs.len);
            try std.testing.expectEqualStrings("dist", scan.match_dirs[0]);
            try std.testing.expectEqualStrings("build", scan.match_dirs[1]);
            try std.testing.expectEqualStrings(".cache", scan.skip_dirs[0]);
            try std.testing.expectEqualStrings("temp", scan.skip_dirs[1]);
        },
    }
}
