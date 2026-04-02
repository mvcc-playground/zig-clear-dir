const std = @import("std");
const builtin = @import("builtin");

pub const ConfirmToken = "REMOVE";

pub const ScanOptions = struct {
    roots: [][]const u8,
    match_dirs: [][]const u8,
    skip_dirs: [][]const u8,
    snapshot_path: []const u8,
    workers: usize,

    pub fn deinit(self: *ScanOptions, allocator: std.mem.Allocator) void {
        freeStringSlice(allocator, self.roots);
        freeStringSlice(allocator, self.match_dirs);
        freeStringSlice(allocator, self.skip_dirs);
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
    scan: ScanOptions,
    apply: ApplyOptions,

    pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .scan => |*scan| scan.deinit(allocator),
            .apply => |*apply| apply.deinit(allocator),
        }
    }
};

pub const ParseError = error{ InvalidArgs, MissingValue };

pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !Command {
    if (args.len < 2) return error.InvalidArgs;

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "scan")) {
        return .{ .scan = try parseScan(allocator, args[2..]) };
    }
    if (std.mem.eql(u8, cmd, "apply")) {
        return .{ .apply = try parseApply(allocator, args[2..]) };
    }
    return error.InvalidArgs;
}

pub fn printUsage(writer: anytype) !void {
    try writer.print(
        \\rm-folders - safe directory cleanup
        \\Usage:
        \\  rm-folders scan --root <path> [--root <path> ...]
        \\      [--match-dir <name> ...] [--skip-dir <name> ...]
        \\      [--workers auto|N] [--snapshot <path>]
        \\
        \\  rm-folders apply --snapshot <path> --confirm REMOVE [--dry-run]
        \\
    , .{});
}

fn parseScan(allocator: std.mem.Allocator, raw: []const []const u8) !ScanOptions {
    var roots_list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer freeArrayListStrings(allocator, &roots_list);

    var match_list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer freeArrayListStrings(allocator, &match_list);

    var skip_list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer freeArrayListStrings(allocator, &skip_list);

    try appendDup(allocator, &match_list, "node_modules");
    try appendDup(allocator, &match_list, "target");

    const default_skip = [_][]const u8{ ".git", ".hg", ".svn", "System Volume Information", "$RECYCLE.BIN", ".zig-cache", "zig-out" };
    for (default_skip) |name| {
        try appendDup(allocator, &skip_list, name);
    }

    var snapshot_path: ?[]const u8 = null;
    errdefer if (snapshot_path) |p| allocator.free(p);

    var workers: usize = defaultWorkers();

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
            try appendDup(allocator, &match_list, raw[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--skip-dir")) {
            i += 1;
            if (i >= raw.len) return error.MissingValue;
            try appendDup(allocator, &skip_list, raw[i]);
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
            continue;
        }
        return error.InvalidArgs;
    }

    if (roots_list.items.len == 0) return error.InvalidArgs;

    if (snapshot_path == null) {
        const now = std.time.timestamp();
        const generated = try std.fmt.allocPrint(allocator, ".rm-folders/snapshots/{d}.json", .{now});
        defer allocator.free(generated);
        snapshot_path = try absolutePath(allocator, generated);
    }

    return .{
        .roots = try roots_list.toOwnedSlice(allocator),
        .match_dirs = try match_list.toOwnedSlice(allocator),
        .skip_dirs = try skip_list.toOwnedSlice(allocator),
        .snapshot_path = snapshot_path.?,
        .workers = workers,
    };
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

fn appendDup(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8), value: []const u8) !void {
    try list.append(allocator, try allocator.dupe(u8, value));
}

fn freeStringSlice(allocator: std.mem.Allocator, values: [][]const u8) void {
    for (values) |v| allocator.free(v);
    allocator.free(values);
}

fn freeArrayListStrings(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8)) void {
    for (list.items) |v| allocator.free(v);
    list.deinit(allocator);
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
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse apply" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "rm-folders", "apply", "--snapshot", "a.json", "--confirm", "REMOVE", "--dry-run" };
    var cmd = try parseArgs(allocator, &args);
    defer cmd.deinit(allocator);

    switch (cmd) {
        .apply => |apply| {
            try std.testing.expect(apply.dry_run);
            try std.testing.expectEqualStrings("REMOVE", apply.confirm);
        },
        else => return error.TestUnexpectedResult,
    }
}
