const std = @import("std");
const Rules = @import("rules.zig").Rules;
const platform = @import("../platform/mod.zig");

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

pub fn scan(allocator: std.mem.Allocator, roots: []const []const u8, rules: Rules, workers: usize) !ScanResult {
    const candidates = try collectCandidates(allocator, roots, rules);
    errdefer {
        for (candidates) |path| allocator.free(path);
        allocator.free(candidates);
    }

    std.sort.heap([]const u8, candidates, {}, lessThanPath);

    const sizes = try allocator.alloc(u64, candidates.len);
    defer allocator.free(sizes);

    @memset(sizes, 0);

    if (candidates.len > 0) {
        try measureSizes(allocator, candidates, sizes, workers);
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

fn collectCandidates(allocator: std.mem.Allocator, roots: []const []const u8, rules: Rules) ![][]const u8 {
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

    while (stack.pop()) |current| {
        defer allocator.free(current);

        var dir = platform.fs.openDir(current) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => return err,
        };
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            switch (entry.kind) {
                .directory => {
                    if (rules.shouldSkipDir(entry.name)) continue;

                    const child = try std.fs.path.join(allocator, &.{ current, entry.name });
                    if (rules.shouldMatchDir(entry.name)) {
                        try candidates.append(allocator, child);
                    } else {
                        try stack.append(allocator, child);
                    }
                },
                .sym_link => continue,
                else => continue,
            }
        }
    }

    return try candidates.toOwnedSlice(allocator);
}

const MeasureContext = struct {
    paths: []const []const u8,
    sizes: []u64,
    next_index: usize = 0,
    first_error: ?anyerror = null,
    lock: std.Thread.Mutex = .{},
};

fn measureSizes(allocator: std.mem.Allocator, paths: []const []const u8, sizes: []u64, workers: usize) !void {
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator, .n_jobs = @max(@as(usize, 1), workers) });
    defer pool.deinit();

    var wg: std.Thread.WaitGroup = .{};
    var context = MeasureContext{ .paths = paths, .sizes = sizes };

    const worker_count = @min(@max(@as(usize, 1), workers), paths.len);
    var i: usize = 0;
    while (i < worker_count) : (i += 1) {
        pool.spawnWg(&wg, measureWorker, .{&context});
    }

    wg.wait();

    if (context.first_error) |err| return err;
}

fn measureWorker(context: *MeasureContext) void {
    while (true) {
        const idx_opt = getNextIndex(context);
        if (idx_opt == null) return;

        const idx = idx_opt.?;
        const size = sizeOfDir(context.paths[idx]) catch |err| {
            context.lock.lock();
            defer context.lock.unlock();
            if (context.first_error == null) context.first_error = err;
            return;
        };
        context.sizes[idx] = size;
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

fn sizeOfDir(path: []const u8) !u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stack: std.ArrayListUnmanaged([]const u8) = .empty;
    defer stack.deinit(allocator);

    try stack.append(allocator, try allocator.dupe(u8, path));

    var total: u64 = 0;

    while (stack.pop()) |current| {
        var dir = platform.fs.openDir(current) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => return err,
        };
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            const child = try std.fs.path.join(allocator, &.{ current, entry.name });

            switch (entry.kind) {
                .directory => {
                    try stack.append(allocator, child);
                },
                .sym_link => {},
                else => {
                    const stat = std.fs.cwd().statFile(child) catch continue;
                    total +|= stat.size;
                },
            }
        }
    }

    return total;
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

    var result = try scan(allocator, &.{root_path}, rules, 2);
    defer result.deinit(allocator);

    try std.testing.expect(result.entries.len == 1);
    try std.testing.expect(std.mem.endsWith(u8, result.entries[0].path, "node_modules"));
}
