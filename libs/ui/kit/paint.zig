//! Drawing helpers shared by components: token colors per tone, text runs that mirror in
//! RTL, focus rings, and the mark + label layout of checkboxes and radios.

const std = @import("std");
const ui = @import("ui_core");
const tokens = @import("ui_tokens");

pub const Env = ui.Env;
pub const Node = ui.Node;
pub const Rect = ui.geometry.Rect;
pub const Size = ui.geometry.Size;
pub const Placement = ui.frame.Placement;
pub const NodeState = ui.frame.NodeState;
pub const DisplayList = ui.display.DisplayList;
pub const Color = tokens.Color;
pub const Error = error{OutOfMemory};

pub fn toneColor(env: *const Env, tone: ui.ir.Tone) Color {
    const t = env.theme;
    return switch (tone) {
        .normal => t.text,
        .muted => t.text_muted,
        .accent => t.accent,
        .danger => t.danger,
        .success => t.success,
        .warning => t.warning,
    };
}

/// The fill of an interactive surface: pressed wins over hovered.
pub fn interactive(state: NodeState, rest: Color, hover: Color, pressed: Color) Color {
    return if (state.pressed) pressed else if (state.hovered) hover else rest;
}

pub fn textWidth(env: *const Env, style: ui.ir.TextStyle, copy: []const u8) i32 {
    return env.text.width(env.font(style), copy);
}

pub fn measureText(env: *const Env, style: ui.ir.TextStyle, copy: []const u8, max_w: i32) Size {
    const extent = ui.text.measure(env.text, env.font(style), copy, max_w);
    return .{
        .w = extent.width,
        .h = env.lineHeight(style) * @as(i32, @intCast(extent.lines)),
    };
}

pub const Run = struct {
    style: ui.ir.TextStyle = .body,
    color: Color,
    underline: bool = false,
};

/// One line at (x, y); `x` is the left edge in LTR. In RTL the line ends at `right`.
pub fn line(
    list: *DisplayList,
    env: *const Env,
    run: Run,
    copy: []const u8,
    x: i32,
    right: i32,
    y: i32,
) Error!void {
    const width = textWidth(env, run.style, copy);
    try list.add(.{ .text = .{
        .x = if (env.direction == .rtl) right - width else x,
        .y = y,
        .line_height = env.lineHeight(run.style),
        .font = env.font(run.style),
        .color = run.color,
        .text = copy,
        .underline = run.underline,
    } });
}

/// Wrapped lines inside `rect`, start-aligned for the reading direction.
pub fn paragraph(
    list: *DisplayList,
    env: *const Env,
    run: Run,
    copy: []const u8,
    rect: Rect,
) Error!void {
    const lines = try ui.text.wrap(list.arena, env.text, env.font(run.style), copy, rect.w);
    const height = env.lineHeight(run.style);
    for (lines, 0..) |l, k| {
        const y = rect.y + height * @as(i32, @intCast(k));
        try line(list, env, run, copy[l.start..l.end], rect.x, rect.right(), y);
    }
}

/// The ring sits one gap outside the control so it never merges with an accent fill.
pub fn focusRing(list: *DisplayList, env: *const Env, rect: Rect, radius: i32) Error!void {
    const ring = env.px(env.metrics.focus_ring);
    const outset = ring + env.px(2);
    try list.add(.{ .stroke = .{
        .rect = rect.inset(-outset),
        .radius = radius + outset,
        .width = ring,
        .color = env.theme.focus,
    } });
}

pub fn hairline(env: *const Env) i32 {
    return @max(1, env.px(1));
}

/// Checkbox and radio layout: a square mark beside a wrapped label, mirrored in RTL.
pub const Mark = struct {
    mark: Rect,
    label: Rect,

    pub fn size(env: *const Env) i32 {
        return env.px(tokens.checkbox_size);
    }

    pub fn measure(env: *const Env, copy: []const u8, max_w: i32) Size {
        const m = size(env);
        const gap = env.token(.sm);
        const label = measureText(env, .body, copy, @max(1, max_w - m - gap));
        return .{ .w = m + gap + label.w, .h = @max(m, label.h) };
    }

    pub fn place(env: *const Env, rect: Rect) Mark {
        const m = size(env);
        const gap = env.token(.sm);
        const top = rect.y + @divFloor(@max(0, env.lineHeight(.body) - m), 2);
        const ltr = env.direction == .ltr;
        return .{
            .mark = .{ .x = if (ltr) rect.x else rect.right() - m, .y = top, .w = m, .h = m },
            .label = .{
                .x = if (ltr) rect.x + m + gap else rect.x,
                .y = rect.y,
                .w = @max(0, rect.w - m - gap),
                .h = rect.h,
            },
        };
    }
};

test "line start follows the reading direction" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var list: DisplayList = .init(arena_state.allocator());
    const ltr = ui.testing.env(.{});
    const rtl = ui.testing.env(.{ .direction = .rtl });
    try line(&list, &ltr, .{ .color = ltr.theme.text }, "abc", 10, 100, 0);
    try line(&list, &rtl, .{ .color = rtl.theme.text }, "abc", 10, 100, 0);
    try std.testing.expectEqual(@as(i32, 10), list.items()[0].text.x);
    try std.testing.expectEqual(@as(i32, 100 - 3 * 7), list.items()[1].text.x);
}
