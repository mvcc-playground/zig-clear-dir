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
        .interactive => |scan_opts| {
            try runScanAndInteractiveDelete(allocator, stdout, scan_opts, true);
        },
        .scan => |scan_opts| {
            try runScanAndInteractiveDelete(allocator, stdout, scan_opts, false);
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

fn runScanAndInteractiveDelete(
    allocator: std.mem.Allocator,
    stdout: anytype,
    scan_opts: rm.config.ScanOptions,
    interactive: bool,
) !void {
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

    if (!interactive or result.entries.len == 0) return;

    try stdout.print("\nInteractive delete: y = delete current, n = skip current, y-all = delete current and all remaining\n", .{});
    try stdout.flush();

    var selected = std.ArrayListUnmanaged(rm.snapshot.SnapshotEntry).empty;
    defer selected.deinit(allocator);

    var all_remaining = false;
    for (result.entries, 0..) |entry, idx| {
        if (all_remaining) {
            try selected.append(allocator, .{ .path = entry.path, .bytes = entry.bytes });
            continue;
        }

        while (true) {
            try stdout.print("[{d}/{d}] {s} -> delete? (y/n/y-all): ", .{ idx + 1, result.entries.len, entry.path });
            try stdout.flush();

            const choice = try readChoice();
            if (choice == .yes_current) {
                try selected.append(allocator, .{ .path = entry.path, .bytes = entry.bytes });
                break;
            }
            if (choice == .no_current) break;
            if (choice == .yes_all) {
                try selected.append(allocator, .{ .path = entry.path, .bytes = entry.bytes });
                all_remaining = true;
                break;
            }
        }
    }

    if (selected.items.len == 0) {
        try stdout.print("No directories selected for deletion.\n", .{});
        return;
    }

    const selected_total = calcSelectedTotal(selected.items);
    const report = try rm.remover.applyEntries(stdout, scan_opts.roots, selected.items, selected_total, false);
    try stdout.print(
        "\nInteractive apply: selected {d}, removed {d}, bytes {d}\n",
        .{ selected.items.len, report.removed_entries, report.total_bytes },
    );
}

const Choice = enum {
    yes_current,
    no_current,
    yes_all,
};

fn readChoice() !Choice {
    var stdin_buf: [512]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    const stdin = &stdin_reader.interface;

    var line_buf: [64]u8 = undefined;
    const maybe_line = try stdin.readUntilDelimiterOrEof(&line_buf, '\n');
    const line = maybe_line orelse return .no_current;
    const trimmed = std.mem.trim(u8, line, " \t\r\n");

    if (std.ascii.eqlIgnoreCase(trimmed, "y-all")) return .yes_all;
    if (std.ascii.eqlIgnoreCase(trimmed, "y")) return .yes_current;
    if (std.ascii.eqlIgnoreCase(trimmed, "n")) return .no_current;
    return .no_current;
}

fn calcSelectedTotal(entries: []const rm.snapshot.SnapshotEntry) u64 {
    var total: u64 = 0;
    for (entries) |e| total +|= e.bytes;
    return total;
}

test "usage parsing defaults to interactive command" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{"rm-folders"};
    var cmd = try rm.config.parseArgs(allocator, &args);
    defer cmd.deinit(allocator);
    switch (cmd) {
        .interactive => {},
        else => return error.TestUnexpectedResult,
    }
}
