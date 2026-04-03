const std = @import("std");
const rm = @import("rm_folders");

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var command = rm.config.parseArgs(allocator, argv) catch {
        try rm.config.printUsage(stderr);
        try stderr.flush();
        return error.InvalidArgs;
    };
    defer command.deinit(allocator);

    switch (command) {
        .scan => |scan_opts| {
            var rules = try rm.rules.Rules.init(allocator, scan_opts.match_dirs, scan_opts.skip_dirs);
            defer rules.deinit();

            const started = std.time.microTimestamp();
            var result = try rm.scanner.scan(allocator, scan_opts.roots, rules, scan_opts.workers, scan_opts.progress, scan_opts.with_size);
            defer result.deinit(allocator);

            try rm.snapshot.save(allocator, scan_opts, result);

            for (result.entries) |entry| {
                try stdout.print("{s}\t{d}\n", .{ entry.path, entry.bytes });
            }

            const elapsed_us = std.time.microTimestamp() - started;
            if (scan_opts.with_size) {
                try stdout.print(
                    "\nFound {d} directories, total reclaimable: {d} bytes\nSnapshot: {s}\nElapsed: {d} ms\n",
                    .{ result.entries.len, result.total_bytes, scan_opts.snapshot_path, @divFloor(elapsed_us, 1000) },
                );
            } else {
                try stdout.print(
                    "\nFound {d} directories (size not calculated)\nSnapshot: {s}\nElapsed: {d} ms\nUse --with-size to calculate bytes.\n",
                    .{ result.entries.len, scan_opts.snapshot_path, @divFloor(elapsed_us, 1000) },
                );
            }
        },
        .apply => |apply_opts| {
            var loaded = try rm.snapshot.loadAndValidate(allocator, apply_opts.snapshot_path);
            defer loaded.deinit();

            const report = try rm.remover.applySnapshot(stdout, apply_opts, loaded.data());
            try stdout.print(
                "\nProcessed {d} entries, affected {d}, total snapshot bytes {d}\n",
                .{ report.total_entries, report.removed_entries, report.total_bytes },
            );
        },
    }

    try stdout.flush();
}

test "usage parsing requires command" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{"rm-folders"};
    try std.testing.expectError(error.InvalidArgs, rm.config.parseArgs(allocator, &args));
}
