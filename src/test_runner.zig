const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;

pub const std_options: std.Options = .{
    .logFn = log,
};

var log_err_count: usize = 0;

pub fn main() !void {
    @disableInstrumentation();

    if (builtin.test_functions.len == 0) return;

    const stdout = std.fs.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout.writer(&stdout_buf);
    const out = &stdout_writer.interface;

    var passed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var leaked: usize = 0;

    for (builtin.test_functions, 0..) |test_fn, idx| {
        testing.allocator_instance = .{};
        log_err_count = 0;

        try out.print("[{d}/{d}] {s} ... ", .{ idx + 1, builtin.test_functions.len, test_fn.name });

        if (test_fn.func()) |_| {
            passed += 1;
            if (testing.allocator_instance.deinit() == .leak) {
                leaked += 1;
                failed += 1;
                passed -= 1;
                try out.print("LEAK\n", .{});
            } else {
                try out.print("OK\n", .{});
            }
        } else |err| switch (err) {
            error.SkipZigTest => {
                skipped += 1;
                _ = testing.allocator_instance.deinit();
                try out.print("SKIP\n", .{});
            },
            else => {
                failed += 1;
                _ = testing.allocator_instance.deinit();
                try out.print("FAIL ({s})\n", .{@errorName(err)});
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
            },
        }

        try out.flush();
    }

    try out.print(
        "\n{d} passed, {d} skipped, {d} failed",
        .{ passed, skipped, failed },
    );
    if (leaked != 0) {
        try out.print(", {d} leaked", .{leaked});
    }
    if (log_err_count != 0) {
        try out.print(", {d} logs", .{log_err_count});
    }
    try out.print("\n", .{});
    try out.flush();

    if (failed != 0) std.process.exit(1);
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}
