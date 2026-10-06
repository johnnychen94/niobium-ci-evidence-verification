//! PNG I/O on std.compress.flate. Encoding writes 8-bit RGBA with a per-row filter chosen by
//! minimum absolute sum (deterministic bytes for goldens). Decoding accepts non-interlaced
//! 8-bit grayscale, gray+alpha, RGB, RGBA and palette (with tRNS) images within `max_side`;
//! every chunk CRC is checked.

const std = @import("std");
const flate = std.compress.flate;

pub const Error = error{ OutOfMemory, UiImageInvalid, UiImageUnsupported, UiImageTooLarge };

/// Straight-alpha pixels, `u32` = 0xAARRGGBB, row-major.
pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []const u32,
};

pub const max_side = 4096;
const signature = "\x89PNG\r\n\x1a\n";

fn writeChunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) Error!void {
    const len = std.math.cast(u32, data.len) orelse return error.UiImageTooLarge;
    writeChunkBody(w, kind, data, len) catch return error.OutOfMemory;
}

fn writeChunkBody(
    w: *std.Io.Writer,
    kind: *const [4]u8,
    data: []const u8,
    len: u32,
) std.Io.Writer.Error!void {
    try w.writeInt(u32, len, .big);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try w.writeAll(kind);
    try w.writeAll(data);
    try w.writeInt(u32, crc.final(), .big);
}

/// floor((a + b) / 2) without widening.
fn average(a: u8, b: u8) u8 {
    return (a >> 1) + (b >> 1) + (a & b & 1);
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    return if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c;
}

/// Filter `row` against `prior` (zeros for the first row) with filter type `t` into `out`.
fn filterRow(t: u8, row: []const u8, prior: []const u8, bpp: usize, out: []u8) void {
    for (row, 0..) |x, i| {
        const a: u8 = if (i >= bpp) row[i - bpp] else 0;
        const b = prior[i];
        const c: u8 = if (i >= bpp) prior[i - bpp] else 0;
        out[i] = x -% switch (t) {
            0 => 0,
            1 => a,
            2 => b,
            3 => average(a, b),
            else => paeth(a, b, c),
        };
    }
}

fn filtered(arena: std.mem.Allocator, image: Image) Error![]u8 {
    const stride = image.width * 4;
    const raw = try arena.alloc(u8, stride * image.height);
    for (image.pixels, 0..) |p, i| {
        var bgra: [4]u8 = undefined; // SAFETY: written by writeInt.
        std.mem.writeInt(u32, &bgra, p, .little);
        raw[i * 4 ..][0..4].* = .{ bgra[2], bgra[1], bgra[0], bgra[3] };
    }
    const out = try arena.alloc(u8, (stride + 1) * image.height);
    const zero = try arena.alloc(u8, stride);
    @memset(zero, 0);
    const trial = try arena.alloc(u8, stride);
    for (0..image.height) |y| {
        const row = raw[y * stride ..][0..stride];
        const prior = if (y == 0) zero else raw[(y - 1) * stride ..][0..stride];
        const dest = out[y * (stride + 1) ..][0 .. stride + 1];
        var best: u64 = std.math.maxInt(u64);
        for ([_]u8{ 0, 1, 2, 3, 4 }) |t| {
            filterRow(t, row, prior, 4, trial);
            var sum: u64 = 0;
            for (trial) |v| sum += @abs(@as(i8, @bitCast(v)));
            if (sum < best) {
                best = sum;
                dest[0] = t;
                @memcpy(dest[1..], trial);
            }
        }
    }
    return out;
}

pub fn encode(gpa: std.mem.Allocator, image: Image) Error![]u8 {
    if (image.width == 0 or image.height == 0) return error.UiImageTooLarge;
    if (image.width > max_side or image.height > max_side) return error.UiImageTooLarge;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rows = try filtered(arena, image);

    var zlib: std.Io.Writer.Allocating = try .initCapacity(arena, rows.len / 2 + 64);
    const window = try arena.alloc(u8, flate.max_window_len);
    const compress = try arena.create(flate.Compress);
    compress.* = flate.Compress.init(
        &zlib.writer,
        window,
        .zlib,
        .default,
    ) catch return error.OutOfMemory;
    compress.writer.writeAll(rows) catch return error.OutOfMemory;
    compress.finish() catch return error.OutOfMemory;

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    var header: [13]u8 = undefined; // SAFETY: every byte is written below.
    std.mem.writeInt(u32, header[0..4], image.width, .big);
    std.mem.writeInt(u32, header[4..8], image.height, .big);
    header[8..13].* = .{ 8, 6, 0, 0, 0 };
    w.writeAll(signature) catch return error.OutOfMemory;
    try writeChunk(w, "IHDR", &header);
    try writeChunk(w, "IDAT", zlib.written());
    try writeChunk(w, "IEND", "");
    return out.toOwnedSlice();
}

const Header = struct {
    width: u32,
    height: u32,
    color: u8,
    channels: u32,
};

fn parseHeader(data: []const u8) Error!Header {
    if (data.len != 13) return error.UiImageInvalid;
    const width = std.mem.readInt(u32, data[0..4], .big);
    const height = std.mem.readInt(u32, data[4..8], .big);
    if (width == 0 or height == 0) return error.UiImageInvalid;
    if (width > max_side or height > max_side) return error.UiImageTooLarge;
    if (data[8] != 8 or data[10] != 0 or data[11] != 0) return error.UiImageUnsupported;
    if (data[12] != 0) return error.UiImageUnsupported;
    const channels: u32 = switch (data[9]) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        else => return error.UiImageUnsupported,
    };
    return .{ .width = width, .height = height, .color = data[9], .channels = channels };
}

const Chunks = struct {
    header: Header,
    idat: []const u8,
    palette: []const u8 = &.{},
    transparency: []const u8 = &.{},
};

fn readChunks(arena: std.mem.Allocator, bytes: []const u8) Error!Chunks {
    if (!std.mem.startsWith(u8, bytes, signature)) return error.UiImageInvalid;
    var rest = bytes[signature.len..];
    var header: ?Header = null;
    var idat: std.ArrayList(u8) = .empty;
    var palette: []const u8 = &.{};
    var transparency: []const u8 = &.{};
    // loop-bound: every iteration consumes at least 12 bytes of `rest`.
    while (true) {
        if (rest.len < 12) return error.UiImageInvalid;
        const len = std.mem.readInt(u32, rest[0..4], .big);
        if (len > rest.len - 12) return error.UiImageInvalid;
        const kind = rest[4..8];
        const data = rest[8..][0..len];
        var crc: std.hash.Crc32 = .init();
        crc.update(kind);
        crc.update(data);
        if (crc.final() != std.mem.readInt(
            u32,
            rest[8 + len ..][0..4],
            .big,
        )) return error.UiImageInvalid;
        rest = rest[12 + len ..];
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (header != null) return error.UiImageInvalid;
            header = try parseHeader(data);
        } else if (header == null) {
            return error.UiImageInvalid;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            if (len % 3 != 0 or len == 0 or len > 768) return error.UiImageInvalid;
            palette = data;
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            transparency = data;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(arena, data);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        } else if (kind[0] & 0x20 == 0) {
            return error.UiImageUnsupported;
        }
    }
    const h = header orelse return error.UiImageInvalid;
    if (h.color == 3 and palette.len == 0) return error.UiImageInvalid;
    return .{ .header = h, .idat = idat.items, .palette = palette, .transparency = transparency };
}

fn inflate(arena: std.mem.Allocator, idat: []const u8, expected: usize) Error![]u8 {
    var input: std.Io.Reader = .fixed(idat);
    const window = try arena.alloc(u8, flate.max_window_len);
    var d: flate.Decompress = .init(&input, .zlib, window);
    const raw = d.reader.allocRemaining(arena, .limited(expected + 1)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UiImageInvalid,
    };
    if (raw.len != expected) return error.UiImageInvalid;
    return raw;
}

fn unfilter(raw: []u8, h: Header) Error![]const u8 {
    const stride = h.width * h.channels;
    var prior: []const u8 = &.{};
    for (0..h.height) |y| {
        const line = raw[y * (stride + 1) ..][0 .. stride + 1];
        const t = line[0];
        if (t > 4) return error.UiImageInvalid;
        const row = line[1..];
        for (row, 0..) |*x, i| {
            const a: u8 = if (i >= h.channels) row[i - h.channels] else 0;
            const b: u8 = if (prior.len > 0) prior[i] else 0;
            const c: u8 = if (prior.len > 0 and i >= h.channels) prior[i - h.channels] else 0;
            x.* +%= switch (t) {
                0 => 0,
                1 => a,
                2 => b,
                3 => average(a, b),
                else => paeth(a, b, c),
            };
        }
        prior = row;
    }
    return raw;
}

fn pixel(c: Chunks, row: []const u8, x: usize) Error!u32 {
    const argb = struct {
        fn f(r: u8, g: u8, b: u8, a: u8) u32 {
            return @as(u32, a) << 24 | @as(u32, r) << 16 | @as(u32, g) << 8 | b;
        }
    }.f;
    return switch (c.header.color) {
        0 => argb(row[x], row[x], row[x], 255),
        4 => argb(row[2 * x], row[2 * x], row[2 * x], row[2 * x + 1]),
        2 => argb(row[3 * x], row[3 * x + 1], row[3 * x + 2], 255),
        6 => argb(row[4 * x], row[4 * x + 1], row[4 * x + 2], row[4 * x + 3]),
        else => blk: {
            const i: usize = row[x];
            if (3 * i + 2 >= c.palette.len) return error.UiImageInvalid;
            const a = if (i < c.transparency.len) c.transparency[i] else 255;
            break :blk argb(c.palette[3 * i], c.palette[3 * i + 1], c.palette[3 * i + 2], a);
        },
    };
}

/// Decodes into `gpa`-owned pixels.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) Error!Image {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const c = try readChunks(arena, bytes);
    const h = c.header;
    const stride: usize = @as(usize, h.width) * h.channels;
    const raw = try inflate(arena, c.idat, (stride + 1) * h.height);
    const rows = try unfilter(raw, h);
    const pixels = try gpa.alloc(u32, @as(usize, h.width) * h.height);
    errdefer gpa.free(pixels);
    for (0..h.height) |y| {
        const row = rows[y * (stride + 1) + 1 ..][0..stride];
        for (0..h.width) |x| pixels[y * h.width + x] = try pixel(c, row, x);
    }
    return .{ .width = h.width, .height = h.height, .pixels = pixels };
}

test "encode/decode round trip is lossless and deterministic" {
    const gpa = std.testing.allocator;
    var pixels: [6 * 5]u32 = undefined; // SAFETY: filled below.
    for (&pixels, 0..) |*p, i| p.* = @as(u32, @intCast(i)) *% 0x01070B3D | 0x40000000;
    const image: Image = .{ .width = 6, .height = 5, .pixels = &pixels };
    const a = try encode(gpa, image);
    defer gpa.free(a);
    const b = try encode(gpa, image);
    defer gpa.free(b);
    try std.testing.expectEqualSlices(u8, a, b);
    const back = try decode(gpa, a);
    defer gpa.free(back.pixels);
    try std.testing.expectEqualSlices(u32, &pixels, back.pixels);
}

test "corrupt and unsupported images are rejected" {
    const gpa = std.testing.allocator;
    const pixels: [4]u32 = @splat(0xFF112233);
    const good = try encode(gpa, .{ .width = 2, .height = 2, .pixels = &pixels });
    defer gpa.free(good);
    const bad_crc = try gpa.dupe(u8, good);
    defer gpa.free(bad_crc);
    bad_crc[signature.len + 8 + 13] ^= 1;
    try std.testing.expectError(error.UiImageInvalid, decode(gpa, bad_crc));
    try std.testing.expectError(error.UiImageInvalid, decode(gpa, good[0 .. good.len - 20]));
    try std.testing.expectError(error.UiImageInvalid, decode(gpa, "GIF89a"));
    var big: [13]u8 = .{ 0, 0, 0x20, 0, 0, 0, 0, 1, 8, 6, 0, 0, 0 };
    try std.testing.expectError(error.UiImageTooLarge, parseHeader(&big));
    big = .{ 0, 0, 0, 1, 0, 0, 0, 1, 16, 6, 0, 0, 0 };
    try std.testing.expectError(error.UiImageUnsupported, parseHeader(&big));
    big = .{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 1 };
    try std.testing.expectError(error.UiImageUnsupported, parseHeader(&big));
}
