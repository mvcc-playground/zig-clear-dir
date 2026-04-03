const std = @import("std");
const rm = @import("clear_dev_cache");

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
    }

    try stdout.flush();
}

fn runScanAndInteractiveDelete(
    allocator: std.mem.Allocator,
    stdout: anytype,
    scan_opts: rm.config.ScanOptions,
    interactive: bool,
) !void {
    var rules = try rm.rules.Rules.init(allocator, scan_opts.match_dirs, scan_opts.skip_dirs, scan_opts.skip_path_regexes, scan_opts.skip_dot_dirs);
    defer rules.deinit();

    const started = std.time.microTimestamp();
    var result = try rm.scanner.scan(allocator, scan_opts.roots, rules, scan_opts.workers, scan_opts.progress);
    defer result.deinit(allocator);

    for (result.entries) |entry| {
        try stdout.print("{s}\t", .{entry.path});
        try printHumanBytes(stdout, entry.bytes);
        try stdout.print(" ({d} bytes)\n", .{entry.bytes});
    }

    const elapsed_us = std.time.microTimestamp() - started;
    try stdout.print(
        "\nFound {d} directories, total reclaimable (exact): ",
        .{result.entries.len},
    );
    try printHumanBytes(stdout, result.total_bytes);
    try stdout.print(" ({d} bytes)\nElapsed: {d} ms\n", .{ result.total_bytes, @divFloor(elapsed_us, 1000) });

    if (!interactive or result.entries.len == 0) return;

    try stdout.print(
        "\nDelete mode: all/a = delete all, none/n = delete none, each/e = choose one by one\n",
        .{},
    );
    try stdout.flush();

    var selected = try selectEntriesInteractive(allocator, stdout, result.entries);
    defer selected.deinit(allocator);

    if (selected.items.len == 0) {
        try stdout.print("No directories selected for deletion.\n", .{});
        return;
    }

    const selected_total = calcSelectedTotal(selected.items);
    const report = try rm.remover.applyEntries(
        stdout,
        scan_opts.roots,
        selected.items,
        selected_total,
        false,
        scan_opts.delete_workers,
        scan_opts.progress,
    );
    try stdout.print(
        "\nInteractive apply: selected {d}, removed {d}, failed {d}, bytes ",
        .{ selected.items.len, report.removed_entries, report.failed_entries },
    );
    try printHumanBytes(stdout, report.total_bytes);
    try stdout.print(" ({d} bytes)\n", .{report.total_bytes});
}

const Choice = enum {
    yes_current,
    no_current,
    yes_all,
    invalid,
};

const DeleteMode = enum {
    all,
    none,
    each,
    invalid,
};

fn selectEntriesInteractive(
    allocator: std.mem.Allocator,
    stdout: anytype,
    entries: []const rm.scanner.MatchEntry,
) !std.ArrayListUnmanaged(rm.scanner.MatchEntry) {
    const mode = try readDeleteModePrompt(stdout);
    var selected: std.ArrayListUnmanaged(rm.scanner.MatchEntry) = .empty;

    switch (mode) {
        .all => {
            try appendAllSelected(allocator, &selected, entries);
            return selected;
        },
        .none => return selected,
        .each => {
            try stdout.print(
                "Interactive delete: y = delete current, n = skip current, y-all = delete current and all remaining\n",
                .{},
            );
            try stdout.flush();
            try appendSelectedEach(allocator, stdout, &selected, entries);
            return selected;
        },
        .invalid => unreachable,
    }
}

fn appendAllSelected(
    allocator: std.mem.Allocator,
    selected: *std.ArrayListUnmanaged(rm.scanner.MatchEntry),
    entries: []const rm.scanner.MatchEntry,
) !void {
    for (entries) |entry| {
        try selected.append(allocator, .{ .path = entry.path, .bytes = entry.bytes });
    }
}

fn appendSelectedEach(
    allocator: std.mem.Allocator,
    stdout: anytype,
    selected: *std.ArrayListUnmanaged(rm.scanner.MatchEntry),
    entries: []const rm.scanner.MatchEntry,
) !void {
    var all_remaining = false;
    for (entries, 0..) |entry, idx| {
        if (all_remaining) {
            try selected.append(allocator, .{ .path = entry.path, .bytes = entry.bytes });
            continue;
        }

        while (true) {
            try stdout.print("[{d}/{d}] {s} -> delete? (y/n/y-all): ", .{ idx + 1, entries.len, entry.path });
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
            try stdout.print("Invalid input. Use: y, n, or y-all.\n", .{});
        }
    }
}

fn selectEntriesByDecisions(
    allocator: std.mem.Allocator,
    entries: []const rm.scanner.MatchEntry,
    decisions: []const Choice,
) !std.ArrayListUnmanaged(rm.scanner.MatchEntry) {
    var selected: std.ArrayListUnmanaged(rm.scanner.MatchEntry) = .empty;
    var all_remaining = false;

    for (entries, 0..) |entry, idx| {
        if (all_remaining) {
            try selected.append(allocator, .{ .path = entry.path, .bytes = entry.bytes });
            continue;
        }
        const c = if (idx < decisions.len) decisions[idx] else .no_current;
        switch (c) {
            .yes_current => try selected.append(allocator, .{ .path = entry.path, .bytes = entry.bytes }),
            .no_current, .invalid => {},
            .yes_all => {
                try selected.append(allocator, .{ .path = entry.path, .bytes = entry.bytes });
                all_remaining = true;
            },
        }
    }
    return selected;
}

fn readDeleteModePrompt(stdout: anytype) !DeleteMode {
    while (true) {
        try stdout.print("Delete mode (all/a, none/n, each/e): ", .{});
        try stdout.flush();
        const mode = try readDeleteMode();
        if (mode != .invalid) return mode;
        try stdout.print("Invalid input. Use: all/a, none/n, or each/e.\n", .{});
    }
}

fn readDeleteMode() !DeleteMode {
    var stdin_buf: [512]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    const stdin = &stdin_reader.interface;

    const maybe_line = try stdin.takeDelimiter('\n');
    const line = maybe_line orelse return .none;
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    return parseDeleteMode(trimmed);
}

fn parseDeleteMode(trimmed: []const u8) DeleteMode {
    if (std.ascii.eqlIgnoreCase(trimmed, "all") or std.ascii.eqlIgnoreCase(trimmed, "a")) return .all;
    if (std.ascii.eqlIgnoreCase(trimmed, "none") or std.ascii.eqlIgnoreCase(trimmed, "n")) return .none;
    if (std.ascii.eqlIgnoreCase(trimmed, "each") or std.ascii.eqlIgnoreCase(trimmed, "e")) return .each;
    return .invalid;
}

fn readChoice() !Choice {
    var stdin_buf: [512]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    const stdin = &stdin_reader.interface;

    const maybe_line = try stdin.takeDelimiter('\n');
    const line = maybe_line orelse return .no_current;
    const trimmed = std.mem.trim(u8, line, " \t\r\n");

    if (std.ascii.eqlIgnoreCase(trimmed, "y-all")) return .yes_all;
    if (std.ascii.eqlIgnoreCase(trimmed, "y")) return .yes_current;
    if (std.ascii.eqlIgnoreCase(trimmed, "n")) return .no_current;
    return .invalid;
}

fn calcSelectedTotal(entries: []const rm.scanner.MatchEntry) u64 {
    var total: u64 = 0;
    for (entries) |e| total +|= e.bytes;
    return total;
}

fn printHumanBytes(writer: anytype, bytes: u64) !void {
    const kb: f64 = 1024.0;
    const mb: f64 = kb * 1024.0;
    const gb: f64 = mb * 1024.0;
    const value: f64 = @floatFromInt(bytes);
    if (value >= gb) {
        try writer.print("{d:.2} GB", .{value / gb});
        return;
    }
    if (value >= mb) {
        try writer.print("{d:.2} MB", .{value / mb});
        return;
    }
    if (value >= kb) {
        try writer.print("{d:.2} KB", .{value / kb});
        return;
    }
    try writer.print("{d} B", .{bytes});
}

test "usage parsing defaults to interactive command" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{"clear-dev-cache"};
    var cmd = try rm.config.parseArgs(allocator, &args);
    defer cmd.deinit(allocator);
    _ = cmd.interactive;
}

test "parse delete mode aliases" {
    try std.testing.expect(parseDeleteMode("all") == .all);
    try std.testing.expect(parseDeleteMode("a") == .all);
    try std.testing.expect(parseDeleteMode("none") == .none);
    try std.testing.expect(parseDeleteMode("n") == .none);
    try std.testing.expect(parseDeleteMode("each") == .each);
    try std.testing.expect(parseDeleteMode("e") == .each);
    try std.testing.expect(parseDeleteMode("x") == .invalid);
}

test "append all selected selects every entry" {
    const allocator = std.testing.allocator;
    const entries = [_]rm.scanner.MatchEntry{
        .{ .path = "C:\\a\\node_modules", .bytes = 100 },
        .{ .path = "C:\\b\\target", .bytes = 200 },
    };
    var out: std.ArrayListUnmanaged(rm.scanner.MatchEntry) = .empty;
    defer out.deinit(allocator);

    try appendAllSelected(allocator, &out, &entries);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings(entries[0].path, out.items[0].path);
    try std.testing.expectEqualStrings(entries[1].path, out.items[1].path);
}

test "select entries by decisions keeps only selected subset" {
    const allocator = std.testing.allocator;
    const entries = [_]rm.scanner.MatchEntry{
        .{ .path = "C:\\a\\node_modules", .bytes = 10 },
        .{ .path = "C:\\b\\target", .bytes = 20 },
        .{ .path = "C:\\c\\dist", .bytes = 30 },
    };
    const decisions = [_]Choice{ .yes_current, .no_current, .yes_current };
    var out = try selectEntriesByDecisions(allocator, &entries, &decisions);
    defer out.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings(entries[0].path, out.items[0].path);
    try std.testing.expectEqualStrings(entries[2].path, out.items[1].path);
}

test "select entries by decisions y-all selects current and remaining" {
    const allocator = std.testing.allocator;
    const entries = [_]rm.scanner.MatchEntry{
        .{ .path = "C:\\a\\node_modules", .bytes = 10 },
        .{ .path = "C:\\b\\target", .bytes = 20 },
        .{ .path = "C:\\c\\dist", .bytes = 30 },
    };
    const decisions = [_]Choice{ .no_current, .yes_all };
    var out = try selectEntriesByDecisions(allocator, &entries, &decisions);
    defer out.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings(entries[1].path, out.items[0].path);
    try std.testing.expectEqualStrings(entries[2].path, out.items[1].path);
}
