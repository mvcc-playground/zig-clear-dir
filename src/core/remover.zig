const std = @import("std");
const builtin = @import("builtin");
const scanner = @import("scanner.zig");
const platform = @import("../platform/mod.zig");

pub const ApplyReport = struct {
    total_entries: usize,
    removed_entries: usize,
    failed_entries: usize,
    total_bytes: u64,
};

fn flushWriterIfSupported(writer: anytype) void {
    const T = @TypeOf(writer);
    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.size == .one and @hasDecl(ptr.child, "flush")) {
                writer.flush() catch {};
            }
        },
        else => {
            if (@hasDecl(T, "flush")) {
                writer.flush() catch {};
            }
        },
    }
}

pub fn applyEntries(
    writer: anytype,
    roots: []const []const u8,
    entries: []const scanner.MatchEntry,
    requested_total_bytes: u64,
    dry_run: bool,
    delete_workers: usize,
    progress: bool,
) !ApplyReport {
    const paths = try std.heap.page_allocator.alloc(scanner.MatchEntry, entries.len);
    defer std.heap.page_allocator.free(paths);

    @memcpy(paths, entries);

    std.sort.heap(scanner.MatchEntry, paths, {}, byPathDesc);

    for (paths) |entry| {
        try ensureSafePath(entry.path, roots);
    }

    if (dry_run) {
        for (paths) |entry| {
            try writer.print("[dry-run] would remove {s} ({d} bytes)\n", .{ entry.path, entry.bytes });
        }
        return .{
            .total_entries = entries.len,
            .removed_entries = entries.len,
            .failed_entries = 0,
            .total_bytes = requested_total_bytes,
        };
    }

    const worker_count = @min(paths.len, @max(@as(usize, 1), delete_workers));
    if (worker_count <= 1 or paths.len <= 1) {
        var removed_entries: usize = 0;
        var failed_entries: usize = 0;
        var removed_bytes: u64 = 0;
        for (paths) |entry| {
            platform.fs.deleteTree(entry.path) catch |err| {
                failed_entries += 1;
                if (progress) {
                    try writer.print("failed {d}/{d}: {s} ({s})\n", .{ removed_entries + failed_entries, paths.len, entry.path, @errorName(err) });
                    flushWriterIfSupported(writer);
                }
                continue;
            };
            removed_entries += 1;
            removed_bytes +|= entry.bytes;
            if (progress) {
                try writer.print("removed {d}/{d}: {s} ({d} bytes)\n", .{ removed_entries + failed_entries, paths.len, entry.path, entry.bytes });
                flushWriterIfSupported(writer);
            }
        }
        return .{
            .total_entries = entries.len,
            .removed_entries = removed_entries,
            .failed_entries = failed_entries,
            .total_bytes = removed_bytes,
        };
    }

    var pending = try std.heap.page_allocator.alloc(bool, paths.len);
    defer std.heap.page_allocator.free(pending);
    @memset(pending, true);

    var done_count: usize = 0;
    var removed_entries: usize = 0;
    var failed_entries: usize = 0;
    var removed_bytes: u64 = 0;
    while (done_count < paths.len) {
        var batch_indices = std.ArrayListUnmanaged(usize).empty;
        defer batch_indices.deinit(std.heap.page_allocator);
        try buildBatch(paths, pending, worker_count, &batch_indices);
        if (batch_indices.items.len == 0) return error.Unexpected;

        const BatchResult = struct {
            ok: bool = false,
            err: ?anyerror = null,
        };
        var batch_results = try std.heap.page_allocator.alloc(BatchResult, batch_indices.items.len);
        defer std.heap.page_allocator.free(batch_results);
        @memset(batch_results, .{});

        var pool: std.Thread.Pool = undefined;
        try pool.init(.{ .allocator = std.heap.page_allocator, .n_jobs = batch_indices.items.len });
        defer pool.deinit();
        var wg: std.Thread.WaitGroup = .{};
        for (batch_indices.items, 0..) |path_idx, i| {
            pool.spawnWg(&wg, struct {
                fn run(all_paths: []const scanner.MatchEntry, idx: usize, result_out: *BatchResult) void {
                    platform.fs.deleteTree(all_paths[idx].path) catch |err| {
                        result_out.err = err;
                        return;
                    };
                    result_out.ok = true;
                }
            }.run, .{ paths, path_idx, &batch_results[i] });
        }
        wg.wait();

        for (batch_indices.items, 0..) |path_idx, i| {
            if (batch_results[i].ok) {
                pending[path_idx] = false;
                done_count += 1;
                removed_entries += 1;
                removed_bytes +|= paths[path_idx].bytes;
                if (progress) {
                    try writer.print("removed {d}/{d}: {s} ({d} bytes)\n", .{ done_count, paths.len, paths[path_idx].path, paths[path_idx].bytes });
                    flushWriterIfSupported(writer);
                }
                continue;
            }

            if (batch_results[i].err) |err| {
                pending[path_idx] = false;
                done_count += 1;
                failed_entries += 1;
                if (progress) {
                    try writer.print("failed {d}/{d}: {s} ({s})\n", .{ done_count, paths.len, paths[path_idx].path, @errorName(err) });
                    flushWriterIfSupported(writer);
                }
                continue;
            }

            pending[path_idx] = false;
            done_count += 1;
            failed_entries += 1;
            if (progress) {
                try writer.print("failed {d}/{d}: {s} (Unknown)\n", .{ done_count, paths.len, paths[path_idx].path });
                flushWriterIfSupported(writer);
            }
        }
    }

    return .{
        .total_entries = entries.len,
        .removed_entries = removed_entries,
        .failed_entries = failed_entries,
        .total_bytes = removed_bytes,
    };
}

fn buildBatch(
    paths: []const scanner.MatchEntry,
    pending: []const bool,
    max_batch: usize,
    out: *std.ArrayListUnmanaged(usize),
) !void {
    for (paths, 0..) |entry, idx| {
        if (!pending[idx]) continue;

        var conflict = false;
        for (out.items) |already_idx| {
            if (pathsRelated(entry.path, paths[already_idx].path)) {
                conflict = true;
                break;
            }
        }
        if (conflict) continue;

        try out.append(std.heap.page_allocator, idx);
        if (out.items.len >= max_batch) break;
    }

    if (out.items.len == 0) {
        for (pending, 0..) |is_pending, idx| {
            if (is_pending) {
                try out.append(std.heap.page_allocator, idx);
                break;
            }
        }
    }
}

fn pathsRelated(a: []const u8, b: []const u8) bool {
    return isAncestorPath(a, b) or isAncestorPath(b, a);
}

fn isAncestorPath(ancestor: []const u8, child: []const u8) bool {
    if (builtin.os.tag == .windows) {
        if (!std.ascii.startsWithIgnoreCase(child, ancestor)) return false;
    } else {
        if (!std.mem.startsWith(u8, child, ancestor)) return false;
    }

    if (child.len == ancestor.len) return true;
    const next = child[ancestor.len];
    return next == std.fs.path.sep or next == '/' or next == '\\';
}

fn byPathDesc(_: void, a: scanner.MatchEntry, b: scanner.MatchEntry) bool {
    if (a.path.len != b.path.len) return a.path.len > b.path.len;
    return std.mem.lessThan(u8, b.path, a.path);
}

fn ensureSafePath(path: []const u8, roots: []const []const u8) !void {
    if (isDangerousRoot(path)) return error.RefusingRootDelete;

    for (roots) |root| {
        if (isUnderRoot(path, root)) return;
    }

    return error.PathOutsideRoots;
}

fn isUnderRoot(path: []const u8, root: []const u8) bool {
    if (builtin.os.tag == .windows) {
        if (!std.ascii.startsWithIgnoreCase(path, root)) return false;
    } else {
        if (!std.mem.startsWith(u8, path, root)) return false;
    }

    if (path.len == root.len) return true;

    const sep = std.fs.path.sep;
    const next = path[root.len];
    return next == sep or next == '/' or next == '\\';
}

fn isDangerousRoot(path: []const u8) bool {
    if (builtin.os.tag == .windows) {
        if (path.len == 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/')) {
            return true;
        }
        return false;
    }
    return std.mem.eql(u8, path, "/");
}

test "blocks root delete" {
    try std.testing.expectError(error.RefusingRootDelete, ensureSafePath(if (builtin.os.tag == .windows) "C:\\" else "/", &.{if (builtin.os.tag == .windows) "C:\\work" else "/tmp/work"}));
}

test "apply removes only selected entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("project/node_modules/deep");
    try tmp.dir.makePath("project/src");

    var f = try tmp.dir.createFile("project/node_modules/deep/a.txt", .{});
    f.close();

    const allocator = std.testing.allocator;
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);
    const entry_path = try std.fs.path.join(allocator, &.{ root, "project", "node_modules" });
    defer allocator.free(entry_path);

    const entries = [_]scanner.MatchEntry{
        .{ .path = entry_path, .bytes = 1 },
    };
    const roots = [_][]const u8{root};

    const Sink = struct {
        fn print(_: *@This(), comptime _: []const u8, _: anytype) !void {}
    };
    var sink: Sink = .{};

    const report = try applyEntries(&sink, &roots, &entries, 1, false, 1, false);
    try std.testing.expectEqual(@as(usize, 1), report.removed_entries);
    try std.testing.expectEqual(@as(usize, 0), report.failed_entries);
    try std.testing.expectEqual(@as(u64, 1), report.total_bytes);

    const maybe_dir = std.fs.cwd().openDir(entry_path, .{}) catch null;
    try std.testing.expect(maybe_dir == null);
}

test "apply rejects outside root before deleting anything" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("root/a/node_modules");
    try tmp.dir.makePath("outside/node_modules");
    var fa = try tmp.dir.createFile("root/a/node_modules/a.txt", .{});
    defer fa.close();
    try fa.writeAll("a");
    var fb = try tmp.dir.createFile("outside/node_modules/b.txt", .{});
    defer fb.close();
    try fb.writeAll("b");

    const allocator = std.testing.allocator;
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp.dir.realpath(".", &root_buf);
    const good = try std.fs.path.join(allocator, &.{ base, "root", "a", "node_modules" });
    defer allocator.free(good);
    const bad = try std.fs.path.join(allocator, &.{ base, "outside", "node_modules" });
    defer allocator.free(bad);
    const root_only = try std.fs.path.join(allocator, &.{ base, "root" });
    defer allocator.free(root_only);

    const entries = [_]scanner.MatchEntry{
        .{ .path = good, .bytes = 1 },
        .{ .path = bad, .bytes = 1 },
    };
    const roots = [_][]const u8{root_only};

    const Sink = struct {
        fn print(_: *@This(), comptime _: []const u8, _: anytype) !void {}
    };
    var sink: Sink = .{};

    try std.testing.expectError(
        error.PathOutsideRoots,
        applyEntries(&sink, &roots, &entries, 2, false, 2, false),
    );

    const still_good = std.fs.cwd().openDir(good, .{}) catch null;
    try std.testing.expect(still_good != null);
    if (still_good) |d| d.close();
}

test "apply continues after local failure and reports counts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("root/a/node_modules");
    try tmp.dir.makePath("root/b/target");

    var fa = try tmp.dir.createFile("root/a/node_modules/a.txt", .{});
    defer fa.close();
    try fa.writeAll("a");

    var fb = try tmp.dir.createFile("root/b/target/b.txt", .{});
    defer fb.close();
    try fb.writeAll("bb");

    const allocator = std.testing.allocator;
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp.dir.realpath(".", &root_buf);
    const root_only = try std.fs.path.join(allocator, &.{ base, "root" });
    defer allocator.free(root_only);
    const good = try std.fs.path.join(allocator, &.{ base, "root", "a", "node_modules" });
    defer allocator.free(good);
    const missing = try std.fs.path.join(allocator, &.{ base, "root", "missing", "target" });
    defer allocator.free(missing);

    const entries = [_]scanner.MatchEntry{
        .{ .path = good, .bytes = 1 },
        .{ .path = missing, .bytes = 10 },
    };
    const roots = [_][]const u8{root_only};

    const Sink = struct {
        fn print(_: *@This(), comptime _: []const u8, _: anytype) !void {}
    };
    var sink: Sink = .{};

    const report = try applyEntries(&sink, &roots, &entries, 11, false, 2, false);
    try std.testing.expectEqual(@as(usize, 1), report.removed_entries);
    try std.testing.expectEqual(@as(usize, 1), report.failed_entries);
    try std.testing.expectEqual(@as(u64, 1), report.total_bytes);
}
