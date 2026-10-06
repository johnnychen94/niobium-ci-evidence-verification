//! Progress bar (determinate, fills from the reading edge) and ring (indeterminate, phase
//! from the animation clock; frozen at phase 0 with reduced motion).

const std = @import("std");
const paint = @import("../paint.zig");
const tokens = @import("ui_tokens");

const Env = paint.Env;
const Node = paint.Node;

pub const ring_size = 24;

pub fn measure(env: *const Env, n: *const Node, max_w: i32) paint.Size {
    return switch (n.kind) {
        .progress_ring => .{ .w = env.px(ring_size), .h = env.px(ring_size) },
        else => .{ .w = max_w, .h = env.px(tokens.progress_height) },
    };
}

pub fn emitBar(
    env: *const Env,
    n: *const Node,
    at: paint.Placement,
    list: *paint.DisplayList,
) paint.Error!void {
    const t = env.theme;
    const rect = at.rect;
    const radius = @divFloor(rect.h, 2);
    try list.add(.{ .fill = .{ .rect = rect, .radius = radius, .color = t.track } });
    const value = std.math.clamp(n.value, 0, 1);
    const filled: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(rect.w)) * value));
    if (filled == 0) return;
    const x = if (env.direction == .rtl) rect.right() - filled else rect.x;
    try list.add(.{ .fill = .{
        .rect = .{ .x = x, .y = rect.y, .w = filled, .h = rect.h },
        .radius = radius,
        .color = if (n.enabled) t.accent else t.disabled_text,
    } });
}

pub fn emitRing(
    env: *const Env,
    n: *const Node,
    at: paint.Placement,
    list: *paint.DisplayList,
) paint.Error!void {
    _ = n;
    const rect = at.rect;
    const side = @min(rect.w, rect.h);
    const square: paint.Rect = .{
        .x = rect.x + @divFloor(rect.w - side, 2),
        .y = rect.y + @divFloor(rect.h - side, 2),
        .w = side,
        .h = side,
    };
    const period = tokens.progress_period_ms;
    const phase: u16 = if (env.reduced_motion) 0 else @intCast(
        env.time_ms % period * 1000 / period,
    );
    try list.add(.{ .ring = .{
        .rect = square,
        .width = env.px(3),
        .phase = phase,
        .color = env.theme.accent,
    } });
}

test "bar fills from the right in RTL and the ring freezes with reduced motion" {
    const ui = @import("ui_core");
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var list: paint.DisplayList = .init(arena_state.allocator());
    const rect: paint.Rect = .{ .x = 10, .y = 0, .w = 200, .h = 6 };
    const n: Node = .{ .kind = .progress_bar, .value = 0.25 };
    const rtl = ui.testing.env(.{ .direction = .rtl });
    try emitBar(&rtl, &n, .{ .rect = rect, .clip = rect }, &list);
    try std.testing.expectEqual(@as(i32, 160), list.items()[1].fill.rect.x);
    try std.testing.expectEqual(@as(i32, 50), list.items()[1].fill.rect.w);

    var still = ui.testing.env(.{});
    still.reduced_motion = true;
    still.time_ms = 700;
    try emitRing(&still, &n, .{ .rect = rect, .clip = rect }, &list);
    try std.testing.expectEqual(@as(u16, 0), list.items()[2].ring.phase);
    var moving = ui.testing.env(.{});
    moving.time_ms = 700;
    try emitRing(&moving, &n, .{ .rect = rect, .clip = rect }, &list);
    try std.testing.expectEqual(@as(u16, 500), list.items()[3].ring.phase);
}
