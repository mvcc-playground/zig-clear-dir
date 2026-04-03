const std = @import("std");
const builtin = @import("builtin");
const defaults = @import("default_rules.zig");
const lists = @import("string_lists.zig");

pub const SizeMode = enum {
    approx,
    exact,
    hybrid,
};

pub const ScanOptions = struct {
    roots: [][]const u8,
    match_dirs: [][]const u8,
    skip_dirs: [][]const u8,
    skip_path_regexes: [][]const u8,
    skip_dot_dirs: bool,
    workers: usize,
    delete_workers: usize,
    progress: bool,
    with_size: bool,
    size_mode: SizeMode,

    pub fn deinit(self: *ScanOptions, allocator: std.mem.Allocator) void {
        lists.freeStringSlice(allocator, self.roots);
        lists.freeStringSlice(allocator, self.match_dirs);
        lists.freeStringSlice(allocator, self.skip_dirs);
        lists.freeStringSlice(allocator, self.skip_path_regexes);
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
        \\      [--skip-path-regex <pattern>] [--no-skip-dot-dirs]
        \\      [--workers auto|N] [--delete-workers auto|N]
        \\      [--with-size] [--size-mode approx|exact|hybrid]
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
    var skip_regex_list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer lists.freeArrayListStrings(allocator, &skip_regex_list);

    const use_defaults = !lists.hasFlag(raw, "--no-default-rules");
    var skip_dot_dirs = defaults.skip_dot_dirs;
    if (use_defaults) {
        for (defaults.match_dirs) |name| {
            try lists.appendDup(allocator, &match_list, name);
        }
        for (defaults.skip_dirs) |name| {
            try lists.appendDup(allocator, &skip_list, name);
        }
        for (defaults.skip_path_regexes) |regex| {
            try lists.appendDup(allocator, &skip_regex_list, regex);
        }
    }

    var workers: usize = defaultWorkers();
    var delete_workers: usize = defaultDeleteWorkers();
    var progress = true;
    var with_size = false;
    var size_mode: SizeMode = .approx;

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
        if (std.mem.eql(u8, arg, "--skip-path-regex")) {
            i += 1;
            if (i >= raw.len) return error.MissingValue;
            try lists.appendCsvOrSingle(allocator, &skip_regex_list, raw[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-skip-dot-dirs")) {
            skip_dot_dirs = false;
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
        if (std.mem.eql(u8, arg, "--delete-workers")) {
            i += 1;
            if (i >= raw.len) return error.MissingValue;
            if (std.mem.eql(u8, raw[i], "auto")) {
                delete_workers = defaultDeleteWorkers();
            } else {
                delete_workers = try std.fmt.parseInt(usize, raw[i], 10);
                delete_workers = @max(@as(usize, 1), @min(delete_workers, @as(usize, 32)));
            }
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
        if (std.mem.eql(u8, arg, "--size-mode")) {
            i += 1;
            if (i >= raw.len) return error.MissingValue;
            size_mode = parseSizeMode(raw[i]) orelse return error.InvalidArgs;
            continue;
        }
        return error.InvalidArgs;
    }

    if (roots_list.items.len == 0) return error.InvalidArgs;

    return .{
        .roots = try roots_list.toOwnedSlice(allocator),
        .match_dirs = try match_list.toOwnedSlice(allocator),
        .skip_dirs = try skip_list.toOwnedSlice(allocator),
        .skip_path_regexes = try skip_regex_list.toOwnedSlice(allocator),
        .skip_dot_dirs = skip_dot_dirs,
        .workers = workers,
        .delete_workers = delete_workers,
        .progress = progress,
        .with_size = with_size,
        .size_mode = size_mode,
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
        if (std.mem.eql(u8, arg, "--delete-workers")) {
            i += 1;
            if (i >= raw.len) return error.MissingValue;
            if (std.mem.eql(u8, raw[i], "auto")) {
                opts.delete_workers = defaultDeleteWorkers();
            } else {
                opts.delete_workers = try std.fmt.parseInt(usize, raw[i], 10);
                opts.delete_workers = @max(@as(usize, 1), @min(opts.delete_workers, @as(usize, 32)));
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
        if (std.mem.eql(u8, arg, "--skip-path-regex")) {
            i += 1;
            if (i >= raw.len) return error.MissingValue;
            opts.skip_path_regexes = try lists.appendOwnedCsvOrSingle(allocator, opts.skip_path_regexes, raw[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-skip-dot-dirs")) {
            opts.skip_dot_dirs = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-default-rules")) {
            lists.freeStringSlice(allocator, opts.match_dirs);
            lists.freeStringSlice(allocator, opts.skip_dirs);
            lists.freeStringSlice(allocator, opts.skip_path_regexes);
            opts.match_dirs = try allocator.alloc([]const u8, 0);
            opts.skip_dirs = try allocator.alloc([]const u8, 0);
            opts.skip_path_regexes = try allocator.alloc([]const u8, 0);
            continue;
        }
        if (std.mem.eql(u8, arg, "--with-size")) {
            opts.with_size = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--size-mode")) {
            i += 1;
            if (i >= raw.len) return error.MissingValue;
            opts.size_mode = parseSizeMode(raw[i]) orelse return error.InvalidArgs;
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

fn parseSizeMode(raw: []const u8) ?SizeMode {
    if (std.ascii.eqlIgnoreCase(raw, "approx")) return .approx;
    if (std.ascii.eqlIgnoreCase(raw, "exact")) return .exact;
    if (std.ascii.eqlIgnoreCase(raw, "hybrid")) return .hybrid;
    return null;
}

fn defaultWorkers() usize {
    const cpu = std.Thread.getCpuCount() catch 1;
    return @max(@as(usize, 1), @min(cpu, @as(usize, 32)));
}

fn defaultDeleteWorkers() usize {
    if (builtin.os.tag == .windows) return 2;
    return 4;
}

fn canonicalizePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return try std.fs.cwd().realpathAlloc(allocator, path);
}


test "parse scan with defaults" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "rm-folders", "--root", "." };
    var cmd = try parseArgs(allocator, &args);
    defer cmd.deinit(allocator);

    switch (cmd) {
        .interactive => |scan| {
            try std.testing.expect(scan.roots.len == 1);
            try std.testing.expect(scan.match_dirs.len >= 2);
            try std.testing.expect(scan.skip_dirs.len >= 3);
            try std.testing.expect(scan.workers >= 1);
            try std.testing.expect(scan.delete_workers >= 1);
            try std.testing.expect(scan.progress);
            try std.testing.expect(!scan.with_size);
            try std.testing.expect(scan.size_mode == .approx);
            try std.testing.expect(scan.match_dirs.len >= 2);
            try std.testing.expect(scan.skip_dot_dirs);
        },
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
            try std.testing.expect(scan.size_mode == .approx);
        },
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
            try std.testing.expectEqual(@as(usize, 0), scan.skip_path_regexes.len);
            try std.testing.expect(scan.skip_dot_dirs);
        },
    }
}

test "parse skip path regex and no skip dot dirs" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{
        "rm-folders",
        "--dir",
        ".",
        "--skip-path-regex",
        ".*/\\..*,.*cache.*",
        "--no-skip-dot-dirs",
    };
    var cmd = try parseArgs(allocator, &args);
    defer cmd.deinit(allocator);

    switch (cmd) {
        .interactive => |scan| {
            try std.testing.expectEqual(@as(usize, 2), scan.skip_path_regexes.len);
            try std.testing.expectEqualStrings(".*/\\..*", scan.skip_path_regexes[0]);
            try std.testing.expectEqualStrings(".*cache.*", scan.skip_path_regexes[1]);
            try std.testing.expect(!scan.skip_dot_dirs);
        },
    }
}

test "parse with-size and explicit size-mode" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{
        "rm-folders",
        "--dir",
        ".",
        "--with-size",
        "--size-mode",
        "exact",
    };
    var cmd = try parseArgs(allocator, &args);
    defer cmd.deinit(allocator);

    switch (cmd) {
        .interactive => |scan| {
            try std.testing.expect(scan.with_size);
            try std.testing.expect(scan.size_mode == .exact);
        },
    }
}

test "parse explicit delete-workers" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{
        "rm-folders",
        "--dir",
        ".",
        "--delete-workers",
        "7",
    };
    var cmd = try parseArgs(allocator, &args);
    defer cmd.deinit(allocator);

    switch (cmd) {
        .interactive => |scan| {
            try std.testing.expectEqual(@as(usize, 7), scan.delete_workers);
        },
    }
}

test "parse rejects legacy snapshot flags" {
    const allocator = std.testing.allocator;
    const bad1 = [_][]const u8{ "rm-folders", "--dir", ".", "--snapshot", "x.json" };
    try std.testing.expectError(error.InvalidArgs, parseArgs(allocator, &bad1));

    const bad2 = [_][]const u8{ "rm-folders", "--dir", ".", "--no-snapshot" };
    try std.testing.expectError(error.InvalidArgs, parseArgs(allocator, &bad2));
}
