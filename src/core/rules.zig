const std = @import("std");
const builtin = @import("builtin");
const regex_lite = @import("regex_lite.zig");

pub const Rules = struct {
    allocator: std.mem.Allocator,
    match_dirs: [][]const u8,
    skip_dirs: [][]const u8,
    skip_path_regexes: [][]const u8,
    skip_dot_dirs: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        match_dirs: []const []const u8,
        skip_dirs: []const []const u8,
        skip_path_regexes: []const []const u8,
        skip_dot_dirs: bool,
    ) !Rules {
        return .{
            .allocator = allocator,
            .match_dirs = try normalizeList(allocator, match_dirs),
            .skip_dirs = try normalizeList(allocator, skip_dirs),
            .skip_path_regexes = try cloneList(allocator, skip_path_regexes),
            .skip_dot_dirs = skip_dot_dirs,
        };
    }

    pub fn deinit(self: *Rules) void {
        for (self.match_dirs) |item| self.allocator.free(item);
        self.allocator.free(self.match_dirs);

        for (self.skip_dirs) |item| self.allocator.free(item);
        self.allocator.free(self.skip_dirs);
        for (self.skip_path_regexes) |item| self.allocator.free(item);
        self.allocator.free(self.skip_path_regexes);

        self.* = undefined;
    }

    pub fn shouldMatchDir(self: Rules, name: []const u8) bool {
        return containsNormalized(self.match_dirs, name);
    }

    pub fn shouldSkipDir(self: Rules, name: []const u8) bool {
        return containsNormalized(self.skip_dirs, name);
    }

    pub fn shouldSkipPath(self: Rules, full_path: []const u8, dir_name: []const u8) bool {
        if (self.skip_dot_dirs and dir_name.len > 0 and dir_name[0] == '.') return true;
        for (self.skip_path_regexes) |pattern| {
            if (regex_lite.matches(pattern, full_path)) return true;
        }
        return false;
    }

    fn containsNormalized(values: []const []const u8, name: []const u8) bool {
        for (values) |v| {
            if (equalName(v, name)) return true;
        }
        return false;
    }

    fn normalizeList(allocator: std.mem.Allocator, values: []const []const u8) ![][]const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (out.items) |item| allocator.free(item);
            out.deinit(allocator);
        }

        for (values) |value| {
            try out.append(allocator, try normalizeName(allocator, value));
        }

        return try out.toOwnedSlice(allocator);
    }

    fn cloneList(allocator: std.mem.Allocator, values: []const []const u8) ![][]const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (out.items) |item| allocator.free(item);
            out.deinit(allocator);
        }
        for (values) |v| {
            try out.append(allocator, try allocator.dupe(u8, v));
        }
        return try out.toOwnedSlice(allocator);
    }

    fn normalizeName(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
        const copy = try allocator.dupe(u8, value);
        if (builtin.os.tag == .windows) {
            _ = std.ascii.lowerString(copy, copy);
        }
        return copy;
    }

    fn equalName(normalized: []const u8, raw: []const u8) bool {
        if (builtin.os.tag == .windows) {
            return std.ascii.eqlIgnoreCase(normalized, raw);
        }
        return std.mem.eql(u8, normalized, raw);
    }
};

test "case insensitive on windows" {
    const allocator = std.testing.allocator;
    var rules = try Rules.init(allocator, &.{"Node_Modules"}, &.{".GIT"}, &.{".*/\\..*"}, true);
    defer rules.deinit();

    if (builtin.os.tag == .windows) {
        try std.testing.expect(rules.shouldMatchDir("node_modules"));
        try std.testing.expect(rules.shouldSkipDir(".git"));
    } else {
        try std.testing.expect(!rules.shouldMatchDir("node_modules"));
    }
}

test "skip dot dirs and regex path pattern" {
    const allocator = std.testing.allocator;
    var rules = try Rules.init(allocator, &.{"node_modules"}, &.{}, &.{".*/\\..*"}, true);
    defer rules.deinit();

    try std.testing.expect(rules.shouldSkipPath("C:\\Users\\a\\.bun\\cache\\node_modules", ".bun"));
    try std.testing.expect(!rules.shouldSkipPath("C:\\Users\\a\\bun\\cache\\node_modules", "bun"));
}
