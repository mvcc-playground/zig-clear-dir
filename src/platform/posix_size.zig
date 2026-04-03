const common = @import("size_common.zig");

pub fn dirSize(path: []const u8, progress: bool, sub_workers: usize) !u64 {
    return common.dirSize(path, progress, sub_workers);
}
