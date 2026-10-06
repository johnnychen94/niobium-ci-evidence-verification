//! Deterministic ustar writer (docs/spec/artifact-format-v1.md): mtime 0, uid/gid 0, mode 0644,
//! names longer than the 100-byte field carried by a pax `path` record. The caller orders the
//! entries; the reader in libs/package is the authority on what is accepted.

const std = @import("std");

pub const block_len = 512;
const name_len = 100;

pub const Writer = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    pub fn deinit(w: *Writer) void {
        w.bytes.deinit(w.gpa);
    }

    pub fn file(w: *Writer, path: []const u8, contents: []const u8) !void {
        try w.entry('0', path, contents.len);
        try w.data(contents);
    }

    /// `path` without the trailing `/`.
    pub fn dir(w: *Writer, path: []const u8) !void {
        const name = try std.fmt.allocPrint(w.gpa, "{s}/", .{path});
        defer w.gpa.free(name);
        try w.entry('5', name, 0);
    }

    /// The end-of-archive marker: two zero blocks.
    pub fn finish(w: *Writer) !void {
        try w.bytes.appendNTimes(w.gpa, 0, 2 * block_len);
    }

    fn entry(w: *Writer, flag: u8, path: []const u8, size: u64) !void {
        if (path.len > name_len) {
            const record = try paxRecord(w.gpa, "path", path);
            defer w.gpa.free(record);
            try w.header('x', "PaxHeader", record.len);
            try w.data(record);
            try w.header(flag, path[0..name_len], size);
        } else {
            try w.header(flag, path, size);
        }
    }

    fn header(w: *Writer, flag: u8, name: []const u8, size: u64) !void {
        std.debug.assert(name.len <= name_len);
        var block: [block_len]u8 = @splat(0);
        @memcpy(block[0..name.len], name);
        octal(block[100..108], 0o644);
        octal(block[108..116], 0);
        octal(block[116..124], 0);
        octal(block[124..136], size);
        octal(block[136..148], 0);
        block[156] = flag;
        @memcpy(block[257..265], "ustar\x0000");
        @memset(block[148..156], ' ');
        var sum: u64 = 0;
        for (block) |byte| sum += byte;
        octal(block[148..155], sum);
        try w.bytes.appendSlice(w.gpa, &block);
    }

    fn data(w: *Writer, contents: []const u8) !void {
        try w.bytes.appendSlice(w.gpa, contents);
        const rest = contents.len % block_len;
        if (rest != 0) try w.bytes.appendNTimes(w.gpa, 0, block_len - rest);
    }
};

/// Zero-padded octal filling `field` except its final NUL.
fn octal(field: []u8, value: u64) void {
    var v = value;
    var i = field.len - 1;
    field[i] = 0;
    // loop-bound: one digit per field byte.
    while (i > 0) {
        i -= 1;
        field[i] = '0' + @as(u8, @intCast(v & 7));
        v >>= 3;
    }
    std.debug.assert(v == 0);
}

/// `"<len> <key>=<value>\n"`, where `<len>` counts the whole record including itself.
fn paxRecord(gpa: std.mem.Allocator, key: []const u8, value: []const u8) ![]u8 {
    const body = key.len + value.len + 3; // ' ', '=', '\n'
    var digits: usize = 1;
    // loop-bound: at most 20 decimal digits.
    while (std.math.pow(usize, 10, digits) <= body + digits) digits += 1;
    return std.fmt.allocPrint(gpa, "{d} {s}={s}\n", .{ body + digits, key, value });
}

test "pax record length counts itself" {
    const gpa = std.testing.allocator;
    const record = try paxRecord(gpa, "path", "abc");
    defer gpa.free(record);
    try std.testing.expectEqualStrings("12 path=abc\n", record);
    const name: [90]u8 = @splat('x');
    const long = try paxRecord(gpa, "path", &name);
    defer gpa.free(long);
    const space = std.mem.findScalar(u8, long, ' ').?;
    try std.testing.expectEqual(long.len, try std.fmt.parseInt(usize, long[0..space], 10));
}

test "headers carry a valid checksum and block padding" {
    var w: Writer = .{ .gpa = std.testing.allocator };
    defer w.deinit();
    try w.file("component.json", "{}");
    try w.finish();
    try std.testing.expectEqual(@as(usize, 4 * block_len), w.bytes.items.len);
    const block = w.bytes.items[0..block_len];
    var sum: u64 = 0;
    for (block, 0..) |byte, i| sum += if (i >= 148 and i < 156) ' ' else byte;
    const stored = try std.fmt.parseInt(u64, block[148..154], 8);
    try std.testing.expectEqual(sum, stored);
}
