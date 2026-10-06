//! A BGRA8 pixel buffer (`u32` = 0xAARRGGBB, little-endian bytes B, G, R, A) with a clip
//! rectangle and source-over blending of straight-alpha colors. Every backend blits this
//! layout directly: Win32 DIB sections, CGImage (32Little, premultiplied first: the window
//! background is opaque, so premultiplied and straight agree) and X11 ZPixmap depth 24.

const std = @import("std");
const ui = @import("ui_core");
const tokens = @import("ui_tokens");

pub const Rect = ui.geometry.Rect;
pub const Color = tokens.Color;

pub const max_side = 8192;

pub const Canvas = struct {
    width: i32,
    height: i32,
    pixels: []u32,
    clip: Rect,

    pub const Error = error{ OutOfMemory, UiCanvasTooLarge };

    pub fn init(gpa: std.mem.Allocator, width: i32, height: i32) Error!Canvas {
        if (width <= 0 or height <= 0 or width > max_side or height > max_side) {
            return error.UiCanvasTooLarge;
        }
        const len: usize = @intCast(width * height);
        const pixels = try gpa.alloc(u32, len);
        @memset(pixels, 0);
        return .{
            .width = width,
            .height = height,
            .pixels = pixels,
            .clip = .{ .x = 0, .y = 0, .w = width, .h = height },
        };
    }

    pub fn deinit(c: *Canvas, gpa: std.mem.Allocator) void {
        gpa.free(c.pixels);
        c.* = undefined; // SAFETY: the canvas is dead after deinit.
    }

    pub fn bounds(c: *const Canvas) Rect {
        return .{ .x = 0, .y = 0, .w = c.width, .h = c.height };
    }

    pub fn get(c: *const Canvas, x: i32, y: i32) Color {
        return unpack(c.pixels[c.index(x, y)]);
    }

    fn index(c: *const Canvas, x: i32, y: i32) usize {
        std.debug.assert(x >= 0);
        std.debug.assert(x < c.width);
        std.debug.assert(y >= 0);
        std.debug.assert(y < c.height);
        return @intCast(y * c.width + x);
    }

    /// Blends `color` at `coverage` (0–255) onto one pixel inside the clip.
    pub fn blend(c: *Canvas, x: i32, y: i32, color: Color, coverage: u8) void {
        if (coverage == 0 or !c.clip.contains(.{ .x = x, .y = y })) return;
        const i = c.index(x, y);
        c.pixels[i] = over(c.pixels[i], color, coverage);
    }

    /// Blends a horizontal run [x0, x1) of row `y`, clipped.
    pub fn span(c: *Canvas, y: i32, x0: i32, x1: i32, color: Color, coverage: u8) void {
        if (coverage == 0 or y < c.clip.y or y >= c.clip.bottom()) return;
        const from = @max(x0, c.clip.x);
        const to = @min(x1, c.clip.right());
        if (from >= to) return;
        const row = c.pixels[c.index(from, y)..][0..@intCast(to - from)];
        if (coverage == 255 and color.a == 255) {
            @memset(row, pack(color));
            return;
        }
        for (row) |*p| p.* = over(p.*, color, coverage);
    }

    pub fn blendRect(c: *Canvas, r: Rect, color: Color) void {
        var y = r.y;
        while (y < r.bottom()) : (y += 1) c.span(y, r.x, r.right(), color, 255);
    }
};

pub fn pack(c: Color) u32 {
    return @as(u32, c.a) << 24 | @as(u32, c.r) << 16 | @as(u32, c.g) << 8 | c.b;
}

pub fn unpack(p: u32) Color {
    return .{
        .r = @truncate(p >> 16),
        .g = @truncate(p >> 8),
        .b = @truncate(p),
        .a = @truncate(p >> 24),
    };
}

fn mul255(a: u32, b: u32) u32 {
    const t = a * b + 128;
    return (t + (t >> 8)) >> 8;
}

/// Source-over of a straight-alpha color at `coverage` onto a straight-alpha pixel.
pub fn over(dst: u32, color: Color, coverage: u8) u32 {
    const a = mul255(color.a, coverage);
    if (a == 0) return dst;
    const d = unpack(dst);
    const inv = 255 - a;
    const out_a = a + mul255(d.a, inv);
    if (out_a == 0) return 0;
    const channel = struct {
        fn f(s: u8, dc: u8, sa: u32, da: u32, oa: u32) u8 {
            const num = @as(u32, s) * sa * 255 + @as(u32, dc) * da * (255 - sa);
            return @intCast((num + oa * 255 / 2) / (oa * 255));
        }
    }.f;
    return pack(.{
        .r = channel(color.r, d.r, a, d.a, out_a),
        .g = channel(color.g, d.g, a, d.a, out_a),
        .b = channel(color.b, d.b, a, d.a, out_a),
        .a = @intCast(out_a),
    });
}

test "blending onto opaque pixels mixes by alpha; clip bounds every write" {
    var c = try Canvas.init(std.testing.allocator, 4, 2);
    defer c.deinit(std.testing.allocator);
    c.span(0, -5, 10, .{ .r = 255, .g = 255, .b = 255 }, 255);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), c.pixels[3]);
    c.blend(1, 0, .{ .r = 0, .g = 0, .b = 0, .a = 128 }, 255);
    try std.testing.expectEqual(Color{ .r = 127, .g = 127, .b = 127 }, c.get(1, 0));
    c.clip = .{ .x = 0, .y = 0, .w = 1, .h = 1 };
    c.span(1, 0, 4, .{ .r = 1, .g = 2, .b = 3 }, 255);
    c.blend(2, 0, .{ .r = 1, .g = 2, .b = 3 }, 255);
    try std.testing.expectEqual(@as(u32, 0), c.pixels[5]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), c.pixels[2]);
    try std.testing.expectEqual(@as(u32, 0xFF010203), pack(.{ .r = 1, .g = 2, .b = 3 }));
}
