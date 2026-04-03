const std = @import("std");
const builtin = @import("builtin");

/// Lightweight matcher for patterns with regex-like `.*`.
/// Supported:
/// - `.*` => wildcard any sequence
/// - escapes (`\.` `\/` `\\`) => literal char
/// - `^` and `$` are ignored (treated as optional anchors in full regex)
pub fn matches(pattern: []const u8, path: []const u8) bool {
    var pat_buf: [512]u8 = undefined;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    const pat = normalizePattern(pattern, &pat_buf) catch return false;
    const pth = normalizePath(path, &path_buf) catch return false;
    return globMatchStarOnly(pat, pth);
}

fn normalizePattern(input: []const u8, buf: []u8) ![]const u8 {
    var j: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (j >= buf.len) return error.NoSpaceLeft;

        if (input[i] == '^' or input[i] == '$') {
            i += 1;
            continue;
        }
        if (i + 1 < input.len and input[i] == '.' and input[i + 1] == '*') {
            buf[j] = '*';
            j += 1;
            i += 2;
            continue;
        }
        if (input[i] == '\\' and i + 1 < input.len) {
            var c = input[i + 1];
            if (c == '\\') c = '/';
            if (builtin.os.tag == .windows) c = std.ascii.toLower(c);
            buf[j] = c;
            j += 1;
            i += 2;
            continue;
        }

        var c = input[i];
        if (c == '\\') c = '/';
        if (builtin.os.tag == .windows) c = std.ascii.toLower(c);
        buf[j] = c;
        j += 1;
        i += 1;
    }
    return buf[0..j];
}

fn normalizePath(input: []const u8, buf: []u8) ![]const u8 {
    if (input.len > buf.len) return error.NoSpaceLeft;
    for (input, 0..) |c0, idx| {
        var c = c0;
        if (c == '\\') c = '/';
        if (builtin.os.tag == .windows) c = std.ascii.toLower(c);
        buf[idx] = c;
    }
    return buf[0..input.len];
}

fn globMatchStarOnly(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (t < text.len) {
        if (p < pattern.len and (pattern[p] == text[t])) {
            p += 1;
            t += 1;
            continue;
        }
        if (p < pattern.len and pattern[p] == '*') {
            star_idx = p;
            match_idx = t;
            p += 1;
            continue;
        }
        if (star_idx) |s| {
            p = s + 1;
            match_idx += 1;
            t = match_idx;
            continue;
        }
        return false;
    }

    while (p < pattern.len and pattern[p] == '*') : (p += 1) {}
    return p == pattern.len;
}

test "regex-lite hidden segment pattern" {
    try std.testing.expect(matches(".*/\\..*", "C:\\Users\\mathe\\.bun\\cache\\node_modules"));
    try std.testing.expect(!matches(".*/\\..*", "C:\\Users\\mathe\\bun\\cache\\node_modules"));
}

test "regex-lite generic contains style" {
    try std.testing.expect(matches(".*node_modules.*", "C:\\repo\\a\\node_modules\\b"));
}
