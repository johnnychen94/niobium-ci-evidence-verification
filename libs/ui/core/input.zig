//! Focus and input. Interaction state is keyed by node ids (stable across rebinding), events
//! resolve against the last layout, and activation yields an `Intent` for the screen
//! controller. While a modal is shown only its subtree receives input.

const std = @import("std");
const ir = @import("ir.zig");
const geometry = @import("geometry.zig");
const layout_mod = @import("layout.zig");
const env_mod = @import("env.zig");

const Tree = ir.Tree;
const Layout = layout_mod.Layout;
const Point = geometry.Point;

pub const Key = enum { tab, shift_tab, enter, space, escape, up, down, left, right };

pub const Event = union(enum) {
    pointer_move: Point,
    pointer_down: Point,
    pointer_up: Point,
    pointer_leave,
    wheel: struct { at: Point, dy: i32 },
    key: Key,
};

pub const Intent = union(enum) {
    action: ir.Action,
    toggle: []const u8,
    select: struct { id: []const u8, index: u32 },
    choose_folder: []const u8,
};

/// A node, or one option of a radio group (`index`).
pub const Target = struct {
    id: []const u8 = "",
    index: u32 = 0,

    pub fn none(t: Target) bool {
        return t.id.len == 0;
    }

    pub fn eql(a: Target, b: Target) bool {
        return a.index == b.index and std.mem.eql(u8, a.id, b.id);
    }
};

pub const max_scrolls = 8;

pub const Interaction = struct {
    hover: Target = .{},
    pressed: Target = .{},
    focus: []const u8 = "",
    /// Focus rings show after keyboard navigation, not after a click.
    focus_visible: bool = false,
    scrolls: [max_scrolls]layout_mod.ScrollOffset = @splat(.{ .id = "", .offset = 0 }),
    scroll_len: u8 = 0,

    pub fn offsets(s: *const Interaction) []const layout_mod.ScrollOffset {
        return s.scrolls[0..s.scroll_len];
    }

    pub fn setOffset(s: *Interaction, id: []const u8, offset: i32) void {
        for (s.scrolls[0..s.scroll_len]) |*o| {
            if (std.mem.eql(u8, o.id, id)) {
                o.offset = offset;
                return;
            }
        }
        const slot = if (s.scroll_len < max_scrolls) s.scroll_len else max_scrolls - 1;
        s.scrolls[slot] = .{ .id = id, .offset = offset };
        if (s.scroll_len < max_scrolls) s.scroll_len += 1;
    }

    /// Drops references to nodes that disappeared or became disabled after rebinding.
    pub fn reconcile(s: *Interaction, tree: Tree) void {
        if (!live(tree, s.hover.id)) s.hover = .{};
        if (!live(tree, s.pressed.id)) s.pressed = .{};
        if (!live(tree, s.focus)) s.focus = "";
    }
};

fn live(tree: Tree, id: []const u8) bool {
    const i = tree.find(id) orelse return false;
    return tree.nodes[i].enabled;
}

/// The subtree that accepts input: the modal when one is shown, else the whole tree.
fn scope(tree: Tree) struct { start: u32, end: u32 } {
    for (tree.nodes, 0..) |n, i| {
        if (n.kind == .modal) return .{ .start = @intCast(i), .end = n.end };
    }
    return .{ .start = 0, .end = @intCast(tree.nodes.len) };
}

fn pressable(n: ir.Node) bool {
    if (!n.enabled) return false;
    return switch (n.kind) {
        .button, .link => n.action != null,
        .checkbox, .radio_option => true,
        .folder_picker => !n.fallback_active,
        else => false,
    };
}

pub fn focusable(n: ir.Node) bool {
    if (!n.enabled) return false;
    return switch (n.kind) {
        .button, .link => n.action != null,
        .checkbox, .radio_group => true,
        .folder_picker => !n.fallback_active,
        else => false,
    };
}

fn targetOf(n: ir.Node) Target {
    return .{ .id = n.id, .index = if (n.kind == .radio_option) n.index else 0 };
}

fn hit(tree: Tree, l: Layout, p: Point) Target {
    const s = scope(tree);
    var i = s.end;
    while (i > s.start) {
        i -= 1;
        const n = tree.nodes[i];
        if (pressable(n) and l.visible(i).contains(p)) return targetOf(n);
    }
    return .{};
}

fn activate(tree: Tree, t: Target) ?Intent {
    const i = tree.find(t.id) orelse return null;
    const n = tree.nodes[i];
    if (!n.enabled) return null;
    return switch (n.kind) {
        .button, .link => if (n.action) |a| .{ .action = a } else null,
        .checkbox => .{ .toggle = n.id },
        .radio_group => .{ .select = .{ .id = n.id, .index = t.index } },
        .folder_picker => if (n.fallback_active) null else .{ .choose_folder = n.id },
        else => null,
    };
}

pub fn handle(
    tree: Tree,
    l: Layout,
    direction: env_mod.Direction,
    s: *Interaction,
    event: Event,
) ?Intent {
    switch (event) {
        .pointer_move => |p| s.hover = hit(tree, l, p),
        .pointer_leave => s.hover = .{},
        .pointer_down => |p| {
            s.pressed = hit(tree, l, p);
            if (!s.pressed.none()) {
                const i = tree.find(s.pressed.id).?;
                if (focusable(tree.nodes[i])) s.focus = s.pressed.id;
                s.focus_visible = false;
            }
        },
        .pointer_up => |p| {
            const released = hit(tree, l, p);
            const pressed = s.pressed;
            s.pressed = .{};
            if (!pressed.none() and pressed.eql(released)) return activate(tree, pressed);
        },
        .wheel => |w| wheel(tree, l, s, w.at, w.dy),
        .key => |k| return key(tree, l, direction, s, k),
    }
    return null;
}

fn wheel(tree: Tree, l: Layout, s: *Interaction, at: Point, dy: i32) void {
    const sc = scope(tree);
    var i = sc.end;
    while (i > sc.start) {
        i -= 1;
        if (tree.nodes[i].kind != .scroll or !l.visible(i).contains(at)) continue;
        const extent = l.scroll[i];
        s.setOffset(tree.nodes[i].id, std.math.clamp(extent.offset + dy, 0, extent.max));
        return;
    }
}

fn key(tree: Tree, l: Layout, direction: env_mod.Direction, s: *Interaction, k: Key) ?Intent {
    const focused = tree.find(s.focus);
    switch (k) {
        .tab, .shift_tab => {
            moveFocus(tree, s, k == .tab);
            reveal(tree, l, s);
        },
        .enter => {
            if (focused) |i| switch (tree.nodes[i].kind) {
                .button, .link, .folder_picker => return activate(tree, .{ .id = s.focus }),
                else => {},
            };
            const default = findButton(tree, &.{}, .primary) orelse return null;
            return activate(tree, .{ .id = tree.nodes[default].id });
        },
        .space => if (focused) |i| switch (tree.nodes[i].kind) {
            .button, .link, .folder_picker, .checkbox => return activate(tree, .{ .id = s.focus }),
            else => {},
        },
        .escape => {
            // Escape dismisses: a modal prefers close/back over cancel, a page prefers cancel.
            const order: []const ir.Action = if (scope(tree).start > 0)
                &.{ .close, .back, .cancel }
            else
                &.{ .cancel, .close };
            for (order) |action| {
                const i = findButton(tree, &.{action}, null) orelse continue;
                return activate(tree, .{ .id = tree.nodes[i].id });
            }
            return null;
        },
        .up, .down, .left, .right => {
            const i = focused orelse return null;
            if (tree.nodes[i].kind != .radio_group) return null;
            const forward = switch (k) {
                .down => true,
                .up => false,
                .right => direction == .ltr,
                else => direction == .rtl,
            };
            return step(tree, i, forward);
        },
    }
    return null;
}

/// First enabled button in scope with one of `actions` (any when empty) and `variant`.
fn findButton(tree: Tree, actions: []const ir.Action, variant: ?ir.Variant) ?u32 {
    const s = scope(tree);
    var i = s.start;
    while (i < s.end) : (i += 1) {
        const n = tree.nodes[i];
        if (n.kind != .button or !pressable(n)) continue;
        if (variant) |v| if (n.variant != v) continue;
        if (actions.len > 0 and std.mem.findScalar(
            ir.Action,
            actions,
            n.action.?,
        ) == null) continue;
        return i;
    }
    return null;
}

fn step(tree: Tree, group: u32, forward: bool) ?Intent {
    const n = tree.nodes[group];
    const count = n.end - group - 1;
    if (count == 0) return null;
    var current: u32 = 0;
    for (tree.nodes[group + 1 .. n.end]) |o| {
        if (o.selected) current = o.index;
    }
    const next = if (forward) @min(current + 1, count - 1) else current -| 1;
    if (next == current) return null;
    return .{ .select = .{ .id = n.id, .index = next } };
}

fn moveFocus(tree: Tree, s: *Interaction, forward: bool) void {
    const sc = scope(tree);
    var stops: [ir_max_stops]u32 = undefined; // SAFETY: only stops[0..count] is read.
    var count: usize = 0;
    var current: ?usize = null;
    var i = sc.start;
    while (i < sc.end and count < stops.len) : (i += 1) {
        if (!focusable(tree.nodes[i])) continue;
        if (std.mem.eql(u8, tree.nodes[i].id, s.focus)) current = count;
        stops[count] = i;
        count += 1;
    }
    s.focus_visible = true;
    if (count == 0) {
        s.focus = "";
        return;
    }
    const next = if (current) |c|
        (if (forward) (c + 1) % count else (c + count - 1) % count)
    else if (forward) 0 else count - 1;
    s.focus = tree.nodes[stops[next]].id;
}

const ir_max_stops = 128;

/// Scrolls the focused node's nearest scroll ancestor so the node is fully visible.
fn reveal(tree: Tree, l: Layout, s: *Interaction) void {
    const i = tree.find(s.focus) orelse return;
    var p = tree.nodes[i].parent;
    while (p != ir.no_parent) : (p = tree.nodes[p].parent) {
        if (tree.nodes[p].kind != .scroll) continue;
        const view = l.rects[p];
        const r = l.rects[i];
        const extent = l.scroll[p];
        var offset = extent.offset;
        if (r.y < view.y) offset -= view.y - r.y;
        if (r.bottom() > view.bottom()) offset += r.bottom() - view.bottom();
        s.setOffset(tree.nodes[p].id, std.math.clamp(offset, 0, extent.max));
        return;
    }
}
