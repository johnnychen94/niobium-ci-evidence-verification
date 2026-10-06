//! Strict unified-diff application (`git diff` / `diff -u` output) for third_party patches:
//! every context and removed line must match at the stated position. No fuzz, no offsets, so
//! a patch that no longer fits a new upstream version fails the build instead of drifting.

const std = @import("std");

pub const Error = error{
    PatchMalformed,
    PatchUnsupported,
    PatchMismatch,
    OutOfMemory,
};

pub const Kind = enum { context, remove, add };

pub const Line = struct { kind: Kind, text: []const u8 };

pub const Hunk = struct {
    old_start: usize,
    old_len: usize,
    new_len: usize,
    lines: []const Line,
    /// `\ No newline at end of file` after the hunk's last new-side line.
    new_ends_without_newline: bool = false,
};

pub const FilePatch = struct {
    /// Relative to the package root (`a/` and `b/` prefixes removed).
    path: []const u8,
    /// `--- /dev/null`: the file is created.
    create: bool,
    hunks: []const Hunk,
};

pub fn parse(arena: std.mem.Allocator, text: []const u8) Error![]const FilePatch {
    var files: std.ArrayList(FilePatch) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var pending_old: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (std.mem.cutPrefix(u8, line, "--- ")) |old| {
            pending_old = pathOf(old);
        } else if (std.mem.cutPrefix(u8, line, "+++ ")) |new| {
            const old = pending_old orelse return error.PatchMalformed;
            const path = pathOf(new);
            if (std.mem.eql(u8, path, "/dev/null")) return error.PatchUnsupported;
            try files.append(arena, .{
                .path = path,
                .create = std.mem.eql(u8, old, "/dev/null"),
                .hunks = try parseHunks(arena, &lines),
            });
            pending_old = null;
        }
    }
    if (files.items.len == 0) return error.PatchMalformed;
    return files.items;
}

/// Hunks until the next file header; leaves `lines` positioned after the last hunk line.
fn parseHunks(
    arena: std.mem.Allocator,
    lines: *std.mem.SplitIterator(u8, .scalar),
) Error![]const Hunk {
    var hunks: std.ArrayList(Hunk) = .empty;
    while (lines.peek()) |line| {
        if (!std.mem.startsWith(u8, line, "@@ ")) break;
        skip(lines);
        var hunk = try parseHeader(line);
        var body: std.ArrayList(Line) = .empty;
        var old_seen: usize = 0;
        var new_seen: usize = 0;
        while (old_seen < hunk.old_len or new_seen < hunk.new_len) {
            const raw = lines.next() orelse return error.PatchMalformed;
            if (raw.len == 0) return error.PatchMalformed;
            const kind: Kind = switch (raw[0]) {
                ' ' => .context,
                '-' => .remove,
                '+' => .add,
                else => return error.PatchMalformed,
            };
            if (kind != .add) old_seen += 1;
            if (kind != .remove) new_seen += 1;
            try body.append(arena, .{ .kind = kind, .text = raw[1..] });
        }
        if (old_seen != hunk.old_len or new_seen != hunk.new_len) return error.PatchMalformed;
        if (lines.peek()) |next| if (std.mem.startsWith(u8, next, "\\ ")) {
            skip(lines);
            hunk.new_ends_without_newline = body.items[body.items.len - 1].kind != .remove;
        };
        hunk.lines = body.items;
        try hunks.append(arena, hunk);
    }
    if (hunks.items.len == 0) return error.PatchMalformed;
    return hunks.items;
}

/// Advances past a line already seen through `peek`.
fn skip(lines: *std.mem.SplitIterator(u8, .scalar)) void {
    const skipped = lines.next();
    std.debug.assert(skipped != null);
}

/// `@@ -l[,s] +l[,s] @@ ...`.
fn parseHeader(line: []const u8) Error!Hunk {
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    if (!std.mem.eql(u8, fields.next() orelse "", "@@")) return error.PatchMalformed;
    const old = std.mem.cutPrefix(u8, fields.next() orelse "", "-") orelse
        return error.PatchMalformed;
    const new = std.mem.cutPrefix(u8, fields.next() orelse "", "+") orelse
        return error.PatchMalformed;
    const old_range = try parseRange(old);
    const new_range = try parseRange(new);
    return .{
        .old_start = old_range[0],
        .old_len = old_range[1],
        .new_len = new_range[1],
        .lines = &.{},
    };
}

fn parseRange(text: []const u8) Error!struct { usize, usize } {
    var parts = std.mem.splitScalar(u8, text, ',');
    const start = std.fmt.parseInt(usize, parts.next() orelse "", 10) catch
        return error.PatchMalformed;
    const len = if (parts.next()) |l| std.fmt.parseInt(usize, l, 10) catch
        return error.PatchMalformed else 1;
    return .{ start, len };
}

fn pathOf(header: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, header, "\t") orelse header.len;
    const path = header[0..end];
    if (std.mem.cutPrefix(u8, path, "a/")) |rest| return rest;
    if (std.mem.cutPrefix(u8, path, "b/")) |rest| return rest;
    return path;
}

/// `original` with `file`'s hunks applied.
pub fn apply(arena: std.mem.Allocator, original: []const u8, file: FilePatch) Error![]u8 {
    var old_lines: std.ArrayList([]const u8) = .empty;
    var split = std.mem.splitScalar(u8, original, '\n');
    while (split.next()) |line| try old_lines.append(arena, line);
    const had_newline = original.len == 0 or original[original.len - 1] == '\n';
    if (had_newline) std.debug.assert(old_lines.pop().?.len == 0);
    var out: std.ArrayList([]const u8) = .empty;
    var cursor: usize = 0;
    var ends_without_newline = !had_newline;
    for (file.hunks) |hunk| {
        const start = if (hunk.old_len == 0) hunk.old_start else hunk.old_start - 1;
        if (start < cursor or start > old_lines.items.len) return error.PatchMismatch;
        try out.appendSlice(arena, old_lines.items[cursor..start]);
        cursor = start;
        for (hunk.lines) |line| {
            if (line.kind != .add) {
                if (cursor >= old_lines.items.len) return error.PatchMismatch;
                const old = old_lines.items[cursor];
                if (!std.mem.eql(u8, old, line.text)) return error.PatchMismatch;
                cursor += 1;
            }
            if (line.kind != .remove) try out.append(arena, line.text);
        }
        ends_without_newline = hunk.new_ends_without_newline;
    }
    if (cursor < old_lines.items.len) ends_without_newline = !had_newline;
    try out.appendSlice(arena, old_lines.items[cursor..]);
    const joined = try std.mem.join(arena, "\n", out.items);
    if (ends_without_newline or out.items.len == 0) return joined;
    return std.mem.concat(arena, u8, &.{ joined, "\n" });
}

test "a patch applies exactly and rejects drifted context" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diff =
        \\diff --git a/lib/x.c b/lib/x.c
        \\--- a/lib/x.c
        \\+++ b/lib/x.c
        \\@@ -2,3 +2,3 @@ int f(void)
        \\ one
        \\-two
        \\+TWO
        \\ three
        \\@@ -6 +6,2 @@
        \\ six
        \\+seven
        \\
    ;
    const files = try parse(a, diff);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("lib/x.c", files[0].path);
    const original = "zero\none\ntwo\nthree\nfour\nsix\n";
    try std.testing.expectEqualStrings(
        "zero\none\nTWO\nthree\nfour\nsix\nseven\n",
        try apply(a, original, files[0]),
    );
    try std.testing.expectError(error.PatchMismatch, apply(a, "zero\none\n2\nthree\n", files[0]));
}

test "created files and end-of-file newline markers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diff = "--- /dev/null\n+++ b/NOTE\n@@ -0,0 +1,2 @@\n+a\n+b\n" ++
        "\\ No newline at end of file\n";
    const files = try parse(a, diff);
    try std.testing.expect(files[0].create);
    try std.testing.expectEqualStrings("a\nb", try apply(a, "", files[0]));
    try std.testing.expectError(error.PatchMalformed, parse(a, "--- a/x\n+++ b/x\n@@ -1 +1 @@\n"));
    try std.testing.expectError(error.PatchUnsupported, parse(a, "--- a/x\n+++ /dev/null\n"));
}
