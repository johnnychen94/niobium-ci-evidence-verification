//! One frame: layout, DisplayList, SemanticTree. Each node is drawn by
//! `Kit.emit(env, node, placement, state, list)` before its children; a Kit may also declare
//! `overlay` with the same signature, drawn after the subtree (scrollbars). The same tree,
//! viewport, env and interaction always produce byte-identical snapshots.

const std = @import("std");
const ir = @import("ir.zig");
const geometry = @import("geometry.zig");
const env_mod = @import("env.zig");
const layout_mod = @import("layout.zig");
const display = @import("display.zig");
const semantics = @import("semantics.zig");
const input = @import("input.zig");
const order = @import("order.zig");

pub const Error = error{OutOfMemory};

/// Interaction facts a component draws; disabled is `node.enabled`.
pub const NodeState = struct {
    hovered: bool = false,
    pressed: bool = false,
    /// Keyboard focus: draw the focus ring.
    focused: bool = false,
};

/// Where a node sits: its rect, the visible area it may draw into, and for scroll areas the
/// applied offset and range.
pub const Placement = struct {
    rect: geometry.Rect,
    clip: geometry.Rect,
    scroll: layout_mod.ScrollExtent = .{},
};

pub const Frame = struct {
    tree: ir.Tree,
    layout: layout_mod.Layout,
    display: display.DisplayList,
    semantics: semantics.Tree,
};

pub fn nodeState(n: ir.Node, s: *const input.Interaction) NodeState {
    const target: input.Target = .{
        .id = n.id,
        .index = if (n.kind == .radio_option) n.index else 0,
    };
    const owns_focus = s.focus_visible and n.id.len > 0 and std.mem.eql(u8, n.id, s.focus);
    return .{
        .hovered = n.enabled and n.id.len > 0 and s.hover.eql(target),
        .pressed = n.enabled and n.id.len > 0 and s.pressed.eql(target),
        .focused = owns_focus and (n.kind != .radio_option or n.selected),
    };
}

pub fn build(
    comptime Kit: type,
    arena: std.mem.Allocator,
    env: *const env_mod.Env,
    template_tree: ir.Tree,
    viewport: geometry.Size,
    s: *const input.Interaction,
) Error!Frame {
    const tree = try order.buttons(arena, template_tree, env.metrics.primary_on_right);
    const l = try layout_mod.compute(Kit, arena, env, tree, viewport, s.offsets());
    var list: display.DisplayList = .init(arena);
    var open: std.ArrayList(u32) = .empty;
    for (tree.nodes, 0..) |n, index| {
        const i: u32 = @intCast(index);
        try close(Kit, env, tree, l, s, &open, &list, i);
        const state = nodeState(n, s);
        const radio_focus = n.kind == .radio_group and state.focused;
        try Kit.emit(env, &n, placement(l, i), if (radio_focus) .{} else state, &list);
        if (n.kind == .scroll) {
            try list.add(.{ .clip = l.visible(i) });
            try open.append(arena, i);
        }
    }
    try close(Kit, env, tree, l, s, &open, &list, @intCast(tree.nodes.len));
    return .{
        .tree = tree,
        .layout = l,
        .display = list,
        .semantics = try semantics.build(arena, tree, l, s),
    };
}

fn placement(l: layout_mod.Layout, i: u32) Placement {
    return .{ .rect = l.rects[i], .clip = l.clips[i], .scroll = l.scroll[i] };
}

/// Ends every open scroll whose subtree finishes before node `before`.
fn close(
    comptime Kit: type,
    env: *const env_mod.Env,
    tree: ir.Tree,
    l: layout_mod.Layout,
    s: *const input.Interaction,
    open: *std.ArrayList(u32),
    list: *display.DisplayList,
    before: u32,
) Error!void {
    // loop-bound: pops at most one entry per open scroll.
    while (open.items.len > 0) {
        const top = open.items[open.items.len - 1];
        if (tree.nodes[top].end > before) return;
        open.items.len -= 1;
        try list.add(.unclip);
        if (@hasDecl(Kit, "overlay")) {
            try Kit.overlay(
                env,
                &tree.nodes[top],
                placement(l, top),
                nodeState(tree.nodes[top], s),
                list,
            );
        }
    }
}
