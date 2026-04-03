const std = @import("std");

pub fn appendDup(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8), value: []const u8) !void {
    try list.append(allocator, try allocator.dupe(u8, value));
}

pub fn appendCsvOrSingle(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8), raw: []const u8) !void {
    if (std.mem.indexOfScalar(u8, raw, ',')) |_| {
        var it = std.mem.splitScalar(u8, raw, ',');
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t\r\n");
            if (trimmed.len == 0) continue;
            try appendDup(allocator, list, trimmed);
        }
        return;
    }
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return;
    try appendDup(allocator, list, trimmed);
}

pub fn appendOwnedCsvOrSingle(allocator: std.mem.Allocator, original: [][]const u8, raw: []const u8) ![][]const u8 {
    var list = std.ArrayListUnmanaged([]const u8).fromOwnedSlice(original);
    errdefer list.deinit(allocator);
    try appendCsvOrSingle(allocator, &list, raw);
    return try list.toOwnedSlice(allocator);
}

pub fn freeStringSlice(allocator: std.mem.Allocator, values: [][]const u8) void {
    for (values) |v| allocator.free(v);
    allocator.free(values);
}

pub fn freeArrayListStrings(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8)) void {
    for (list.items) |v| allocator.free(v);
    list.deinit(allocator);
}

pub fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

test "append csv and trim ignores empty parts" {
    const allocator = std.testing.allocator;
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer freeArrayListStrings(allocator, &list);

    try appendCsvOrSingle(allocator, &list, " node_modules, target ,,dist ");
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqualStrings("node_modules", list.items[0]);
    try std.testing.expectEqualStrings("target", list.items[1]);
    try std.testing.expectEqualStrings("dist", list.items[2]);
}

test "append single value" {
    const allocator = std.testing.allocator;
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer freeArrayListStrings(allocator, &list);

    try appendCsvOrSingle(allocator, &list, "target");
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("target", list.items[0]);
}

test "append owned csv keeps previous values" {
    const allocator = std.testing.allocator;
    const base = try allocator.alloc([]const u8, 1);
    base[0] = try allocator.dupe(u8, "node_modules");

    const out = try appendOwnedCsvOrSingle(allocator, base, "target,dist");
    defer freeStringSlice(allocator, out);

    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqualStrings("node_modules", out[0]);
    try std.testing.expectEqualStrings("target", out[1]);
    try std.testing.expectEqualStrings("dist", out[2]);
}

test "has flag" {
    const args = [_][]const u8{ "--dir", "C:\\repo", "--no-default-rules" };
    try std.testing.expect(hasFlag(&args, "--no-default-rules"));
    try std.testing.expect(!hasFlag(&args, "--unknown"));
}
