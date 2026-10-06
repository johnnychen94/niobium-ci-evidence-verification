//! Pure ustar / pax header parsing. No IO; fuzzed directly (tests/fuzz).

const std = @import("std");

pub const block_len = 512;

pub const Kind = enum { file, directory, pax, end };

pub const HeaderError = error{ ArchiveHeader, ForbiddenEntryType };

pub const Header = struct {
    kind: Kind,
    size: u64,
    /// Slices into the header block; copy before reading the next block.
    name: []const u8,
    prefix: []const u8,
};

pub const Pax = struct {
    path: ?[]const u8 = null,
    size: ?u64 = null,
};

pub fn isZero(bytes: *const [block_len]u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

fn field(bytes: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, bytes, 0) orelse bytes.len;
    return bytes[0..end];
}

/// Octal number terminated by NUL or space, optionally space-padded on the left. Base-256
/// (GNU) encodings are rejected.
pub fn parseOctal(bytes: []const u8) error{ArchiveHeader}!u64 {
    var index: usize = 0;
    while (index < bytes.len and bytes[index] == ' ') index += 1;
    var value: u64 = 0;
    var digits: usize = 0;
    while (index < bytes.len) : (index += 1) {
        const c = bytes[index];
        if (c == 0 or c == ' ') break;
        if (c < '0' or c > '7') return error.ArchiveHeader;
        value = std.math.mul(u64, value, 8) catch return error.ArchiveHeader;
        value += c - '0';
        digits += 1;
    }
    while (index < bytes.len) : (index += 1) {
        if (bytes[index] != 0 and bytes[index] != ' ') return error.ArchiveHeader;
    }
    if (digits == 0) return error.ArchiveHeader;
    return value;
}

fn checksum(bytes: *const [block_len]u8) u64 {
    var sum: u64 = 0;
    for (bytes, 0..) |byte, i| {
        sum += if (i >= 148 and i < 156) ' ' else byte;
    }
    return sum;
}

fn kindOf(flag: u8) HeaderError!Kind {
    return switch (flag) {
        '0', 0 => .file,
        '5' => .directory,
        'x' => .pax,
        else => error.ForbiddenEntryType,
    };
}

pub fn parseHeader(bytes: *const [block_len]u8) HeaderError!Header {
    if (isZero(bytes)) return .{ .kind = .end, .size = 0, .name = "", .prefix = "" };
    const magic = bytes[257..265];
    const posix = std.mem.eql(u8, magic, "ustar\x0000");
    const gnu = std.mem.eql(u8, magic, "ustar  \x00");
    if (!posix and !gnu) return error.ArchiveHeader;
    if (try parseOctal(bytes[148..156]) != checksum(bytes)) return error.ArchiveHeader;
    const kind = try kindOf(bytes[156]);
    const size = try parseOctal(bytes[124..136]);
    if (kind == .directory and size != 0) return error.ArchiveHeader;
    return .{
        .kind = kind,
        .size = size,
        .name = field(bytes[0..100]),
        .prefix = if (posix) field(bytes[345..500]) else "",
    };
}

/// Records are `<len> <key>=<value>\n`. Only `path` and `size` are honored.
pub fn parsePax(content: []const u8) error{ArchiveHeader}!Pax {
    var pax: Pax = .{};
    var rest = content;
    while (rest.len > 0) {
        const space = std.mem.findScalar(u8, rest, ' ') orelse return error.ArchiveHeader;
        const len = std.fmt.parseInt(usize, rest[0..space], 10) catch return error.ArchiveHeader;
        if (len <= space + 1 or len > rest.len or rest[len - 1] != '\n') return error.ArchiveHeader;
        const record = rest[space + 1 .. len - 1];
        rest = rest[len..];
        const eq = std.mem.findScalar(u8, record, '=') orelse return error.ArchiveHeader;
        const key = record[0..eq];
        const value = record[eq + 1 ..];
        if (std.mem.eql(u8, key, "path")) {
            pax.path = value;
        } else if (std.mem.eql(u8, key, "size")) {
            pax.size = std.fmt.parseInt(u64, value, 10) catch return error.ArchiveHeader;
        }
    }
    return pax;
}

pub fn padding(size: u64) u64 {
    return (block_len - size % block_len) % block_len;
}

test "octal" {
    try std.testing.expectEqual(@as(u64, 8), try parseOctal("0000010\x00"));
    try std.testing.expectEqual(@as(u64, 7), try parseOctal("   7 \x00"));
    try std.testing.expectError(error.ArchiveHeader, parseOctal("\x80\x00\x00\x00"));
    try std.testing.expectError(error.ArchiveHeader, parseOctal("12x"));
    try std.testing.expectError(error.ArchiveHeader, parseOctal("1 2"));
    try std.testing.expectError(error.ArchiveHeader, parseOctal("77777777777777777777777777"));
}

test "pax" {
    const pax = try parsePax("13 path=a/bc\n12 size=100\n15 mtime=12345\n");
    try std.testing.expectEqualStrings("a/bc", pax.path.?);
    try std.testing.expectEqual(@as(?u64, 100), pax.size);
    try std.testing.expectError(error.ArchiveHeader, parsePax("99 path=x\n"));
    try std.testing.expectError(error.ArchiveHeader, parsePax("5 a\n"));
}
