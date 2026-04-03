pub const match_dirs: []const []const u8 = &.{
    "node_modules",
    "target",
};

pub const skip_dirs: []const []const u8 = &.{
    ".git",
    ".hg",
    ".svn",
    "System Volume Information",
    "$RECYCLE.BIN",
    ".zig-cache",
    "zig-out",
    "AppData",
};

pub const skip_dot_dirs: bool = true;
pub const skip_path_regexes: []const []const u8 = &.{};
