//! Executes a DisplayList onto a Canvas: shapes, text runs through the glyph cache, icons
//! drawn from distance fields, and image blits with an area filter.

const std = @import("std");
const ui = @import("ui_core");
const canvas_mod = @import("canvas.zig");
const shapes = @import("shapes.zig");
const font = @import("font.zig");
const png = @import("png.zig");

const Canvas = canvas_mod.Canvas;
const Color = canvas_mod.Color;
const Rect = canvas_mod.Rect;
const Command = ui.display.Command;

pub const Error = font.Error || error{UiClipDepth};

pub const max_clip_depth = 16;

pub const Images = struct {
    logo: ?png.Image = null,
    icon: ?png.Image = null,
};

pub const Options = struct {
    images: Images = .{},
    /// Fill for an image node whose source the product does not provide.
    placeholder: Color = .{ .r = 0xC7, .g = 0xC7, .b = 0xCF },
};

pub fn render(c: *Canvas, fonts: *font.Fonts, commands: []const Command, o: Options) Error!void {
    var clips: [max_clip_depth]Rect = undefined; // SAFETY: only [0..depth] is read.
    var depth: usize = 0;
    const full = c.bounds();
    c.clip = full;
    for (commands) |command| {
        switch (command) {
            .fill => |f| shapes.fillRounded(c, .of(f.rect), @floatFromInt(f.radius), f.color),
            .stroke => |s| shapes.strokeRounded(
                c,
                .of(s.rect),
                @floatFromInt(s.radius),
                @floatFromInt(s.width),
                s.color,
            ),
            .ring => |r| shapes.ring(c, .of(r.rect), @floatFromInt(r.width), r.phase, r.color),
            .text => |t| try text(
                c,
                fonts,
                t.x,
                t.y,
                t.line_height,
                t.font,
                t.color,
                t.text,
                t.underline,
            ),
            .icon => |i| icon(c, i.rect, i.icon, i.color),
            .image => |i| image(c, i.rect, switch (i.source) {
                .logo => o.images.logo,
                .icon => o.images.icon,
            }, o.placeholder),
            .clip => |r| {
                if (depth == max_clip_depth) return error.UiClipDepth;
                clips[depth] = c.clip;
                depth += 1;
                c.clip = c.clip.intersect(r);
            },
            .unclip => {
                if (depth == 0) continue;
                depth -= 1;
                c.clip = clips[depth];
            },
        }
    }
    c.clip = full;
}

fn text(
    c: *Canvas,
    fonts: *font.Fonts,
    x: i32,
    top: i32,
    line_height: i32,
    f: ui.env.Font,
    color: Color,
    run: []const u8,
    underline: bool,
) Error!void {
    const id = font.faceOf(f.style);
    const base = font.baseline(fonts.face(id), f.size, top, line_height);
    var pen: font.Pen = .init(fonts, f, run);
    const origin: f32 = @floatFromInt(x);
    // loop-bound: one step per code point of `run`.
    while (pen.next()) |step| {
        const at = origin + step.x;
        const whole = @floor(at);
        const phase: u2 = @intFromFloat(@min(3, @floor((at - whole) * 4)));
        const g = try fonts.glyph(id, step.glyph, f.size, phase) orelse continue;
        blit(c, @as(i32, @intFromFloat(whole)) + g.x0, base + g.y0, g, color);
    }
    if (underline) {
        const thickness = @max(1, @divFloor(f.size + 8, 16));
        const offset = @max(1, @divFloor(f.size + 5, 10));
        const width = fonts.width(f, run);
        c.blendRect(.{ .x = x, .y = base + offset, .w = width, .h = thickness }, color);
    }
}

fn blit(c: *Canvas, x0: i32, y0: i32, g: font.Glyph, color: Color) void {
    var y: i32 = 0;
    while (y < g.h) : (y += 1) {
        var x: i32 = 0;
        while (x < g.w) : (x += 1) {
            const alpha = g.alpha[@intCast(y * g.w + x)];
            c.blend(x0 + x, y0 + y, color, alpha);
        }
    }
}

const Segment = [4]f32;

/// Icon strokes in a unit square; rings are (cx, cy, r, 0).
const IconShape = struct { lines: []const Segment = &.{}, ring: bool = false, dot: ?[2]f32 = null };

fn shape(i: ui.display.Icon) IconShape {
    return switch (i) {
        .check => .{ .lines = &.{ .{ 0.2, 0.52, 0.42, 0.72 }, .{ 0.42, 0.72, 0.8, 0.3 } } },
        .chevron => .{ .lines = &.{ .{ 0.38, 0.22, 0.66, 0.5 }, .{ 0.66, 0.5, 0.38, 0.78 } } },
        .folder => .{},
        .warning => .{
            .ring = true,
            .lines = &.{.{ 0.5, 0.28, 0.5, 0.56 }},
            .dot = .{ 0.5, 0.72 },
        },
        .failure => .{
            .ring = true,
            .lines = &.{ .{ 0.34, 0.34, 0.66, 0.66 }, .{ 0.66, 0.34, 0.34, 0.66 } },
        },
        .success => .{
            .ring = true,
            .lines = &.{ .{ 0.3, 0.52, 0.45, 0.66 }, .{ 0.45, 0.66, 0.72, 0.36 } },
        },
    };
}

fn icon(c: *Canvas, rect: Rect, which: ui.display.Icon, color: Color) void {
    const b: shapes.Box = .of(rect);
    const side = @min(b.w, b.h);
    if (which == .folder) {
        const r = side / 10;
        shapes.fillRounded(
            c,
            .{ .x = b.x + side * 0.08, .y = b.y + side * 0.18, .w = side * 0.4, .h = side * 0.2 },
            r,
            color,
        );
        shapes.fillRounded(
            c,
            .{ .x = b.x + side * 0.08, .y = b.y + side * 0.28, .w = side * 0.84, .h = side * 0.56 },
            r,
            color,
        );
        return;
    }
    const g = shape(which);
    const half_width = @max(0.75, side / 14);
    const area = c.clip.intersect(rect);
    var y = area.y;
    while (y < area.bottom()) : (y += 1) {
        var x = area.x;
        while (x < area.right()) : (x += 1) {
            const px = (@as(f32, @floatFromInt(x)) + 0.5 - b.x) / side;
            const py = (@as(f32, @floatFromInt(y)) + 0.5 - b.y) / side;
            var d: f32 = std.math.floatMax(f32);
            for (g.lines) |l| d = @min(
                d,
                shapes.segmentDistance(l[0], l[1], l[2], l[3], px, py) * side - half_width,
            );
            if (g.ring) d = @min(
                d,
                @abs(
                    @sqrt((px - 0.5) * (px - 0.5) + (py - 0.5) * (py - 0.5)) - 0.42,
                ) * side - half_width,
            );
            if (g.dot) |dot| d = @min(
                d,
                shapes.segmentDistance(
                    dot[0],
                    dot[1],
                    dot[0],
                    dot[1],
                    px,
                    py,
                ) * side - half_width * 1.2,
            );
            c.blend(x, y, color, shapes.coverage(d));
        }
    }
}

/// Area-averaged scaling of `source` into `rect`, or the placeholder when absent.
fn image(c: *Canvas, rect: Rect, source: ?png.Image, placeholder: Color) void {
    const src = source orelse {
        shapes.fillRounded(
            c,
            .of(rect),
            @floatFromInt(@divFloor(@min(rect.w, rect.h), 6)),
            placeholder,
        );
        return;
    };
    const area = c.clip.intersect(rect);
    var y = area.y;
    while (y < area.bottom()) : (y += 1) {
        const sy0 = scaled(y - rect.y, src.height, rect.h);
        const sy1 = @max(sy0 + 1, scaled(y - rect.y + 1, src.height, rect.h));
        var x = area.x;
        while (x < area.right()) : (x += 1) {
            const sx0 = scaled(x - rect.x, src.width, rect.w);
            const sx1 = @max(sx0 + 1, scaled(x - rect.x + 1, src.width, rect.w));
            const p = average(src, sx0, sx1, sy0, sy1);
            c.blend(x, y, canvas_mod.unpack(p), 255);
        }
    }
}

fn scaled(i: i32, source: u32, dest: i32) u32 {
    const v = @as(u64, @intCast(i)) * source / @as(u64, @intCast(dest));
    return @intCast(@min(v, source - 1));
}

fn average(src: png.Image, x0: u32, x1: u32, y0: u32, y1: u32) u32 {
    var sum: [4]u64 = @splat(0);
    var n: u64 = 0;
    var y = y0;
    while (y < @min(y1, src.height)) : (y += 1) {
        var x = x0;
        while (x < @min(x1, src.width)) : (x += 1) {
            const p = src.pixels[y * src.width + x];
            const a: u64 = p >> 24;
            sum[0] += a;
            sum[1] += ((p >> 16) & 0xFF) * a;
            sum[2] += ((p >> 8) & 0xFF) * a;
            sum[3] += (p & 0xFF) * a;
            n += 1;
        }
    }
    if (n == 0 or sum[0] == 0) return 0;
    const a = (sum[0] + n / 2) / n;
    const r = (sum[1] + sum[0] / 2) / sum[0];
    const g = (sum[2] + sum[0] / 2) / sum[0];
    const b = (sum[3] + sum[0] / 2) / sum[0];
    return @intCast(a << 24 | r << 16 | g << 8 | b);
}
