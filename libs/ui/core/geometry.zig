//! Integer device-pixel geometry. Layout rounds tokens to device pixels once, so every
//! DisplayList coordinate is an exact integer and snapshots stay byte-stable.

const std = @import("std");

pub const Point = struct { x: i32, y: i32 };

pub const Size = struct {
    w: i32,
    h: i32,

    pub const zero: Size = .{ .w = 0, .h = 0 };
};

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub const empty: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

    pub fn right(r: Rect) i32 {
        return r.x + r.w;
    }

    pub fn bottom(r: Rect) i32 {
        return r.y + r.h;
    }

    pub fn contains(r: Rect, p: Point) bool {
        return p.x >= r.x and p.y >= r.y and p.x < r.right() and p.y < r.bottom();
    }

    pub fn intersect(a: Rect, b: Rect) Rect {
        const x = @max(a.x, b.x);
        const y = @max(a.y, b.y);
        const r = @min(a.right(), b.right());
        const bottom_edge = @min(a.bottom(), b.bottom());
        if (r <= x or bottom_edge <= y) return .{ .x = x, .y = y, .w = 0, .h = 0 };
        return .{ .x = x, .y = y, .w = r - x, .h = bottom_edge - y };
    }

    pub fn inset(r: Rect, by: i32) Rect {
        return .{
            .x = r.x + by,
            .y = r.y + by,
            .w = @max(0, r.w - 2 * by),
            .h = @max(0, r.h - 2 * by),
        };
    }

    /// The same rect mirrored inside a container of width `width` starting at x = 0.
    pub fn mirrored(r: Rect, width: i32) Rect {
        return .{ .x = width - r.x - r.w, .y = r.y, .w = r.w, .h = r.h };
    }

    pub fn format(r: Rect, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d},{d} {d}x{d}", .{ r.x, r.y, r.w, r.h });
    }
};

test "rect intersection and mirroring" {
    const a: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const b: Rect = .{ .x = 5, .y = 5, .w = 10, .h = 10 };
    try std.testing.expectEqual(Rect{ .x = 5, .y = 5, .w = 5, .h = 5 }, a.intersect(b));
    const far: Rect = .{ .x = 20, .y = 0, .w = 1, .h = 1 };
    try std.testing.expectEqual(@as(i32, 0), a.intersect(far).w);
    try std.testing.expectEqual(Rect{ .x = 85, .y = 5, .w = 10, .h = 10 }, b.mirrored(100));
    try std.testing.expect(a.contains(.{ .x = 9, .y = 9 }));
    try std.testing.expect(!a.contains(.{ .x = 10, .y = 0 }));
}
