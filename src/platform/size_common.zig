const std = @import("std");

const heartbeat_ms: i64 = 2000;

pub fn dirSizeExact(path: []const u8, progress: bool) !u64 {
    var stack: std.ArrayListUnmanaged(std.fs.Dir) = .empty;
    defer {
        for (stack.items) |*open_dir| open_dir.close();
        stack.deinit(std.heap.page_allocator);
    }

    const root_dir = std.fs.cwd().openDir(path, .{ .iterate = true, .access_sub_paths = true, .no_follow = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return 0,
        error.AccessDenied, error.PermissionDenied => return 0,
        else => return err,
    };
    try stack.append(std.heap.page_allocator, root_dir);

    var total: u64 = 0;
    var visited_dirs: usize = 0;
    var visited_files: usize = 0;
    const started_ms = std.time.milliTimestamp();
    var next_heartbeat = started_ms + heartbeat_ms;
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
                        const now = std.time.milliTimestamp();
                        if (now >= next_heartbeat) {
                            std.debug.print(
                                "progress: sizing working {s} (dirs {d}, files {d}, elapsed {d} ms)\n",
                                .{ path, visited_dirs, visited_files, now - started_ms },
                            );
                            next_heartbeat = now + heartbeat_ms;
                        }
                    }
                },
                else => {},
            }
        }
    }

    return total;
}
