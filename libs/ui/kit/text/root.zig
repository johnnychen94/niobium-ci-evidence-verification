//! Text and link. Both wrap inside their rect and start at the reading edge; a link is an
//! underlined accent run with hover, pressed and focus feedback.

const paint = @import("../paint.zig");

const Env = paint.Env;
const Node = paint.Node;

pub fn measure(env: *const Env, n: *const Node, max_w: i32) paint.Size {
    const style: @import("ui_core").ir.TextStyle = if (n.kind == .link) .body else n.style;
    return paint.measureText(env, style, n.text, max_w);
}

pub fn emitText(
    env: *const Env,
    n: *const Node,
    at: paint.Placement,
    list: *paint.DisplayList,
) paint.Error!void {
    const run: paint.Run = .{ .style = n.style, .color = paint.toneColor(env, n.tone) };
    try paint.paragraph(list, env, run, n.text, at.rect);
}

pub fn emitLink(
    env: *const Env,
    n: *const Node,
    at: paint.Placement,
    state: paint.NodeState,
    list: *paint.DisplayList,
) paint.Error!void {
    const t = env.theme;
    const color = if (!n.enabled)
        t.disabled_text
    else
        paint.interactive(state, t.accent, t.accent_hover, t.accent_pressed);
    try paint.paragraph(list, env, .{ .color = color, .underline = true }, n.text, at.rect);
    if (state.focused) try paint.focusRing(list, env, at.rect, env.px(2));
}
