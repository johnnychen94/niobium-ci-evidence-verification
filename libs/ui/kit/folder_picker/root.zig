//! Folder picker: its label above the path. With the native capability the path sits in a
//! full-width field (folder icon + path) that opens the system dialog; as a fallback it is a
//! read-only path line.

const paint = @import("../paint.zig");

const Env = paint.Env;
const Node = paint.Node;

pub const icon_size = 16;

fn header(env: *const Env, n: *const Node) i32 {
    return if (n.text.len == 0) 0 else env.lineHeight(.body) + env.token(.xs);
}

fn rowHeight(env: *const Env, n: *const Node) i32 {
    return if (n.fallback_active)
        @max(env.px(icon_size), env.lineHeight(.body))
    else
        env.px(env.metrics.control_height);
}

pub fn measure(env: *const Env, n: *const Node, max_w: i32) paint.Size {
    return .{ .w = max_w, .h = header(env, n) + rowHeight(env, n) };
}

fn field(
    env: *const Env,
    n: *const Node,
    rect: paint.Rect,
    state: paint.NodeState,
    list: *paint.DisplayList,
) paint.Error!void {
    const t = env.theme;
    const radius = env.px(env.metrics.radius_control);
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

pub fn emit(
    env: *const Env,
    n: *const Node,
    at: paint.Placement,
    state: paint.NodeState,
    list: *paint.DisplayList,
) paint.Error!void {
    const t = env.theme;
    const label_color = if (n.enabled) t.text else t.disabled_text;
    if (n.text.len > 0) {
        try paint.line(
            list,
            env,
            .{ .color = label_color },
            n.text,
            at.rect.x,
            at.rect.right(),
            at.rect.y,
        );
    }
    const top = at.rect.y + header(env, n);
    const row: paint.Rect = .{ .x = at.rect.x, .y = top, .w = at.rect.w, .h = rowHeight(env, n) };
    const native = !n.fallback_active;
    if (native) try field(env, n, row, state, list);
    const pad = if (native) env.token(.sm) else 0;
    const icon = env.px(icon_size);
    const ltr = env.direction == .ltr;
    const middle = row.y + @divFloor(row.h, 2);
    try list.add(.{ .icon = .{
        .rect = .{
            .x = if (ltr) row.x + pad else row.right() - pad - icon,
            .y = middle - @divFloor(icon, 2),
            .w = icon,
            .h = icon,
        },
        .icon = .folder,
        .color = if (!n.enabled or !native) t.text_muted else t.accent,
    } });
    const gap = icon + env.token(.sm);
    const inner: paint.Rect = .{
        .x = if (ltr) row.x + pad + gap else row.x + pad,
        .y = row.y,
        .w = @max(0, row.w - 2 * pad - gap),
        .h = row.h,
    };
    const path_color = if (!n.enabled) t.disabled_text else if (native) t.text else t.text_muted;
    const y = middle - @divFloor(env.lineHeight(.body), 2);
    try list.add(.{ .clip = inner });
    try paint.line(list, env, .{ .color = path_color }, n.detail, inner.x, inner.right(), y);
    try list.add(.unclip);
    if (state.focused and native) try paint.focusRing(
        list,
        env,
        row,
        env.px(env.metrics.radius_control),
    );
}
