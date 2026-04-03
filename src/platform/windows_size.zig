const std = @import("std");
const windows = std.os.windows;
const kernel32 = windows.kernel32;
const common = @import("size_common.zig");

pub const approx_is_estimated: bool = true;

pub fn dirSizeApprox(path: []const u8) !u64 {
    return dirSizeApproxWindows(path);
}

pub fn dirSizeExact(path: []const u8) !u64 {
    return common.dirSizeExact(path);
}

const FindExInfoBasic: u32 = 1;
const FindExSearchNameMatch: u32 = 0;
const FIND_FIRST_EX_LARGE_FETCH: u32 = 2;

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

fn dirSizeApproxWindows(path: []const u8) !u64 {
    var stack: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (stack.items) |item| std.heap.page_allocator.free(item);
        stack.deinit(std.heap.page_allocator);
    }
    try stack.append(std.heap.page_allocator, try std.heap.page_allocator.dupe(u8, path));

    var total: u64 = 0;
    while (stack.pop()) |current| {
        defer std.heap.page_allocator.free(current);

        const pattern = try std.fs.path.join(std.heap.page_allocator, &.{ current, "*" });
        defer std.heap.page_allocator.free(pattern);

        const pattern_w = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, pattern);
        defer std.heap.page_allocator.free(pattern_w);

        var find_data: windows.WIN32_FIND_DATAW = undefined;
        const handle = FindFirstFileExW(
            pattern_w.ptr,
            FindExInfoBasic,
            &find_data,
            FindExSearchNameMatch,
            null,
            FIND_FIRST_EX_LARGE_FETCH,
        );
        if (handle == windows.INVALID_HANDLE_VALUE) {
            switch (windows.GetLastError()) {
                .FILE_NOT_FOUND, .PATH_NOT_FOUND, .ACCESS_DENIED => continue,
                else => |err| return windows.unexpectedError(err),
            }
        }
        defer windows.FindClose(handle);

        while (true) {
            const name_w = sliceWtf16Z(&find_data.cFileName);
            if (!isDot(name_w)) {
                const attrs = find_data.dwFileAttributes;
                const is_dir = (attrs & windows.FILE_ATTRIBUTE_DIRECTORY) != 0;
                const is_reparse = (attrs & windows.FILE_ATTRIBUTE_REPARSE_POINT) != 0;

                if (is_dir) {
                    if (!is_reparse) {
                        const name_u8 = std.unicode.utf16LeToUtf8Alloc(std.heap.page_allocator, name_w) catch null;
                        if (name_u8) |name| {
                            defer std.heap.page_allocator.free(name);
                            const child = try std.fs.path.join(std.heap.page_allocator, &.{ current, name });
                            try stack.append(std.heap.page_allocator, child);
                        }
                    }
                } else if (!is_reparse) {
                    const high: u64 = @as(u64, find_data.nFileSizeHigh);
                    const low: u64 = @as(u64, find_data.nFileSizeLow);
                    total +|= (high << 32) | low;
                }
            }

            const ok = FindNextFileW(handle, &find_data);
            if (ok != 0) continue;

            switch (windows.GetLastError()) {
                .NO_MORE_FILES => break,
                .ACCESS_DENIED => break,
                else => |err| return windows.unexpectedError(err),
            }
        }
    }
    return total;
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
