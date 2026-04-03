const std = @import("std");

pub fn dirSize(path: []const u8, progress: bool, sub_workers: usize) !u64 {
    if (sub_workers <= 1) return dirSizeSequential(path, progress);

    var root = std.fs.cwd().openDir(path, .{ .iterate = true, .access_sub_paths = true, .no_follow = true }) catch |err| switch (err) {
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

                    const sz = dirSizeSequential(ctx.paths[idx], false) catch |err| {
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

fn dirSizeSequential(path: []const u8, progress: bool) !u64 {
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
