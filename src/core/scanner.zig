const std = @import("std");
const builtin = @import("builtin");
const Rules = @import("rules.zig").Rules;
const SizeMode = @import("config.zig").SizeMode;
const platform = @import("../platform/mod.zig");
const windows = std.os.windows;
const discovery_report_interval: usize = 200;
const sizing_report_interval: usize = 10;
const MeasureMode = enum { approx, exact };
const windows_discovery_worker_cap: usize = 4;
const FindExInfoBasic: u32 = 1;
const FindExSearchNameMatch: u32 = 0;
const FIND_FIRST_EX_LARGE_FETCH: windows.DWORD = 0x2;
const ERROR_NO_MORE_FILES: u16 = 18;

extern "kernel32" fn FindFirstFileExW(
    lpFileName: windows.LPCWSTR,
    fInfoLevelId: u32,
    lpFindFileData: *windows.WIN32_FIND_DATAW,
    fSearchOp: u32,
    lpSearchFilter: ?*anyopaque,
    dwAdditionalFlags: windows.DWORD,
) callconv(.winapi) windows.HANDLE;

extern "kernel32" fn FindNextFileW(
    hFindFile: windows.HANDLE,
    lpFindFileData: *windows.WIN32_FIND_DATAW,
) callconv(.winapi) windows.BOOL;

pub const MatchEntry = struct {
    path: []const u8,
    bytes: u64,
};

pub const ScanResult = struct {
    entries: []MatchEntry,
    total_bytes: u64,
    size_is_estimated: bool,

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
    size_mode: SizeMode,
) !ScanResult {
    const candidates = try collectCandidates(allocator, roots, rules, workers, progress);
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
            std.debug.print("progress: calculating sizes ({s})...\n", .{@tagName(size_mode)});
        }
    }
    if (!with_size) {
        const entries = try allocator.alloc(MatchEntry, candidates.len);
        for (candidates, 0..) |path, idx| {
            entries[idx] = .{ .path = path, .bytes = 0 };
        }
        allocator.free(candidates);
        return .{ .entries = entries, .total_bytes = 0, .size_is_estimated = false };
    }

    const sizes = try allocator.alloc(u64, candidates.len);
    defer allocator.free(sizes);
    @memset(sizes, 0);
    var is_estimated = false;
    if (candidates.len > 0) {
        switch (size_mode) {
            .approx => {
                is_estimated = platform.size.approx_is_estimated;
                try measureSizes(allocator, candidates, sizes, workers, progress, .approx);
            },
            .exact => {
                is_estimated = false;
                try measureSizes(allocator, candidates, sizes, workers, progress, .exact);
            },
            .hybrid => {
                if (progress) std.debug.print("progress: sizing phase 1/2 (estimated)\n", .{});
                try measureSizes(allocator, candidates, sizes, workers, progress, .approx);
                if (progress) std.debug.print("progress: sizing phase 2/2 (exact refine)\n", .{});
                try measureSizes(allocator, candidates, sizes, workers, progress, .exact);
                is_estimated = false;
            },
        }
    }

    const entries = try allocator.alloc(MatchEntry, candidates.len);
    var total: u64 = 0;
    for (candidates, sizes, 0..) |path, bytes, idx| {
        entries[idx] = .{ .path = path, .bytes = bytes };
        total +|= bytes;
    }
    allocator.free(candidates);

    return .{ .entries = entries, .total_bytes = total, .size_is_estimated = is_estimated };
}

fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn collectCandidates(
    allocator: std.mem.Allocator,
    roots: []const []const u8,
    rules: Rules,
    workers: usize,
    progress: bool,
) ![][]const u8 {
    if (builtin.os.tag == .windows) {
        return discoverFastWindows(allocator, roots, rules, workers, progress);
    }
    return discoverPortable(allocator, roots, rules, progress);
}

fn discoverPortable(
    allocator: std.mem.Allocator,
    roots: []const []const u8,
    rules: Rules,
    progress: bool,
) ![][]const u8 {
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
                    if (rules.shouldSkipPath(child, entry.name)) {
                        allocator.free(child);
                        continue;
                    }
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

const DiscoveryContext = struct {
    rules: Rules,
    progress: bool,
    next_index: usize = 0,
    in_flight: usize = 0,
    scanned_dirs: usize = 0,
    matched_dirs: usize = 0,
    first_error: ?anyerror = null,
    pending: std.ArrayListUnmanaged([]const u8) = .empty,
    candidates: std.ArrayListUnmanaged([]const u8) = .empty,
    lock: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
};

const WindowsScratch = struct {
    allocator: std.mem.Allocator,
    search_buf: std.ArrayList(u8),
    child_buf: std.ArrayList(u8),
    name_buf: std.ArrayList(u8),

    fn init(allocator: std.mem.Allocator) WindowsScratch {
        return .{
            .allocator = allocator,
            .search_buf = .empty,
            .child_buf = .empty,
            .name_buf = .empty,
        };
    }

    fn deinit(self: *WindowsScratch) void {
        self.search_buf.deinit(self.allocator);
        self.child_buf.deinit(self.allocator);
        self.name_buf.deinit(self.allocator);
    }
};

fn discoverFastWindows(
    allocator: std.mem.Allocator,
    roots: []const []const u8,
    rules: Rules,
    workers: usize,
    progress: bool,
) ![][]const u8 {
    const temp_allocator = std.heap.page_allocator;
    var context = DiscoveryContext{ .rules = rules, .progress = progress };
    defer {
        for (context.pending.items[context.next_index..]) |path| temp_allocator.free(path);
        context.pending.deinit(temp_allocator);
        for (context.candidates.items) |path| temp_allocator.free(path);
        context.candidates.deinit(temp_allocator);
    }

    for (roots) |root| {
        try context.pending.append(temp_allocator, try temp_allocator.dupe(u8, root));
    }

    const worker_count = effectiveDiscoveryWorkers(workers);
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);

    var started: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < started) : (i += 1) threads[i].join();
    }

    while (started < worker_count) : (started += 1) {
        threads[started] = try std.Thread.spawn(.{}, discoverFastWindowsWorker, .{&context});
    }
    for (threads) |thread| thread.join();

    if (context.first_error) |err| return err;
    if (progress) {
        std.debug.print(
            "progress: discovery complete (scanned {d} dirs, matched {d}, queue 0)\n",
            .{ context.scanned_dirs, context.matched_dirs },
        );
    }

    const owned = try allocator.alloc([]const u8, context.candidates.items.len);
    var copied: usize = 0;
    errdefer {
        for (owned[0..copied]) |path| allocator.free(path);
        allocator.free(owned);
    }
    for (context.candidates.items, 0..) |path, idx| {
        owned[idx] = try allocator.dupe(u8, path);
        copied += 1;
    }
    return owned;
}

fn effectiveDiscoveryWorkers(workers: usize) usize {
    const requested = @max(@as(usize, 1), workers);
    if (builtin.os.tag == .windows) return @min(requested, windows_discovery_worker_cap);
    return 1;
}

fn discoverFastWindowsWorker(context: *DiscoveryContext) void {
    var scratch = WindowsScratch.init(std.heap.page_allocator);
    defer scratch.deinit();

    while (true) {
        const current = getNextDiscoveryPath(context) orelse return;
        defer std.heap.page_allocator.free(current);

        const result = enumerateWindowsDirectory(context, &scratch, current);
        finishDiscoveryPath(context, result);
    }
}

fn getNextDiscoveryPath(context: *DiscoveryContext) ?[]const u8 {
    context.lock.lock();
    defer context.lock.unlock();

    while (true) {
        if (context.first_error != null) return null;
        if (context.next_index < context.pending.items.len) {
            const path = context.pending.items[context.next_index];
            context.next_index += 1;
            context.in_flight += 1;
            return path;
        }
        if (context.in_flight == 0) return null;
        context.cond.wait(&context.lock);
    }
}

fn finishDiscoveryPath(context: *DiscoveryContext, result: anyerror!void) void {
    context.lock.lock();
    defer context.lock.unlock();

    if (result) |_| {} else |err| {
        if (context.first_error == null) context.first_error = err;
    }
    context.in_flight -= 1;
    context.cond.broadcast();
}

fn enumerateWindowsDirectory(
    context: *DiscoveryContext,
    scratch: *WindowsScratch,
    current: []const u8,
) !void {
    const search_path = try buildSearchPattern(&scratch.search_buf, current);
    const search_w = try windows.sliceToPrefixedFileW(null, search_path);

    var find_data: windows.WIN32_FIND_DATAW = undefined;
    const find_handle = FindFirstFileExW(
        search_w.span().ptr,
        FindExInfoBasic,
        &find_data,
        FindExSearchNameMatch,
        null,
        FIND_FIRST_EX_LARGE_FETCH,
    );
    if (find_handle == windows.INVALID_HANDLE_VALUE) {
        return switch (windows.GetLastError()) {
            .FILE_NOT_FOUND, .PATH_NOT_FOUND, .ACCESS_DENIED => {
                reportDiscoveryProgress(context, 1, 0, false);
                return;
            },
            else => error.Unexpected,
        };
    }
    defer _ = windows.kernel32.FindClose(find_handle);

    reportDiscoveryProgress(context, 1, 0, false);

    while (true) {
        try handleWindowsEntry(context, scratch, current, &find_data);

        if (FindNextFileW(find_handle, &find_data) == windows.FALSE) {
            const err = windows.GetLastError();
            if (@intFromEnum(err) == ERROR_NO_MORE_FILES) break;
            if (err == .ACCESS_DENIED) break;
            return error.Unexpected;
        }
    }
}

fn handleWindowsEntry(
    context: *DiscoveryContext,
    scratch: *WindowsScratch,
    current: []const u8,
    find_data: *const windows.WIN32_FIND_DATAW,
) !void {
    const attrs = find_data.dwFileAttributes;
    if (attrs & windows.FILE_ATTRIBUTE_DIRECTORY == 0) return;
    if (attrs & windows.FILE_ATTRIBUTE_REPARSE_POINT != 0) return;
    if (attrs & windows.FILE_ATTRIBUTE_HIDDEN != 0) return;
    if (attrs & windows.FILE_ATTRIBUTE_SYSTEM != 0) return;

    const name = try win32NameToUtf8(&scratch.name_buf, find_data.cFileName[0..]);
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return;
    if (context.rules.shouldSkipDir(name)) return;

    const child_path = try buildChildPath(&scratch.child_buf, current, name);
    if (context.rules.shouldSkipPath(child_path, name)) return;

    if (context.rules.shouldMatchDir(name)) {
        try appendDiscoveryCandidate(context, child_path);
        return;
    }

    try enqueueDiscoveryPath(context, child_path);
}

fn appendDiscoveryCandidate(context: *DiscoveryContext, path: []const u8) !void {
    const temp_allocator = std.heap.page_allocator;
    const owned = try temp_allocator.dupe(u8, path);
    context.lock.lock();
    defer context.lock.unlock();

    if (context.first_error != null) {
        temp_allocator.free(owned);
        return;
    }
    try context.candidates.append(temp_allocator, owned);
    context.matched_dirs += 1;
    context.cond.signal();
}

fn enqueueDiscoveryPath(context: *DiscoveryContext, path: []const u8) !void {
    const temp_allocator = std.heap.page_allocator;
    const owned = try temp_allocator.dupe(u8, path);
    context.lock.lock();
    defer context.lock.unlock();

    if (context.first_error != null) {
        temp_allocator.free(owned);
        return;
    }
    try context.pending.append(temp_allocator, owned);
    context.cond.signal();
}

fn reportDiscoveryProgress(
    context: *DiscoveryContext,
    scanned_increment: usize,
    matched_increment: usize,
    already_locked: bool,
) void {
    if (!already_locked) context.lock.lock();
    defer if (!already_locked) context.lock.unlock();

    context.scanned_dirs += scanned_increment;
    context.matched_dirs += matched_increment;
    const scanned = context.scanned_dirs;
    const matched = context.matched_dirs;
    const queued = context.pending.items.len - context.next_index + context.in_flight;
    const should_report = context.progress and scanned % discovery_report_interval == 0;
    if (should_report) {
        std.debug.print("progress: scanned {d} dirs, matched {d}, queue {d}\n", .{ scanned, matched, queued });
    }
}

fn buildSearchPattern(buf: *std.ArrayList(u8), path: []const u8) ![]const u8 {
    buf.clearRetainingCapacity();
    try buf.appendSlice(std.heap.page_allocator, path);
    if (buf.items.len == 0 or !isPathSeparator(buf.items[buf.items.len - 1])) {
        try buf.append(std.heap.page_allocator, std.fs.path.sep);
    }
    try buf.append(std.heap.page_allocator, '*');
    return buf.items;
}

fn buildChildPath(buf: *std.ArrayList(u8), parent: []const u8, name: []const u8) ![]const u8 {
    buf.clearRetainingCapacity();
    try buf.appendSlice(std.heap.page_allocator, parent);
    if (buf.items.len == 0 or !isPathSeparator(buf.items[buf.items.len - 1])) {
        try buf.append(std.heap.page_allocator, std.fs.path.sep);
    }
    try buf.appendSlice(std.heap.page_allocator, name);
    return buf.items;
}

fn win32NameToUtf8(buf: *std.ArrayList(u8), wide_name: []const u16) ![]const u8 {
    const name_w = std.mem.sliceTo(wide_name, 0);
    try buf.resize(std.heap.page_allocator, name_w.len * 3);
    const len = std.unicode.wtf16LeToWtf8(buf.items, name_w);
    try buf.resize(std.heap.page_allocator, len);
    return buf.items;
}

fn isPathSeparator(ch: u8) bool {
    return ch == '\\' or ch == '/';
}

fn shouldSkipWindowsHiddenOrSystem(path: []const u8) bool {
    if (builtin.os.tag != .windows) return false;

    const attrs = windows.GetFileAttributes(path) catch return false;
    const hidden = attrs & windows.FILE_ATTRIBUTE_HIDDEN != 0;
    const system = attrs & windows.FILE_ATTRIBUTE_SYSTEM != 0;
    return hidden or system;
}

const MeasureContext = struct {
    paths: []const []const u8,
    sizes: []u64,
    next_index: usize = 0,
    first_error: ?anyerror = null,
    completed: usize = 0,
    progress: bool = false,
    mode: MeasureMode = .exact,
    lock: std.Thread.Mutex = .{},
};

fn measureSizes(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    sizes: []u64,
    workers: usize,
    progress: bool,
    mode: MeasureMode,
) !void {
    if (paths.len == 0) return;

    const effective_workers = effectiveSizingWorkers(workers, paths.len, mode);
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator, .n_jobs = effective_workers });
    defer pool.deinit();

    var wg: std.Thread.WaitGroup = .{};
    var context = MeasureContext{ .paths = paths, .sizes = sizes, .progress = progress, .mode = mode };

    const worker_count = @min(effective_workers, paths.len);
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

fn effectiveSizingWorkers(workers: usize, total_paths: usize, mode: MeasureMode) usize {
    const w = @max(@as(usize, 1), workers);
    const platform_limit = if (builtin.os.tag == .windows)
        switch (mode) {
            .approx => @as(usize, 8),
            .exact => @as(usize, 4),
        }
    else
        @as(usize, 16);
    return @min(total_paths, @min(w, platform_limit));
}

fn measureWorker(context: *MeasureContext) void {
    while (true) {
        const idx_opt = getNextIndex(context);
        if (idx_opt == null) return;

        const idx = idx_opt.?;
        const size = switch (context.mode) {
            .approx => platform.size.dirSizeApprox(context.paths[idx]),
            .exact => platform.size.dirSizeExact(context.paths[idx]),
        } catch |err| {
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
    var rules = try Rules.init(allocator, &.{"node_modules"}, &.{}, &.{}, true);
    defer rules.deinit();

    var result = try scan(allocator, &.{root_path}, rules, 2, false, false, .approx);
    defer result.deinit(allocator);

    try std.testing.expect(result.entries.len == 1);
    try std.testing.expect(std.mem.endsWith(u8, result.entries[0].path, "node_modules"));
}

test "scan handles multiple roots consistently" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("r1/a/node_modules");
    try tmp.dir.makePath("r2/b/target");
    try tmp.dir.makePath("r2/b/src");

    var root_one_buf: [std.fs.max_path_bytes]u8 = undefined;
    var root_two_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_one = try tmp.dir.realpath("r1", &root_one_buf);
    const root_two = try tmp.dir.realpath("r2", &root_two_buf);

    const allocator = std.testing.allocator;
    var rules = try Rules.init(allocator, &.{ "node_modules", "target" }, &.{}, &.{}, true);
    defer rules.deinit();

    var result = try scan(allocator, &.{ root_one, root_two }, rules, 4, false, false, .approx);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.entries.len);
}

test "scan with-size mode reports precision flag" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("a/target");
    var f = try tmp.dir.createFile("a/target/out.bin", .{});
    defer f.close();
    try f.writeAll("hello-size-mode");

    var root_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_path = try tmp.dir.realpath(".", &root_path_buf);

    const allocator = std.testing.allocator;
    var rules = try Rules.init(allocator, &.{"target"}, &.{}, &.{}, true);
    defer rules.deinit();

    var approx_result = try scan(allocator, &.{root_path}, rules, 4, false, true, .approx);
    defer approx_result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), approx_result.entries.len);
    try std.testing.expect(approx_result.entries[0].bytes > 0);
    try std.testing.expectEqual(platform.size.approx_is_estimated, approx_result.size_is_estimated);

    var exact_result = try scan(allocator, &.{root_path}, rules, 4, false, true, .exact);
    defer exact_result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), exact_result.entries.len);
    try std.testing.expect(exact_result.entries[0].bytes > 0);
    try std.testing.expect(!exact_result.size_is_estimated);
}
