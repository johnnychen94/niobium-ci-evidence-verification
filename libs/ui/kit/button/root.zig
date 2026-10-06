//! Button: primary (accent) or secondary (bordered control). One line; a label wider than
//! the button is clipped at the padding instead of overflowing.

const paint = @import("../paint.zig");
const ui = @import("ui_core");

const Env = paint.Env;
const Node = paint.Node;

pub fn measure(env: *const Env, n: *const Node, max_w: i32) paint.Size {
    _ = max_w;
    const label = paint.textWidth(env, .body, n.text);
    return .{
        .w = @max(env.px(env.metrics.control_min_width), label + 2 * env.token(.lg)),
        .h = env.px(env.metrics.control_height),
    };
}

const Colors = struct { fill: paint.Color, border: ?paint.Color, label: paint.Color };

fn colors(env: *const Env, n: *const Node, state: paint.NodeState) Colors {
    const t = env.theme;
    if (!n.enabled) return .{
        .fill = t.disabled_bg,
        .border = null,
        .label = t.disabled_text,
    };
    return switch (n.variant) {
        .primary => .{
            .fill = paint.interactive(state, t.accent, t.accent_hover, t.accent_pressed),
            .border = null,
            .label = t.accent_text,
        },
        .secondary => .{
            .fill = paint.interactive(state, t.control, t.control_hover, t.control_pressed),
            .border = t.border,
            .label = t.text,
        },
    };
}

pub fn emit(
    env: *const Env,
    n: *const Node,
    at: paint.Placement,
    state: paint.NodeState,
    list: *paint.DisplayList,
) paint.Error!void {
    const rect = at.rect;
    const radius = env.px(env.metrics.radius_control);
    const c = colors(env, n, state);
    try list.add(.{ .fill = .{ .rect = rect, .radius = radius, .color = c.fill } });
    if (c.border) |border| try list.add(.{ .stroke = .{
        .rect = rect,
        .radius = radius,
        .width = paint.hairline(env),
        .color = border,
    } });
    const pad = env.token(.lg);
    const width = paint.textWidth(env, .body, n.text);
    const y = rect.y + @divFloor(rect.h - env.lineHeight(.body), 2);
    const run: paint.Run = .{ .color = c.label };
    if (width <= rect.w - 2 * pad) {
        const x = rect.x + @divFloor(rect.w - width, 2);
        try list.add(.{ .text = .{
            .x = x,
            .y = y,
            .line_height = env.lineHeight(.body),
            .font = env.font(.body),
            .color = c.label,
            .text = n.text,
        } });
    } else {
        const inner = rect.inset(pad);
        try list.add(.{ .clip = .{ .x = inner.x, .y = rect.y, .w = inner.w, .h = rect.h } });
        try paint.line(list, env, run, n.text, inner.x, inner.right(), y);
        try list.add(.unclip);
    }
    if (state.focused) try paint.focusRing(list, env, rect, radius);
}

test "primary label is centered and states pick accent roles" {
    const std = @import("std");
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var list: paint.DisplayList = .init(arena_state.allocator());
    const env = ui.testing.env(.{});
    const n: Node = .{ .kind = .button, .text = "Install", .variant = .primary };
    const rect: paint.Rect = .{ .x = 0, .y = 0, .w = 100, .h = 28 };
    try emit(
        &env,
        &n,
        .{ .rect = rect, .clip = rect },
        .{ .pressed = true, .focused = true },
        &list,
    );
    const items = list.items();
    try std.testing.expectEqual(env.theme.accent_pressed, items[0].fill.color);
    try std.testing.expectEqual(@as(i32, (100 - 7 * 7) / 2), items[1].text.x);
    try std.testing.expectEqual(env.theme.focus, items[2].stroke.color);
}
