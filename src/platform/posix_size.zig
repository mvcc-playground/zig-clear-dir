const common = @import("size_common.zig");

pub fn dirSizeExact(path: []const u8, progress: bool) !u64 {
    return common.dirSizeExact(path, progress);
}
