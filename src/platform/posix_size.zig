const common = @import("size_common.zig");

pub const approx_is_estimated: bool = false;

pub fn dirSizeApprox(path: []const u8) !u64 {
    return common.dirSizeExact(path);
}

pub fn dirSizeExact(path: []const u8) !u64 {
    return common.dirSizeExact(path);
}
