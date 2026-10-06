//! Radio group: the group itself draws nothing; each option is a round mark with a dot when
//! selected. Focus belongs to the group but is drawn on the selected option.

const paint = @import("../paint.zig");
const checkbox = @import("../checkbox/root.zig");

const Env = paint.Env;
const Node = paint.Node;

pub fn measure(env: *const Env, n: *const Node, max_w: i32) paint.Size {
    return paint.Mark.measure(env, n.text, max_w);
}

/// `n` is a radio_option; `state.focused` is set when its group has focus and it is selected.
pub fn emit(
    env: *const Env,
    n: *const Node,
    at: paint.Placement,
    state: paint.NodeState,
    list: *paint.DisplayList,
) paint.Error!void {
    const t = env.theme;
    const place = paint.Mark.place(env, at.rect);
    const round = @divFloor(place.mark.w, 2);
    if (n.selected) {
        const fill = if (!n.enabled)
            t.disabled_bg
        else
            paint.interactive(state, t.accent, t.accent_hover, t.accent_pressed);
        try list.add(.{ .fill = .{ .rect = place.mark, .radius = round, .color = fill } });
        const dot = @divFloor(place.mark.w * 2, 5);
        const inset = @divFloor(place.mark.w - dot, 2);
        try list.add(.{ .fill = .{
            .rect = place.mark.inset(inset),
            .radius = @divFloor(dot, 2),
            .color = if (n.enabled) t.accent_text else t.disabled_text,
        } });
    } else {
        try checkbox.box(env, n, state, place.mark, round, list);
    }
    const label = if (n.enabled) t.text else t.disabled_text;
    try paint.paragraph(list, env, .{ .color = label }, n.text, place.label);
    if (state.focused) try paint.focusRing(list, env, place.mark, round);
}
