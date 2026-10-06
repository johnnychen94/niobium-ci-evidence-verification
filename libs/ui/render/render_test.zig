//! DisplayList execution: text lands inside its measured box, clips bound every command,
//! underline and icons draw, images scale with alpha, and the measurer drives ui_core layout.

const std = @import("std");
const ui = @import("ui_core");
const tokens = @import("ui_tokens");
const r = @import("root.zig");

const black: r.canvas.Color = .{ .r = 0, .g = 0, .b = 0 };
const white: r.canvas.Color = .{ .r = 255, .g = 255, .b = 255 };

const Scene = struct {
    fonts: *r.Fonts,
    c: r.Canvas,

    fn init(w: i32, h: i32) !Scene {
        const fonts = try r.Fonts.create(std.testing.allocator);
        errdefer fonts.destroy();
        var c = try r.Canvas.init(std.testing.allocator, w, h);
        c.blendRect(c.bounds(), white);
        return .{ .fonts = fonts, .c = c };
    }

    fn deinit(s: *Scene) void {
        s.c.deinit(std.testing.allocator);
        s.fonts.destroy();
    }

    /// Bounding box of pixels that are not white.
    fn ink(s: *const Scene) ?r.canvas.Rect {
        var box: ?r.canvas.Rect = null;
        var y: i32 = 0;
        while (y < s.c.height) : (y += 1) {
            var x: i32 = 0;
            while (x < s.c.width) : (x += 1) {
                if (s.c.pixels[@intCast(y * s.c.width + x)] == 0xFFFFFFFF) continue;
                const p: r.canvas.Rect = .{ .x = x, .y = y, .w = 1, .h = 1 };
                box = if (box) |b| union_(b, p) else p;
            }
        }
        return box;
    }
};

fn union_(a: r.canvas.Rect, b: r.canvas.Rect) r.canvas.Rect {
    const x = @min(a.x, b.x);
    const y = @min(a.y, b.y);
    return .{
        .x = x,
        .y = y,
        .w = @max(a.right(), b.right()) - x,
        .h = @max(a.bottom(), b.bottom()) - y,
    };
}

fn textCommand(x: i32, y: i32, run: []const u8, underline: bool) ui.display.Command {
    return .{ .text = .{
        .x = x,
        .y = y,
        .line_height = 18,
        .font = .{ .style = .body, .size = 13 },
        .color = black,
        .text = run,
        .underline = underline,
    } };
}

test "text ink stays inside its measured line box" {
    var s = try Scene.init(200, 40);
    defer s.deinit();
    try r.render(&s.c, s.fonts, &.{textCommand(10, 10, "Install Hello", false)}, .{});
    const box = s.ink().?;
    const width = s.fonts.width(.{ .style = .body, .size = 13 }, "Install Hello");
    try std.testing.expect(box.x >= 10 and box.right() <= 10 + width + 1);
    try std.testing.expect(box.y >= 10 and box.bottom() <= 10 + 18);
    try std.testing.expect(box.h >= 9);
}

test "clip bounds text and fills; unclip restores; underline spans the run" {
    var s = try Scene.init(200, 40);
    defer s.deinit();
    try r.render(&s.c, s.fonts, &.{
        .{ .clip = .{ .x = 0, .y = 0, .w = 30, .h = 40 } },
        textCommand(10, 10, "Install Hello", true),
        .{ .fill = .{ .rect = .{ .x = 0, .y = 0, .w = 200, .h = 2 }, .color = black } },
        .unclip,
        .{ .fill = .{ .rect = .{ .x = 190, .y = 38, .w = 10, .h = 2 }, .color = black } },
    }, .{});
    const box = s.ink().?;
    try std.testing.expectEqual(@as(i32, 0), box.x);
    try std.testing.expectEqual(@as(i32, 200), box.right());
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), s.c.pixels[1 * 200 + 100]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), s.c.pixels[1 * 200 + 20]);
    var underline_row = false;
    var y: i32 = 20;
    while (y < 28) : (y += 1) {
        if (s.c.pixels[@intCast(y * 200 + 25)] == 0xFF000000) underline_row = true;
    }
    try std.testing.expect(underline_row);
}

test "icons, ring and image placeholder draw inside their rects" {
    var s = try Scene.init(120, 40);
    defer s.deinit();
    const icon_rect: r.canvas.Rect = .{ .x = 4, .y = 4, .w = 16, .h = 16 };
    for (std.enums.values(ui.display.Icon)) |i| {
        s.c.blendRect(s.c.bounds(), white);
        try r.render(
            &s.c,
            s.fonts,
            &.{.{ .icon = .{ .rect = icon_rect, .icon = i, .color = black } }},
            .{},
        );
        const box = s.ink().?;
        try std.testing.expect(
            icon_rect.intersect(box).w == box.w and icon_rect.intersect(box).h == box.h,
        );
    }
    s.c.blendRect(s.c.bounds(), white);
    try r.render(&s.c, s.fonts, &.{
        .{
            .ring = .{
                .rect = .{ .x = 40, .y = 4, .w = 24, .h = 24 },
                .width = 3,
                .phase = 250,
                .color = black,
            },
        },
        .{ .image = .{ .rect = .{ .x = 80, .y = 4, .w = 32, .h = 32 }, .source = .logo } },
    }, .{});
    try std.testing.expect(s.c.get(40 + 12, 4 + 1).r < 255);
    try std.testing.expectEqual(r.canvas.Color{ .r = 0xC7, .g = 0xC7, .b = 0xCF }, s.c.get(96, 20));
}

test "images scale down by area average and respect alpha" {
    var s = try Scene.init(8, 8);
    defer s.deinit();
    var pixels: [16 * 16]u32 = undefined; // SAFETY: filled below.
    for (&pixels, 0..) |*p, i| p.* = if ((i / 16) < 8) 0xFFFF0000 else 0x00000000;
    const logo: r.Image = .{ .width = 16, .height = 16, .pixels = &pixels };
    try r.render(&s.c, s.fonts, &.{
        .{ .image = .{ .rect = .{ .x = 0, .y = 0, .w = 8, .h = 8 }, .source = .logo } },
    }, .{
        .images = .{ .logo = logo },
    });
    try std.testing.expectEqual(r.canvas.Color{ .r = 255, .g = 0, .b = 0 }, s.c.get(3, 1));
    try std.testing.expectEqual(r.canvas.Color{ .r = 255, .g = 255, .b = 255 }, s.c.get(3, 6));
}

test "the font measurer drives ui_core layout" {
    const fonts = try r.Fonts.create(std.testing.allocator);
    defer fonts.destroy();
    var env = ui.testing.env(.{});
    env.text = fonts.measurer();
    const w = env.text.width(env.font(.body), "Install");
    try std.testing.expectEqual(fonts.width(.{ .style = .body, .size = 13 }, "Install"), w);
    env.scale = 200;
    try std.testing.expect(env.text.width(env.font(.body), "Install") >= 2 * w - 2);
    _ = tokens;
}
