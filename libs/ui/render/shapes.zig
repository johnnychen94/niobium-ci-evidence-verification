//! Anti-aliased shapes by signed distance at pixel centers: coverage = clamp(0.5 − d, 0, 1).
//! Rounded boxes fill straight rows as spans and evaluate distances only in corner bands.

const std = @import("std");
const canvas_mod = @import("canvas.zig");

const Canvas = canvas_mod.Canvas;
const Color = canvas_mod.Color;
const Rect = canvas_mod.Rect;

pub const Box = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn of(r: Rect) Box {
        return .{
            .x = @floatFromInt(r.x),
            .y = @floatFromInt(r.y),
            .w = @floatFromInt(r.w),
            .h = @floatFromInt(r.h),
        };
    }

    pub fn inset(b: Box, d: f32) Box {
        return .{
            .x = b.x + d,
            .y = b.y + d,
            .w = @max(0, b.w - 2 * d),
            .h = @max(0, b.h - 2 * d),
        };
    }

    /// Pixel rows and columns the box touches, intersected with `clip`.
    fn pixels(b: Box, clip: Rect) Rect {
        const x0: i32 = @intFromFloat(@floor(b.x));
        const y0: i32 = @intFromFloat(@floor(b.y));
        const x1: i32 = @intFromFloat(@ceil(b.x + b.w));
        const y1: i32 = @intFromFloat(@ceil(b.y + b.h));
        return clip.intersect(.{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 });
    }
};

pub fn coverage(distance: f32) u8 {
    const c = std.math.clamp(0.5 - distance, 0, 1);
    return @intFromFloat(@round(c * 255));
}

/// Signed distance from (px, py) to a box with corner radius r (negative inside).
pub fn roundedDistance(b: Box, r: f32, px: f32, py: f32) f32 {
    const hx = b.w / 2;
    const hy = b.h / 2;
    const qx = @abs(px - (b.x + hx)) - (hx - r);
    const qy = @abs(py - (b.y + hy)) - (hy - r);
    const outside = @sqrt(@max(qx, 0) * @max(qx, 0) + @max(qy, 0) * @max(qy, 0));
    return outside + @min(@max(qx, qy), 0) - r;
}

fn radiusOf(b: Box, r: f32) f32 {
    return std.math.clamp(r, 0, @min(b.w, b.h) / 2);
}

pub fn fillRounded(c: *Canvas, b: Box, radius: f32, color: Color) void {
    if (b.w <= 0 or b.h <= 0) return;
    const r = radiusOf(b, radius);
    const area = b.pixels(c.clip);
    const solid_top = b.y + @max(r, 1);
    const solid_bottom = b.y + b.h - @max(r, 1);
    var y = area.y;
    while (y < area.bottom()) : (y += 1) {
        const cy = @as(f32, @floatFromInt(y)) + 0.5;
        if (cy >= solid_top and cy <= solid_bottom and @floor(b.x) == b.x and @floor(b.w) == b.w) {
            c.span(y, @intFromFloat(b.x), @intFromFloat(b.x + b.w), color, 255);
            continue;
        }
        var x = area.x;
        while (x < area.right()) : (x += 1) {
            const cx = @as(f32, @floatFromInt(x)) + 0.5;
            c.blend(x, y, color, coverage(roundedDistance(b, r, cx, cy)));
        }
    }
}

/// A `width`-wide outline inside the box edge.
pub fn strokeRounded(c: *Canvas, b: Box, radius: f32, width: f32, color: Color) void {
    if (b.w <= 0 or b.h <= 0 or width <= 0) return;
    const r = radiusOf(b, radius);
    const inner = b.inset(width);
    const inner_r = @max(r - width, 0);
    const area = b.pixels(c.clip);
    const band: i32 = @intFromFloat(@ceil(width + r + 1));
    var y = area.y;
    while (y < area.bottom()) : (y += 1) {
        const cy = @as(f32, @floatFromInt(y)) + 0.5;
        const edge_row = cy < b.y + @as(
            f32,
            @floatFromInt(band),
        ) or cy > b.y + b.h - @as(f32, @floatFromInt(band));
        var x = area.x;
        while (x < area.right()) : (x += 1) {
            if (!edge_row and x >= area.x + band and x < area.right() - band) {
                x = area.right() - band - 1;
                continue;
            }
            const cx = @as(f32, @floatFromInt(x)) + 0.5;
            const outer_cov: i32 = coverage(roundedDistance(b, r, cx, cy));
            const inner_cov: i32 = if (inner.w > 0 and inner.h > 0)
                coverage(roundedDistance(inner, inner_r, cx, cy))
            else
                0;
            c.blend(x, y, color, @intCast(@max(outer_cov - inner_cov, 0)));
        }
    }
}

/// Distance to the segment (ax, ay)–(bx, by).
pub fn segmentDistance(ax: f32, ay: f32, bx: f32, by: f32, px: f32, py: f32) f32 {
    const dx = bx - ax;
    const dy = by - ay;
    const len2 = dx * dx + dy * dy;
    const t = if (len2 == 0) 0 else std.math.clamp(((px - ax) * dx + (py - ay) * dy) / len2, 0, 1);
    const ex = px - (ax + t * dx);
    const ey = py - (ay + t * dy);
    return @sqrt(ex * ex + ey * ey);
}

/// Indeterminate spinner: a faint full track and a quarter-turn arc starting at `phase`
/// thousandths of a turn, clockwise from 12 o'clock.
pub fn ring(c: *Canvas, b: Box, width: f32, phase: u16, color: Color) void {
    const side = @min(b.w, b.h);
    const cx = b.x + b.w / 2;
    const cy = b.y + b.h / 2;
    const radius = side / 2 - width / 2;
    const start = @as(f32, @floatFromInt(phase % 1000)) / 1000.0;
    const track: Color = .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a / 4 };
    const area = b.pixels(c.clip);
    var y = area.y;
    while (y < area.bottom()) : (y += 1) {
        var x = area.x;
        while (x < area.right()) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5 - cx;
            const py = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            const d = @abs(@sqrt(px * px + py * py) - radius) - width / 2;
            const cov = coverage(d);
            if (cov == 0) continue;
            const turn = @mod(std.math.atan2(px, -py) / (2 * std.math.pi) - start, 1.0);
            c.blend(x, y, if (turn < 0.25) color else track, cov);
        }
    }
}

test "rounded fill is solid inside, antialiased at corners and empty outside" {
    var c = try Canvas.init(std.testing.allocator, 20, 20);
    defer c.deinit(std.testing.allocator);
    const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    fillRounded(&c, .{ .x = 2, .y = 2, .w = 16, .h = 16 }, 6, black);
    try std.testing.expectEqual(@as(u8, 255), c.get(10, 10).a);
    try std.testing.expectEqual(@as(u8, 255), c.get(2, 10).a);
    try std.testing.expectEqual(@as(u8, 0), c.get(2, 2).a);
    const edge = c.get(3, 4).a;
    try std.testing.expect(edge > 0 and edge < 255);
    try std.testing.expectEqual(@as(u8, 0), c.get(1, 10).a);
}

test "stroke leaves the interior untouched" {
    var c = try Canvas.init(std.testing.allocator, 40, 20);
    defer c.deinit(std.testing.allocator);
    strokeRounded(&c, .{ .x = 0, .y = 0, .w = 40, .h = 20 }, 4, 1, .{ .r = 0, .g = 0, .b = 0 });
    try std.testing.expectEqual(@as(u8, 255), c.get(20, 0).a);
    try std.testing.expectEqual(@as(u8, 0), c.get(20, 10).a);
    try std.testing.expectEqual(@as(u8, 255), c.get(39, 10).a);
    try std.testing.expectEqual(@as(u8, 0), c.get(38, 10).a);
}
