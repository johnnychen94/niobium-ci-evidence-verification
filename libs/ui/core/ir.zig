//! The closed node vocabulary (docs/spec/ui-ir-v1.md) and the bound UiTree: a flat preorder
//! array where `end` is one past a node's last descendant.

const std = @import("std");

pub const Kind = enum {
    window,
    stack,
    card,
    text,
    image,
    button,
    checkbox,
    radio_group,
    link,
    progress_bar,
    progress_ring,
    scroll,
    modal,
    divider,
    spacer,
    folder_picker,
    /// One option of a radio_group. Produced by bind; templates cannot name it.
    radio_option,

    /// Kinds whose children the layout arranges as a stack.
    pub fn isContainer(k: Kind) bool {
        return switch (k) {
            .window, .stack, .card, .radio_group, .modal, .scroll => true,
            else => false,
        };
    }
};

pub const Action = enum {
    next,
    back,
    install,
    cancel,
    close,
    launch,
    retry,
    show_license,
    choose_folder,
};

pub const Axis = enum { row, column };
pub const Align = enum { start, center, end, stretch };
pub const TextStyle = enum { title, heading, body, caption, mono };
pub const Tone = enum { normal, muted, accent, danger, success, warning };
pub const Variant = enum { primary, secondary };
pub const ImageSource = enum { logo, icon };
pub const Fallback = enum { text };

/// Spacing and size tokens (libs/ui/tokens/tokens.json `space` and `size`).
pub const Token = enum { none, xs, sm, md, lg, xl, xxl, logo, list, field, modal };

pub const Extent = union(enum) {
    content,
    fill,
    fixed: Token,

    pub fn format(e: Extent, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (e) {
            .content, .fill => try w.writeAll(@tagName(e)),
            .fixed => |t| try w.print("fixed:{t}", .{t}),
        }
    }
};

pub const no_parent = std.math.maxInt(u32);

pub const Node = struct {
    kind: Kind,
    parent: u32 = no_parent,
    end: u32 = 0,
    id: []const u8 = "",
    /// Text content, label, or title, placeholders already substituted.
    text: []const u8 = "",
    style: TextStyle = .body,
    tone: Tone = .normal,
    variant: Variant = .secondary,
    action: ?Action = null,
    axis: Axis = .column,
    gap: Token = .none,
    padding: Token = .none,
    alignment: Align = .start,
    width: Extent = .content,
    height: Extent = .content,
    max_height: Token = .none,
    source: ImageSource = .logo,
    enabled: bool = true,
    checked: bool = false,
    selected: bool = false,
    /// progress_bar fraction in [0, 1].
    value: f32 = 0,
    /// radio_option position inside its group.
    index: u32 = 0,
    /// folder_picker: the bound path.
    detail: []const u8 = "",
    /// folder_picker drawn by its declared fallback because the backend lacks the capability.
    fallback_active: bool = false,
};

pub const Tree = struct {
    nodes: []const Node,

    pub fn firstChild(t: Tree, i: u32) ?u32 {
        const child = i + 1;
        return if (child < t.nodes[i].end) child else null;
    }

    pub fn nextSibling(t: Tree, child: u32) ?u32 {
        const parent = t.nodes[child].parent;
        if (parent == no_parent) return null;
        const next = t.nodes[child].end;
        return if (next < t.nodes[parent].end) next else null;
    }

    pub fn find(t: Tree, id: []const u8) ?u32 {
        if (id.len == 0) return null;
        for (t.nodes, 0..) |n, i| {
            if (n.kind != .radio_option and std.mem.eql(u8, n.id, id)) return @intCast(i);
        }
        return null;
    }

    pub fn depth(t: Tree, i: u32) u32 {
        var d: u32 = 0;
        var p = t.nodes[i].parent;
        while (p != no_parent) : (p = t.nodes[p].parent) d += 1;
        return d;
    }

    /// Textual snapshot: one line per node, indented by depth.
    pub fn write(t: Tree, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (t.nodes, 0..) |n, i| {
            try w.splatByteAll(' ', 2 * t.depth(@intCast(i)));
            try w.writeAll(@tagName(n.kind));
            if (n.id.len > 0 and n.kind != .radio_option) try w.print(" #{s}", .{n.id});
            try writeAttributes(w, n);
            if (n.text.len > 0) try w.print(" \"{f}\"", .{std.zig.fmtString(n.text)});
            try w.writeByte('\n');
        }
    }
};

fn writeAttributes(w: *std.Io.Writer, n: Node) std.Io.Writer.Error!void {
    switch (n.kind) {
        .window, .modal => {},
        .stack, .card, .radio_group => {
            if (n.kind == .stack) try w.print(" {t}", .{n.axis});
            try w.print(" gap={t} pad={t} align={t}", .{ n.gap, n.padding, n.alignment });
        },
        .text => try w.print(" {t} {t}", .{ n.style, n.tone }),
        .image => try w.print(" {t}", .{n.source}),
        .button => try w.print(" {t} action={t}", .{ n.variant, n.action.? }),
        .link => try w.print(" action={t}", .{n.action.?}),
        .checkbox => try w.writeAll(if (n.checked) " checked" else " unchecked"),
        .radio_option => {
            try w.print(" {d}", .{n.index});
            if (n.selected) try w.writeAll(" selected");
        },
        .progress_bar => try w.print(" {d}%", .{percent(n.value)}),
        .scroll => try w.print(" max={t}", .{n.max_height}),
        .folder_picker => {
            try w.print(" path=\"{f}\"", .{std.zig.fmtString(n.detail)});
            if (n.fallback_active) try w.writeAll(" fallback=text");
        },
        .progress_ring, .divider, .spacer => {},
    }
    if (!n.enabled) try w.writeAll(" disabled");
    try w.print(" w={f} h={f}", .{ n.width, n.height });
}

/// Progress as a whole percentage, clamped; NaN reads as 0.
pub fn percent(value: f32) u32 {
    if (!(value > 0)) return 0;
    if (value >= 1) return 100;
    return @intFromFloat(@round(value * 100));
}

test "tree navigation" {
    const nodes = [_]Node{
        .{ .kind = .window, .end = 4 },
        .{ .kind = .stack, .parent = 0, .end = 3 },
        .{ .kind = .text, .parent = 1, .end = 3, .text = "a" },
        .{ .kind = .divider, .parent = 0, .end = 4 },
    };
    const t: Tree = .{ .nodes = &nodes };
    try std.testing.expectEqual(@as(?u32, 1), t.firstChild(0));
    try std.testing.expectEqual(@as(?u32, 3), t.nextSibling(1));
    try std.testing.expectEqual(@as(?u32, null), t.nextSibling(3));
    try std.testing.expectEqual(@as(?u32, null), t.firstChild(2));
    try std.testing.expectEqual(@as(u32, 2), t.depth(2));
    try std.testing.expectEqual(@as(u32, 37), percent(0.371));
    try std.testing.expectEqual(@as(u32, 0), percent(std.math.nan(f32)));
}
