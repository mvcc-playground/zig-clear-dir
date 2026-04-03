const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const snapshot = @import("snapshot.zig");
const platform = @import("../platform/mod.zig");

pub const ApplyReport = struct {
    total_entries: usize,
    removed_entries: usize,
    total_bytes: u64,
};

pub fn applySnapshot(writer: anytype, opts: config.ApplyOptions, data: *const snapshot.SnapshotFile) !ApplyReport {
    if (!std.mem.eql(u8, opts.confirm, config.ConfirmToken)) {
        return error.InvalidConfirmationToken;
    }

    return applyEntries(writer, data.roots, data.entries, data.total_bytes, opts.dry_run);
}

pub fn applyEntries(
    writer: anytype,
    roots: []const []const u8,
    entries: []const snapshot.SnapshotEntry,
    total_bytes: u64,
    dry_run: bool,
) !ApplyReport {
    const paths = try std.heap.page_allocator.alloc(snapshot.SnapshotEntry, entries.len);
    defer std.heap.page_allocator.free(paths);

    @memcpy(paths, entries);

    std.sort.heap(snapshot.SnapshotEntry, paths, {}, byPathDesc);

    var removed: usize = 0;

    for (paths) |entry| {
        try ensureSafePath(entry.path, roots);

        if (dry_run) {
            try writer.print("[dry-run] would remove {s} ({d} bytes)\n", .{ entry.path, entry.bytes });
            removed += 1;
            continue;
        }

        try platform.fs.deleteTree(entry.path);

        removed += 1;
        try writer.print("removed {s} ({d} bytes)\n", .{ entry.path, entry.bytes });
    }

    return .{
        .total_entries = entries.len,
        .removed_entries = removed,
        .total_bytes = total_bytes,
    };
}

fn byPathDesc(_: void, a: snapshot.SnapshotEntry, b: snapshot.SnapshotEntry) bool {
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

test "apply removes only snapshot entries" {
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

    const local_confirm = try allocator.dupe(u8, config.ConfirmToken);
    defer allocator.free(local_confirm);
    const local_snapshot = try allocator.dupe(u8, "unused");
    defer allocator.free(local_snapshot);

    const entries = [_]snapshot.SnapshotEntry{
        .{ .path = entry_path, .bytes = 1 },
    };
    const roots = [_][]const u8{root};
    const data = snapshot.SnapshotFile{
        .version = snapshot.Version,
        .created_unix = std.time.timestamp(),
        .roots = @constCast(&roots),
        .match_dirs = @constCast(&[_][]const u8{"node_modules"}),
        .skip_dirs = @constCast(&[_][]const u8{".git"}),
        .total_bytes = 1,
        .entries = @constCast(&entries),
        .hash = "unused",
    };

    const Sink = struct {
        fn print(_: *@This(), comptime _: []const u8, _: anytype) !void {}
    };
    var sink: Sink = .{};

    const report = try applySnapshot(&sink, .{
        .snapshot_path = local_snapshot,
        .confirm = local_confirm,
        .dry_run = false,
    }, &data);
    try std.testing.expectEqual(@as(usize, 1), report.removed_entries);

    const maybe_dir = std.fs.cwd().openDir(entry_path, .{}) catch null;
    try std.testing.expect(maybe_dir == null);
}
