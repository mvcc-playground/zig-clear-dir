const builtin = @import("builtin");

const impl = if (builtin.os.tag == .windows)
    @import("windows_fs.zig")
else
    @import("posix_fs.zig");

pub const fs = impl.Fs;
