//! Containers that paint: window background, card, modal (scrim over the window, then the
//! dialog surface), divider, and the scroll area's scrollbar overlay.

const std = @import("std");
const paint = @import("../paint.zig");

const Env = paint.Env;
const Node = paint.Node;

pub const scrollbar_width = 4;

pub fn measureDivider(env: *const Env, max_w: i32) paint.Size {
    return .{ .w = max_w, .h = paint.hairline(env) };
}

pub fn emit(
    env: *const Env,
    n: *const Node,
    at: paint.Placement,
    list: *paint.DisplayList,
) paint.Error!void {
    const t = env.theme;
    const radius = env.px(env.metrics.radius_surface);
    switch (n.kind) {
        .window => try list.add(.{ .fill = .{ .rect = at.rect, .radius = 0, .color = t.bg } }),
        .divider => try list.add(.{ .fill = .{ .rect = at.rect, .radius = 0, .color = t.border } }),
        .card, .modal => {
            if (n.kind == .modal) try list.add(.{ .fill = .{
                .rect = at.clip,
                .radius = 0,
                .color = t.scrim,
            } });
            const fill = if (n.kind == .modal) t.bg else t.surface;
            try list.add(.{ .fill = .{ .rect = at.rect, .radius = radius, .color = fill } });
            try list.add(.{ .stroke = .{
                .rect = at.rect,
                .radius = radius,
                .width = paint.hairline(env),
                .color = t.border,
            } });
        },
        else => {},
    }
}

/// The thumb of a scroll area whose content overflows; nothing when it fits.
pub fn overlay(
    env: *const Env,
    n: *const Node,
    at: paint.Placement,
    list: *paint.DisplayList,
) paint.Error!void {
    if (n.kind != .scroll or at.scroll.max <= 0) return;
    const rect = at.rect;
    const width = env.px(scrollbar_width);
    const margin = env.px(2);
    const content = rect.h + at.scroll.max;
    const thumb = @max(env.px(24), @divFloor(rect.h * rect.h, content));
    const travel = rect.h - thumb;
    const y = rect.y + @divFloor(travel * at.scroll.offset, at.scroll.max);
    try list.add(.{ .fill = .{
        .rect = .{
            .x = if (env.direction == .rtl) rect.x + margin else rect.right() - margin - width,
            .y = y,
            .w = width,
            .h = thumb,
        },
        .radius = @divFloor(width, 2),
        .color = env.theme.text_muted,
    } });
}

test "scrollbar thumb tracks the offset and hides when content fits" {
    const ui = @import("ui_core");
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var list: paint.DisplayList = .init(arena_state.allocator());
    const env = ui.testing.env(.{});
    const n: Node = .{ .kind = .scroll };
    const rect: paint.Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    try overlay(&env, &n, .{ .rect = rect, .clip = rect }, &list);
    try std.testing.expectEqual(@as(usize, 0), list.items().len);
    try overlay(
        &env,
        &n,
        .{ .rect = rect, .clip = rect, .scroll = .{ .offset = 300, .max = 300 } },
        &list,
    );
    const thumb = list.items()[0].fill.rect;
    try std.testing.expectEqual(@as(i32, 25), thumb.h);
    try std.testing.expectEqual(@as(i32, 100), thumb.bottom());
}
