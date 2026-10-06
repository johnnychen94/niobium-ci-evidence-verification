//! Greedy line breaking over UTF-8. Break opportunities: after spaces, around CJK code
//! points, and at `\n`. A run wider than the line breaks between code points.

const std = @import("std");
const env_mod = @import("env.zig");

const Font = env_mod.Font;
const TextMeasurer = env_mod.TextMeasurer;

pub const Line = struct {
    start: u32,
    end: u32,
    width: i32,
};

pub const max_lines = 256;

pub fn wrap(
    arena: std.mem.Allocator,
    m: TextMeasurer,
    font: Font,
    text: []const u8,
    max_width: i32,
) error{OutOfMemory}![]const Line {
    var lines: std.ArrayList(Line) = .empty;
    var start: usize = 0;
    // loop-bound: every line consumes at least one code point; capped at max_lines.
    while (lines.items.len < max_lines) {
        const next = nextLine(m, font, text, start, max_width);
        try lines.append(arena, next.line);
        if (next.resume_at >= text.len) break;
        start = next.resume_at;
    }
    return lines.items;
}

pub const Extent = struct { width: i32, lines: u32 };

/// The widest line and the line count `wrap` would produce, without allocating.
pub fn measure(m: TextMeasurer, font: Font, text: []const u8, max_width: i32) Extent {
    var result: Extent = .{ .width = 0, .lines = 0 };
    var start: usize = 0;
    // loop-bound: every line consumes at least one code point; capped at max_lines.
    while (result.lines < max_lines) {
        const next = nextLine(m, font, text, start, max_width);
        result.width = @max(result.width, next.line.width);
        result.lines += 1;
        if (next.resume_at >= text.len) break;
        start = next.resume_at;
    }
    return result;
}

const Next = struct { line: Line, resume_at: usize };

fn isCjk(cp: u21) bool {
    return (cp >= 0x2E80 and cp <= 0x9FFF) or (cp >= 0xAC00 and cp <= 0xD7AF) or
        (cp >= 0xF900 and cp <= 0xFAFF) or (cp >= 0xFF00 and cp <= 0xFFEF);
}

fn trimEnd(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text, " ");
}

fn skipSpaces(text: []const u8, at: usize) usize {
    var i = at;
    while (i < text.len and text[i] == ' ') i += 1;
    return i;
}

fn decode(text: []const u8, at: usize) struct { cp: u21, len: usize } {
    const len = std.unicode.utf8ByteSequenceLength(text[at]) catch return .{
        .cp = 0xFFFD,
        .len = 1,
    };
    if (at + len > text.len) return .{ .cp = 0xFFFD, .len = 1 };
    const cp = std.unicode.utf8Decode(text[at..][0..len]) catch return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = cp, .len = len };
}

fn line(m: TextMeasurer, font: Font, text: []const u8, start: usize, end: usize) Line {
    const visible = trimEnd(text[start..end]);
    return .{
        .start = @intCast(start),
        .end = @intCast(start + visible.len),
        .width = m.width(font, visible),
    };
}

fn nextLine(m: TextMeasurer, font: Font, text: []const u8, start: usize, max_width: i32) Next {
    var fit: ?Next = null;
    var i = start;
    var previous: u21 = 0;
    while (i < text.len) {
        const d = decode(text, i);
        if (d.cp == '\n') {
            const here = line(m, font, text, start, i);
            if (here.width <= max_width or fit == null) return .{
                .line = here,
                .resume_at = i + 1,
            };
            return fit.?;
        }
        const opportunity = i > start and (previous == ' ' or isCjk(d.cp) or isCjk(previous));
        if (opportunity and d.cp != ' ') {
            const here = line(m, font, text, start, i);
            if (here.width > max_width) return fit orelse splitRun(m, font, text, start, max_width);
            fit = .{ .line = here, .resume_at = skipSpaces(text, i) };
        }
        previous = d.cp;
        i += d.len;
    }
    const rest = line(m, font, text, start, text.len);
    if (rest.width <= max_width) return .{ .line = rest, .resume_at = text.len };
    return fit orelse splitRun(m, font, text, start, max_width);
}

/// The longest prefix (at least one code point) that fits.
fn splitRun(m: TextMeasurer, font: Font, text: []const u8, start: usize, max_width: i32) Next {
    var end = start + decode(text, start).len;
    // loop-bound: advances one code point per iteration up to text.len.
    while (end < text.len) {
        const d = decode(text, end);
        if (d.cp == ' ' or d.cp == '\n') break;
        if (m.width(font, text[start .. end + d.len]) > max_width) break;
        end += d.len;
    }
    return .{ .line = line(m, font, text, start, end), .resume_at = skipSpaces(text, end) };
}

const testing = @import("testing.zig");

fn lineTexts(text: []const u8, lines: []const Line, buffer: [][]const u8) [][]const u8 {
    for (lines, 0..) |l, i| buffer[i] = text[l.start..l.end];
    return buffer[0..lines.len];
}

test "wrap breaks at spaces, newlines and inside overlong runs" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const env = testing.env(.{});
    const font: Font = .{ .style = .body, .size = 10 };
    // Monospace test measurer: 6 px per Latin code point at size 10.
    var buffer: [16][]const u8 = undefined; // SAFETY: lineTexts writes before reading.
    const text = "Install the app now";
    const lines = try wrap(a, env.text, font, text, 60);
    const got = lineTexts(text, lines, &buffer);
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("Install", got[0]);
    try std.testing.expectEqualStrings("the app", got[1]);
    try std.testing.expectEqualStrings("now", got[2]);

    const long = "Installationsverzeichnis";
    const split = lineTexts(long, try wrap(a, env.text, font, long, 60), &buffer);
    try std.testing.expectEqualStrings("Installati", split[0]);
    try std.testing.expectEqualStrings("onsverzeic", split[1]);

    const two = "a\nb";
    const by_newline = lineTexts(two, try wrap(a, env.text, font, two, 600), &buffer);
    try std.testing.expectEqual(@as(usize, 2), by_newline.len);
    try std.testing.expectEqualStrings("b", by_newline[1]);

    const cjk = "安装应用程序";
    const cjk_lines = try wrap(a, env.text, font, cjk, 30);
    try std.testing.expectEqual(@as(usize, 2), cjk_lines.len);
    try std.testing.expectEqual(@as(i32, 30), cjk_lines[0].width);

    const empty = try wrap(a, env.text, font, "", 10);
    try std.testing.expectEqual(@as(usize, 1), empty.len);
}
