const std = @import("std");
const builtin = @import("builtin");
const Rules = @import("rules.zig").Rules;
const platform = @import("../platform/mod.zig");
const discovery_report_interval: usize = 200;
const sizing_report_interval: usize = 10;

pub const MatchEntry = struct {
    path: []const u8,
    bytes: u64,
};

pub const ScanResult = struct {
    entries: []MatchEntry,
    total_bytes: u64,

    pub fn deinit(self: *ScanResult, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| allocator.free(entry.path);
        allocator.free(self.entries);
        self.* = undefined;
    }
};

pub fn scan(
    allocator: std.mem.Allocator,
    roots: []const []const u8,
    rules: Rules,
    workers: usize,
    progress: bool,
    with_size: bool,
) !ScanResult {
    const candidates = try collectCandidates(allocator, roots, rules, progress);
    errdefer {
        for (candidates) |path| allocator.free(path);
        allocator.free(candidates);
    }

    std.sort.heap([]const u8, candidates, {}, lessThanPath);

    if (progress) {
        std.debug.print("found candidates ({d}):\n", .{candidates.len});
        for (candidates) |path| {
            std.debug.print("  - {s}\n", .{path});
        }
        if (with_size and candidates.len > 0) {
            std.debug.print("progress: calculating sizes...\n", .{});
        }
    }
    if (!with_size) {
        const entries = try allocator.alloc(MatchEntry, candidates.len);
        for (candidates, 0..) |path, idx| {
            entries[idx] = .{ .path = path, .bytes = 0 };
        }
        allocator.free(candidates);
        return .{ .entries = entries, .total_bytes = 0 };
    }

    const sizes = try allocator.alloc(u64, candidates.len);
    defer allocator.free(sizes);
    @memset(sizes, 0);
    if (candidates.len > 0) {
        try measureSizes(allocator, candidates, sizes, workers, progress);
    }

    const entries = try allocator.alloc(MatchEntry, candidates.len);
    var total: u64 = 0;
    for (candidates, sizes, 0..) |path, bytes, idx| {
        entries[idx] = .{ .path = path, .bytes = bytes };
        total +|= bytes;
    }
    allocator.free(candidates);

    return .{ .entries = entries, .total_bytes = total };
}

fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn collectCandidates(allocator: std.mem.Allocator, roots: []const []const u8, rules: Rules, progress: bool) ![][]const u8 {
    var stack: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (stack.items) |path| allocator.free(path);
        stack.deinit(allocator);
    }

    var candidates: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (candidates.items) |path| allocator.free(path);
        candidates.deinit(allocator);
    }

    for (roots) |root| {
        try stack.append(allocator, try allocator.dupe(u8, root));
    }

    var scanned_dirs: usize = 0;
    var matched_dirs: usize = 0;

    while (stack.pop()) |current| {
        defer allocator.free(current);
        scanned_dirs += 1;
        if (progress and scanned_dirs % discovery_report_interval == 0) {
            std.debug.print("progress: scanned {d} dirs, matched {d}, queue {d}\n", .{ scanned_dirs, matched_dirs, stack.items.len });
        }

        var dir = platform.fs.openDir(current) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            error.AccessDenied, error.PermissionDenied => {
                std.log.warn("skip (no permission): {s}", .{current});
                continue;
            },
            else => return err,
        };
        defer dir.close();

        var it = dir.iterate();
        while (true) {
            const maybe_entry = it.next() catch |err| switch (err) {
                error.AccessDenied, error.PermissionDenied => {
                    std.log.warn("skip listing (no permission): {s}", .{current});
                    break;
                },
                else => return err,
            };
            const entry = maybe_entry orelse break;
            switch (entry.kind) {
                .directory => {
                    if (rules.shouldSkipDir(entry.name)) continue;

                    const child = try std.fs.path.join(allocator, &.{ current, entry.name });
                    if (shouldSkipWindowsHiddenOrSystem(child)) {
                        allocator.free(child);
                        continue;
                    }
                    if (rules.shouldMatchDir(entry.name)) {
                        try candidates.append(allocator, child);
                        matched_dirs += 1;
                    } else {
                        try stack.append(allocator, child);
                    }
                },
                .sym_link => continue,
                else => continue,
            }
        }
    }

    if (progress) {
        std.debug.print("progress: discovery complete (scanned {d} dirs, matched {d})\n", .{ scanned_dirs, matched_dirs });
    }

    return try candidates.toOwnedSlice(allocator);
}

const MeasureContext = struct {
    paths: []const []const u8,
    sizes: []u64,
    next_index: usize = 0,
    first_error: ?anyerror = null,
    completed: usize = 0,
    progress: bool = false,
    sub_workers: usize = 1,
    lock: std.Thread.Mutex = .{},
};

fn measureSizes(allocator: std.mem.Allocator, paths: []const []const u8, sizes: []u64, workers: usize, progress: bool) !void {
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator, .n_jobs = @max(@as(usize, 1), workers) });
    defer pool.deinit();

    var wg: std.Thread.WaitGroup = .{};
    var context = MeasureContext{ .paths = paths, .sizes = sizes, .progress = progress };

    const worker_count = @min(@max(@as(usize, 1), workers), paths.len);
    context.sub_workers = @max(@as(usize, 1), @divFloor(@max(@as(usize, 1), workers), worker_count));
    var i: usize = 0;
    while (i < worker_count) : (i += 1) {
        pool.spawnWg(&wg, measureWorker, .{&context});
    }

    wg.wait();

    if (context.first_error) |err| return err;
    if (progress and paths.len > 0) {
        std.debug.print("progress: sizing complete ({d}/{d})\n", .{ context.completed, paths.len });
    }
}

fn measureWorker(context: *MeasureContext) void {
    while (true) {
        const idx_opt = getNextIndex(context);
        if (idx_opt == null) return;

        const idx = idx_opt.?;
        const size = sizeOfDir(context.paths[idx], context.progress, context.sub_workers) catch |err| {
            context.lock.lock();
            defer context.lock.unlock();
            if (context.first_error == null) context.first_error = err;
            return;
        };
        context.lock.lock();
        context.sizes[idx] = size;
        context.completed += 1;
        const completed = context.completed;
        const total = context.paths.len;
        const should_report = context.progress and (completed % sizing_report_interval == 0 or completed == total);
        context.lock.unlock();

        if (should_report) {
            std.debug.print("progress: sizing {d}/{d}\n", .{ completed, total });
        }
    }
}

fn getNextIndex(context: *MeasureContext) ?usize {
    context.lock.lock();
    defer context.lock.unlock();

    if (context.first_error != null) return null;
    if (context.next_index >= context.paths.len) return null;

    const idx = context.next_index;
    context.next_index += 1;
    return idx;
}

fn sizeOfDir(path: []const u8, progress: bool, sub_workers: usize) !u64 {
    if (sub_workers <= 1) return sizeOfDirSequential(path, progress);

    var root = platform.fs.openDir(path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return 0,
        error.AccessDenied, error.PermissionDenied => return 0,
        else => return err,
    };
    defer root.close();

    var subdirs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (subdirs.items) |sub| std.heap.page_allocator.free(sub);
        subdirs.deinit(std.heap.page_allocator);
    }

    var base_total: u64 = 0;
    var it = root.iterate();
    while (true) {
        const maybe_entry = it.next() catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => break,
            else => return err,
        };
        const entry = maybe_entry orelse break;

        switch (entry.kind) {
            .directory => {
                const child = try std.fs.path.join(std.heap.page_allocator, &.{ path, entry.name });
                try subdirs.append(std.heap.page_allocator, child);
            },
            .sym_link => {},
            .file => {
                const stat = root.statFile(entry.name) catch |err| switch (err) {
                    error.AccessDenied, error.PermissionDenied, error.FileNotFound => continue,
                    else => continue,
                };
                base_total +|= stat.size;
            },
            else => {},
        }
    }

    if (subdirs.items.len == 0) return base_total;

    const LocalCtx = struct {
        paths: []const []const u8,
        next_index: usize = 0,
        first_error: ?anyerror = null,
        total: u64 = 0,
        completed: usize = 0,
        lock: std.Thread.Mutex = .{},
    };

    var local = LocalCtx{ .paths = subdirs.items };
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = std.heap.page_allocator, .n_jobs = sub_workers });
    defer pool.deinit();
    var wg: std.Thread.WaitGroup = .{};

    const local_workers = @min(sub_workers, subdirs.items.len);
    var wi: usize = 0;
    while (wi < local_workers) : (wi += 1) {
        pool.spawnWg(&wg, struct {
            fn run(ctx: *LocalCtx) void {
                while (true) {
                    ctx.lock.lock();
                    if (ctx.first_error != null or ctx.next_index >= ctx.paths.len) {
                        ctx.lock.unlock();
                        return;
                    }
                    const idx = ctx.next_index;
                    ctx.next_index += 1;
                    ctx.lock.unlock();

                    const sz = sizeOfDirSequential(ctx.paths[idx], false) catch |err| {
                        ctx.lock.lock();
                        if (ctx.first_error == null) ctx.first_error = err;
                        ctx.lock.unlock();
                        return;
                    };

                    ctx.lock.lock();
                    ctx.total +|= sz;
                    ctx.completed += 1;
                    ctx.lock.unlock();
                }
            }
        }.run, .{&local});
    }
    wg.wait();
    if (local.first_error) |err| return err;

    if (progress) {
        std.debug.print("progress: sized root subtree {s} ({d} chunks)\n", .{ path, local.completed });
    }

    return base_total +| local.total;
}

fn sizeOfDirSequential(path: []const u8, progress: bool) !u64 {
    var stack: std.ArrayListUnmanaged(std.fs.Dir) = .empty;
    defer {
        for (stack.items) |*open_dir| open_dir.close();
        stack.deinit(std.heap.page_allocator);
    }

    const root_dir = platform.fs.openDir(path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return 0,
        error.AccessDenied, error.PermissionDenied => return 0,
        else => return err,
    };
    try stack.append(std.heap.page_allocator, root_dir);

    var total: u64 = 0;
    var visited_dirs: usize = 0;
    var visited_files: usize = 0;
    var next_heartbeat_ms: i64 = std.time.milliTimestamp() + 2000;

    while (stack.pop()) |item| {
        var dir = item;
        defer dir.close();
        visited_dirs += 1;

        var it = dir.iterate();
        while (true) {
            const maybe_entry = it.next() catch |err| switch (err) {
                error.AccessDenied, error.PermissionDenied => break,
                else => return err,
            };
            const entry = maybe_entry orelse break;

            switch (entry.kind) {
                .directory => {
                    var child_dir = dir.openDir(entry.name, .{
                        .iterate = true,
                        .access_sub_paths = true,
                        .no_follow = true,
                    }) catch |err| switch (err) {
                        error.AccessDenied, error.PermissionDenied => continue,
                        error.FileNotFound, error.NotDir => continue,
                        else => return err,
                    };
                    stack.append(std.heap.page_allocator, child_dir) catch |err| {
                        child_dir.close();
                        return err;
                    };
                },
                .sym_link => {},
                .file => {
                    const stat = dir.statFile(entry.name) catch |err| switch (err) {
                        error.AccessDenied, error.PermissionDenied, error.FileNotFound => continue,
                        else => continue,
                    };
                    total +|= stat.size;
                    visited_files += 1;
                    if (progress) {
                        const now_ms = std.time.milliTimestamp();
                        if (now_ms >= next_heartbeat_ms) {
                            std.debug.print("progress: sizing working {s} (dirs {d}, files {d})\n", .{ path, visited_dirs, visited_files });
                            next_heartbeat_ms = now_ms + 2000;
                        }
                    }
                },
                else => {},
            }
        }
    }

    return total;
}

fn shouldSkipWindowsHiddenOrSystem(path: []const u8) bool {
    if (builtin.os.tag != .windows) return false;

    const attrs = std.os.windows.GetFileAttributes(path) catch return false;
    const hidden = attrs & std.os.windows.FILE_ATTRIBUTE_HIDDEN != 0;
    const system = attrs & std.os.windows.FILE_ATTRIBUTE_SYSTEM != 0;
    return hidden or system;
}

test "scan prunes matched dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("a/node_modules/deep");
    try tmp.dir.makePath("a/src");

    var file = try tmp.dir.createFile("a/node_modules/deep/x.txt", .{});
    file.close();

    var root_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_path = try tmp.dir.realpath(".", &root_path_buf);

    const allocator = std.testing.allocator;
    var rules = try Rules.init(allocator, &.{"node_modules"}, &.{});
    defer rules.deinit();

    var result = try scan(allocator, &.{root_path}, rules, 2, false, false);
    defer result.deinit(allocator);

    try std.testing.expect(result.entries.len == 1);
    try std.testing.expect(std.mem.endsWith(u8, result.entries[0].path, "node_modules"));
}
