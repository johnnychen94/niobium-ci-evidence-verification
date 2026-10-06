//! SemanticTree: role, name, value, state and actions per node, the input to future
//! UIA / NSAccessibility / AT-SPI bridges and the protocol evidence for screens today.
//! Layout-only nodes (stack, spacer) have no role; their children attach to the nearest
//! ancestor that has one.

const std = @import("std");
const ir = @import("ir.zig");
const geometry = @import("geometry.zig");
const layout_mod = @import("layout.zig");
const input = @import("input.zig");

pub const Role = enum {
    window,
    group,
    text,
    image,
    button,
    checkbox,
    radiogroup,
    radio,
    link,
    progressbar,
    scrollarea,
    dialog,
    separator,
};

pub fn roleOf(n: ir.Node) ?Role {
    return switch (n.kind) {
        .window => .window,
        .card => .group,
        .text => .text,
        .image => .image,
        .button => .button,
        .checkbox => .checkbox,
        .radio_group => .radiogroup,
        .radio_option => .radio,
        .link => .link,
        .progress_bar, .progress_ring => .progressbar,
        .scroll => .scrollarea,
        .modal => .dialog,
        .divider => .separator,
        .folder_picker => if (n.fallback_active) .text else .button,
        .stack, .spacer => null,
    };
}

pub const State = struct {
    disabled: bool = false,
    checked: bool = false,
    selected: bool = false,
    focused: bool = false,
    busy: bool = false,
};

pub const Actions = struct {
    press: bool = false,
    toggle: bool = false,
    select: bool = false,
    scroll: bool = false,
};

pub const Node = struct {
    role: Role,
    depth: u32,
    id: []const u8,
    name: []const u8,
    value: []const u8 = "",
    bounds: geometry.Rect,
    focusable: bool,
    state: State,
    actions: Actions,
};

pub const Tree = struct {
    nodes: []const Node,

    pub fn write(t: Tree, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (t.nodes) |n| {
            try w.splatByteAll(' ', 2 * n.depth);
            try w.writeAll(@tagName(n.role));
            if (n.id.len > 0 and n.role != .radio) try w.print(" #{s}", .{n.id});
            try w.print(" \"{f}\"", .{std.zig.fmtString(n.name)});
            if (n.value.len > 0) try w.print(" value=\"{f}\"", .{std.zig.fmtString(n.value)});
            try w.print(" {f}", .{n.bounds});
            if (n.focusable) try w.writeAll(" focusable");
            inline for (@typeInfo(State).@"struct".field_names) |name| {
                if (@field(n.state, name)) try w.writeAll(" " ++ name);
            }
            inline for (@typeInfo(Actions).@"struct".field_names) |name| {
                if (@field(n.actions, name)) try w.writeAll(" +" ++ name);
            }
            try w.writeByte('\n');
        }
    }
};

fn semanticDepth(tree: ir.Tree, i: u32) u32 {
    var d: u32 = 0;
    var p = tree.nodes[i].parent;
    while (p != ir.no_parent) : (p = tree.nodes[p].parent) {
        if (roleOf(tree.nodes[p]) != null) d += 1;
    }
    return d;
}

fn value(arena: std.mem.Allocator, n: ir.Node) error{OutOfMemory}![]const u8 {
    return switch (n.kind) {
        .progress_bar => try std.fmt.allocPrint(arena, "{d}%", .{ir.percent(n.value)}),
        .folder_picker => n.detail,
        else => "",
    };
}

pub fn build(
    arena: std.mem.Allocator,
    tree: ir.Tree,
    l: layout_mod.Layout,
    s: *const input.Interaction,
) error{OutOfMemory}!Tree {
    var out: std.ArrayList(Node) = .empty;
    for (tree.nodes, 0..) |n, index| {
        const i: u32 = @intCast(index);
        const role = roleOf(n) orelse continue;
        const focused = s.focus.len > 0 and n.kind != .radio_option and std.mem.eql(
            u8,
            n.id,
            s.focus,
        );
        try out.append(arena, .{
            .role = role,
            .depth = semanticDepth(tree, i),
            .id = n.id,
            .name = n.text,
            .value = try value(arena, n),
            .bounds = l.rects[i],
            .focusable = input.focusable(n),
            .state = .{
                .disabled = !n.enabled and n.kind != .window,
                .checked = n.kind == .checkbox and n.checked,
                .selected = n.kind == .radio_option and n.selected,
                .focused = focused,
                .busy = n.kind == .progress_ring,
            },
            .actions = .{
                .press = n.enabled and switch (n.kind) {
                    .button, .link => n.action != null,
                    .folder_picker => !n.fallback_active,
                    else => false,
                },
                .toggle = n.enabled and n.kind == .checkbox,
                .select = n.enabled and n.kind == .radio_option,
                .scroll = n.kind == .scroll and l.scroll[i].max > 0,
            },
        });
    }
    return .{ .nodes = out.items };
}
