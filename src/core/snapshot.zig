const std = @import("std");
const config = @import("config.zig");
const scanner = @import("scanner.zig");

pub const Version: u32 = 1;

pub const SnapshotEntry = scanner.MatchEntry;

pub const SnapshotFile = struct {
    version: u32,
    created_unix: i64,
    roots: [][]const u8,
    match_dirs: [][]const u8,
    skip_dirs: [][]const u8,
    total_bytes: u64,
    entries: []SnapshotEntry,
    hash: []const u8,
};

pub const LoadedSnapshot = struct {
    allocator: std.mem.Allocator,
    raw: []u8,
    parsed: std.json.Parsed(SnapshotFile),

    pub fn data(self: *const LoadedSnapshot) *const SnapshotFile {
        return &self.parsed.value;
    }

    pub fn deinit(self: *LoadedSnapshot) void {
        self.parsed.deinit();
        self.allocator.free(self.raw);
        self.* = undefined;
    }
};

pub fn save(allocator: std.mem.Allocator, scan_opts: config.ScanOptions, scan_result: scanner.ScanResult) !void {
    const created = std.time.timestamp();
    const final_hash = computeHash(scan_opts.roots, scan_opts.match_dirs, scan_opts.skip_dirs, scan_result.entries, scan_result.total_bytes, created);
    const final_hash_text = try std.fmt.allocPrint(allocator, "{x:0>16}", .{final_hash});
    defer allocator.free(final_hash_text);

    const payload = SnapshotFile{
        .version = Version,
        .created_unix = created,
        .roots = @constCast(scan_opts.roots),
        .match_dirs = @constCast(scan_opts.match_dirs),
        .skip_dirs = @constCast(scan_opts.skip_dirs),
        .total_bytes = scan_result.total_bytes,
        .entries = scan_result.entries,
        .hash = final_hash_text,
    };

    if (std.fs.path.dirname(scan_opts.snapshot_path)) |dir_name| {
        try std.fs.cwd().makePath(dir_name);
    }

    var file = try std.fs.cwd().createFile(scan_opts.snapshot_path, .{ .truncate = true, .read = false });
    defer file.close();

    var buffer: [8192]u8 = undefined;
    var writer = file.writer(&buffer);
    const w = &writer.interface;

    try std.json.Stringify.value(payload, .{ .whitespace = .indent_2 }, w);
    try w.writeByte('\n');
    try w.flush();
}

pub fn loadAndValidate(allocator: std.mem.Allocator, snapshot_path: []const u8) !LoadedSnapshot {
    const raw = try std.fs.cwd().readFileAlloc(allocator, snapshot_path, 128 * 1024 * 1024);
    errdefer allocator.free(raw);

    var parsed = try std.json.parseFromSlice(SnapshotFile, allocator, raw, .{});
    errdefer parsed.deinit();
    if (parsed.value.version != Version) return error.InvalidSnapshotVersion;

    const expected = computeHash(parsed.value.roots, parsed.value.match_dirs, parsed.value.skip_dirs, parsed.value.entries, parsed.value.total_bytes, parsed.value.created_unix);
    const expected_text = try std.fmt.allocPrint(allocator, "{x:0>16}", .{expected});
    defer allocator.free(expected_text);

    if (!std.mem.eql(u8, expected_text, parsed.value.hash)) {
        return error.InvalidSnapshotHash;
    }

    return .{
        .allocator = allocator,
        .raw = raw,
        .parsed = parsed,
    };
}

fn computeHash(
    roots: []const []const u8,
    match_dirs: []const []const u8,
    skip_dirs: []const []const u8,
    entries: []const SnapshotEntry,
    total_bytes: u64,
    created_unix: i64,
) u64 {
    var hasher = std.hash.Wyhash.init(0);

    hashStringSlice(&hasher, roots);
    hashStringSlice(&hasher, match_dirs);
    hashStringSlice(&hasher, skip_dirs);

    hasher.update(std.mem.asBytes(&total_bytes));
    hasher.update(std.mem.asBytes(&created_unix));

    for (entries) |entry| {
        hasher.update(entry.path);
        hasher.update(&[_]u8{0});
        hasher.update(std.mem.asBytes(&entry.bytes));
    }

    return hasher.final();
}

fn hashStringSlice(hasher: *std.hash.Wyhash, values: []const []const u8) void {
    for (values) |value| {
        hasher.update(value);
        hasher.update(&[_]u8{0});
    }
}

test "snapshot hash validation" {
    const entries = [_]SnapshotEntry{
        .{ .path = "C:/tmp/node_modules", .bytes = 100 },
        .{ .path = "C:/tmp/target", .bytes = 200 },
    };

    const h1 = computeHash(&.{"C:/tmp"}, &.{ "node_modules", "target" }, &.{".git"}, &entries, 300, 123);
    const h2 = computeHash(&.{"C:/tmp"}, &.{ "node_modules", "target" }, &.{".git"}, &entries, 300, 123);
    const h3 = computeHash(&.{"C:/tmp"}, &.{"node_modules"}, &.{".git"}, &entries, 300, 123);

    try std.testing.expectEqual(h1, h2);
    try std.testing.expect(h1 != h3);
}
