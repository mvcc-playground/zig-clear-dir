const std = @import("std");

pub const FsAdapter = struct {
    pub fn canonicalize(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        return try std.fs.cwd().realpathAlloc(allocator, path);
    }

    pub fn openDir(path: []const u8) !std.fs.Dir {
        return std.fs.cwd().openDir(path, .{ .iterate = true, .access_sub_paths = true, .no_follow = true });
    }

    pub fn statFile(path: []const u8) !std.fs.File.Stat {
        return std.fs.cwd().statFile(path);
    }

    pub fn makePath(path: []const u8) !void {
        try std.fs.cwd().makePath(path);
    }

    pub fn deleteTree(path: []const u8) !void {
        try std.fs.cwd().deleteTree(path);
    }
};
