//! Checkbox: a rounded square mark (accent and check icon when checked) beside its label.

const paint = @import("../paint.zig");

const Env = paint.Env;
const Node = paint.Node;

pub fn measure(env: *const Env, n: *const Node, max_w: i32) paint.Size {
    return paint.Mark.measure(env, n.text, max_w);
}

pub fn emit(
    env: *const Env,
    n: *const Node,
    at: paint.Placement,
    state: paint.NodeState,
    list: *paint.DisplayList,
) paint.Error!void {
    const t = env.theme;
    const place = paint.Mark.place(env, at.rect);
    const radius = env.px(3);
    if (n.checked) {
        const fill = if (!n.enabled)
            t.disabled_bg
        else
            paint.interactive(state, t.accent, t.accent_hover, t.accent_pressed);
        try list.add(.{ .fill = .{ .rect = place.mark, .radius = radius, .color = fill } });
        try list.add(.{ .icon = .{
            .rect = place.mark,
            .icon = .check,
            .color = if (n.enabled) t.accent_text else t.disabled_text,
        } });
    } else {
        try box(env, n, state, place.mark, radius, list);
    }
    const label = if (n.enabled) t.text else t.disabled_text;
    try paint.paragraph(list, env, .{ .color = label }, n.text, place.label);
    if (state.focused) try paint.focusRing(list, env, place.mark, radius);
}

/// The empty control shared with radio marks.
pub fn box(
    env: *const Env,
    n: *const Node,
    state: paint.NodeState,
    rect: paint.Rect,
    radius: i32,
    list: *paint.DisplayList,
) paint.Error!void {
    const t = env.theme;
    const fill = if (!n.enabled)
        t.disabled_bg
    else
        paint.interactive(state, t.control, t.control_hover, t.control_pressed);
    try list.add(.{ .fill = .{ .rect = rect, .radius = radius, .color = fill } });
    try list.add(.{ .stroke = .{
        .rect = rect,
        .radius = radius,
        .width = paint.hairline(env),
        .color = if (state.hovered and n.enabled) t.text_muted else t.border,
    } });
}
