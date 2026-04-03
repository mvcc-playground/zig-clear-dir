const std = @import("std");
const windows = std.os.windows;

pub fn dirSizeExact(path: []const u8, progress: bool) !u64 {
    return dirSizeExactWindows(path, progress);
}

const kernel32 = windows.kernel32;
const FindExInfoBasic: u32 = 1;
const FindExSearchNameMatch: u32 = 0;
const FIND_FIRST_EX_LARGE_FETCH: u32 = 2;
const heartbeat_ms: i64 = 2000;

extern "kernel32" fn FindFirstFileExW(
    lpFileName: [*:0]const u16,
    fInfoLevelId: u32,
    lpFindFileData: *windows.WIN32_FIND_DATAW,
    fSearchOp: u32,
    lpSearchFilter: ?*anyopaque,
    dwAdditionalFlags: u32,
) callconv(.winapi) windows.HANDLE;

extern "kernel32" fn FindNextFileW(
    hFindFile: windows.HANDLE,
    lpFindFileData: *windows.WIN32_FIND_DATAW,
) callconv(.winapi) windows.BOOL;

const DirFrame = struct {
    handle: windows.HANDLE,
    dir_len: usize,
    find_data: windows.WIN32_FIND_DATAW,
    has_pending: bool,
};

const Scratch = struct {
    allocator: std.mem.Allocator,
    current_path: std.ArrayList(u16),
    search_path: std.ArrayList(u16),
    stack: std.ArrayListUnmanaged(DirFrame) = .empty,

    fn init(allocator: std.mem.Allocator) Scratch {
        return .{
            .allocator = allocator,
            .current_path = .empty,
            .search_path = .empty,
        };
    }

    fn deinit(self: *Scratch) void {
        for (self.stack.items) |frame| {
            _ = kernel32.FindClose(frame.handle);
        }
        self.stack.deinit(self.allocator);
        self.current_path.deinit(self.allocator);
        self.search_path.deinit(self.allocator);
    }
};

fn dirSizeExactWindows(path: []const u8, progress: bool) !u64 {
    var scratch = Scratch.init(std.heap.page_allocator);
    defer scratch.deinit();

    const root_w = try windows.sliceToPrefixedFileW(null, path);
    try scratch.current_path.appendSlice(scratch.allocator, root_w.span());

    const root_find = openDirectory(&scratch, scratch.current_path.items) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return 0,
        else => return err,
    };
    try scratch.stack.append(scratch.allocator, .{
        .handle = root_find.handle,
        .dir_len = scratch.current_path.items.len,
        .find_data = root_find.find_data,
        .has_pending = true,
    });

    var total: u64 = 0;
    var visited_dirs: usize = 1;
    var visited_files: usize = 0;
    const started_ms = std.time.milliTimestamp();
    var next_heartbeat: i64 = started_ms + heartbeat_ms;

    while (scratch.stack.items.len > 0) {
        var frame = &scratch.stack.items[scratch.stack.items.len - 1];
        var find_data: windows.WIN32_FIND_DATAW = undefined;

        if (frame.has_pending) {
            find_data = frame.find_data;
            frame.has_pending = false;
        } else {
            if (FindNextFileW(frame.handle, &find_data) == windows.FALSE) {
                switch (windows.GetLastError()) {
                    .NO_MORE_FILES, .ACCESS_DENIED => {
                        _ = kernel32.FindClose(frame.handle);
                        _ = scratch.stack.pop();
                        if (scratch.stack.items.len > 0) {
                            scratch.current_path.shrinkRetainingCapacity(scratch.stack.items[scratch.stack.items.len - 1].dir_len);
                        }
                        continue;
                    },
                    else => |err| return windows.unexpectedError(err),
                }
            }
        }

        const name_w = sliceWtf16Z(&find_data.cFileName);
        if (isDot(name_w)) continue;

        const attrs = find_data.dwFileAttributes;
        const is_dir = attrs & windows.FILE_ATTRIBUTE_DIRECTORY != 0;
        const is_reparse = attrs & windows.FILE_ATTRIBUTE_REPARSE_POINT != 0;

        if (is_dir) {
            if (is_reparse) continue;

            const parent_len = scratch.current_path.items.len;
            try appendChildPath(&scratch.current_path, scratch.allocator, name_w);

            const child_find = openDirectory(&scratch, scratch.current_path.items) catch |err| switch (err) {
                error.FileNotFound, error.NotDir, error.AccessDenied => {
                    scratch.current_path.shrinkRetainingCapacity(parent_len);
                    continue;
                },
                else => return err,
            };
            visited_dirs += 1;
            try scratch.stack.append(scratch.allocator, .{
                .handle = child_find.handle,
                .dir_len = scratch.current_path.items.len,
                .find_data = child_find.find_data,
                .has_pending = true,
            });
            continue;
        }

        if (!is_reparse) {
            total +|= combineFileSize(find_data);
            visited_files += 1;
        }

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
    }

    return total;
}

const OpenedDir = struct {
    handle: windows.HANDLE,
    find_data: windows.WIN32_FIND_DATAW,
};

fn openDirectory(scratch: *Scratch, dir_path: []const u16) !OpenedDir {
    scratch.search_path.clearRetainingCapacity();
    try scratch.search_path.appendSlice(scratch.allocator, dir_path);
    if (scratch.search_path.items.len == 0 or scratch.search_path.items[scratch.search_path.items.len - 1] != '\\') {
        try scratch.search_path.append(scratch.allocator, '\\');
    }
    try scratch.search_path.append(scratch.allocator, '*');
    try scratch.search_path.append(scratch.allocator, 0);

    var find_data: windows.WIN32_FIND_DATAW = undefined;
    const handle = FindFirstFileExW(
        @ptrCast(scratch.search_path.items.ptr),
        FindExInfoBasic,
        &find_data,
        FindExSearchNameMatch,
        null,
        FIND_FIRST_EX_LARGE_FETCH,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) {
        return switch (windows.GetLastError()) {
            .FILE_NOT_FOUND => error.FileNotFound,
            .PATH_NOT_FOUND => error.NotDir,
            .ACCESS_DENIED => error.AccessDenied,
            else => |err| windows.unexpectedError(err),
        };
    }

    return .{ .handle = handle, .find_data = find_data };
}

fn appendChildPath(buf: *std.ArrayList(u16), allocator: std.mem.Allocator, child_name: []const u16) !void {
    if (buf.items.len == 0 or buf.items[buf.items.len - 1] != '\\') {
        try buf.append(allocator, '\\');
    }
    try buf.appendSlice(allocator, child_name);
}

fn combineFileSize(find_data: windows.WIN32_FIND_DATAW) u64 {
    const high: u64 = @as(u64, find_data.nFileSizeHigh);
    const low: u64 = @as(u64, find_data.nFileSizeLow);
    return (high << 32) | low;
}

fn sliceWtf16Z(buf: []const u16) []const u16 {
    var len: usize = 0;
    while (len < buf.len and buf[len] != 0) : (len += 1) {}
    return buf[0..len];
}

fn isDot(name: []const u16) bool {
    return (name.len == 1 and name[0] == '.') or
        (name.len == 2 and name[0] == '.' and name[1] == '.');
}
