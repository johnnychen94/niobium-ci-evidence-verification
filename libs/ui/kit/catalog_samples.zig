//! Sample trees for catalog cases: a padded window holding the component (id "c"), with the
//! case's state applied as node flags or interaction.

const std = @import("std");
const ui = @import("ui_core");
const catalog = @import("catalog.zig");

const Node = ui.Node;
pub const Error = error{ OutOfMemory, UiCatalogUnknown };

const Component = enum {
    @"button-primary",
    @"button-secondary",
    checkbox,
    radio,
    link,
    text,
    @"folder-picker",
    @"progress-bar",
    @"progress-ring",
    card,
    divider,
    image,
    scroll,
    modal,
};

const id = "c";

const Copy = struct {
    normal: []const u8,
    long: []const u8,
    cjk: []const u8,

    fn pick(c: Copy, variant: catalog.Variant) []const u8 {
        return switch (variant) {
            .content => |content| switch (content) {
                .long => c.long,
                .cjk => c.cjk,
                .rtl => c.normal,
            },
            .state => c.normal,
        };
    }
};

const Builder = struct {
    arena: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    open_nodes: [8]u32 = undefined, // SAFETY: only [0..depth] is read.
    depth: u8 = 0,
    enabled: bool,

    fn add(b: *Builder, n: Node) Error!u32 {
        var node = n;
        node.parent = if (b.depth == 0) ui.ir.no_parent else b.open_nodes[b.depth - 1];
        if (node.id.len > 0 or node.kind == .radio_option) node.enabled = b.enabled;
        const i: u32 = @intCast(b.nodes.items.len);
        node.end = i + 1;
        try b.nodes.append(b.arena, node);
        return i;
    }

    fn leaf(b: *Builder, n: Node) Error!void {
        const i = try b.add(n);
        std.debug.assert(b.nodes.items[i].end == i + 1);
    }

    fn open(b: *Builder, n: Node) Error!void {
        std.debug.assert(b.depth < b.open_nodes.len);
        b.open_nodes[b.depth] = try b.add(n);
        b.depth += 1;
    }

    fn close(b: *Builder) void {
        b.depth -= 1;
        b.nodes.items[b.open_nodes[b.depth]].end = @intCast(b.nodes.items.len);
    }
};

pub fn build(
    arena: std.mem.Allocator,
    entry: catalog.Entry,
    case: catalog.Case,
) Error!catalog.Sample {
    const component = std.meta.stringToEnum(Component, entry.name) orelse
        return error.UiCatalogUnknown;
    const state: catalog.State = switch (case.variant) {
        .state => |s| s,
        .content => .default,
    };
    var b: Builder = .{ .arena = arena, .enabled = state != .disabled };
    try b.open(.{ .kind = .window, .padding = .md, .gap = .sm, .width = .fill, .height = .fill });
    try body(&b, component, case.variant, state);
    b.close();
    var s: ui.Interaction = .{};
    const target: ui.input.Target = .{ .id = id, .index = if (component == .radio) 1 else 0 };
    switch (state) {
        .hover => s.hover = target,
        .pressed => {
            s.hover = target;
            s.pressed = target;
        },
        .focus => {
            s.focus = id;
            s.focus_visible = true;
        },
        else => {},
    }
    return .{
        .tree = .{ .nodes = b.nodes.items },
        .interaction = s,
        .direction = if (case.variant == .content and case.variant.content == .rtl) .rtl else .ltr,
        .capabilities = .{ .native_folder_picker = state != .fallback },
        .viewport = .{ .w = entry.width, .h = entry.height },
    };
}

fn body(
    b: *Builder,
    component: Component,
    variant: catalog.Variant,
    state: catalog.State,
) Error!void {
    switch (component) {
        .@"button-primary", .@"button-secondary" => {
            const copy: Copy = if (component == .@"button-primary")
                .{
                    .normal = "Install",
                    .long = "Installation fortsetzen und abschliessen",
                    .cjk = "安装",
                }
            else
                .{ .normal = "Back", .long = "Zurueck zur vorherigen Seite gehen", .cjk = "返回" };
            try b.leaf(.{
                .kind = .button,
                .id = id,
                .text = copy.pick(variant),
                .variant = if (component == .@"button-primary") .primary else .secondary,
                .action = .install,
            });
        },
        .checkbox => try b.leaf(.{
            .kind = .checkbox,
            .id = id,
            .checked = state == .checked,
            .text = (Copy{
                .normal = "Create a desktop shortcut",
                .long = "Create a desktop shortcut and add Hello to the menu for every user",
                .cjk = "创建桌面快捷方式",
            }).pick(variant),
        }),
        .radio => try radio(b, variant),
        .link => try b.leaf(
            .{ .kind = .link, .id = id, .text = "View license agreement", .action = .show_license },
        ),
        .text => try text(b, variant),
        .@"folder-picker" => try b.leaf(.{
            .kind = .folder_picker,
            .id = id,
            .text = "Location",
            .detail = if (variant == .content and variant.content == .long)
                "/Users/me/Library/Application Support/Very Long Vendor Name/Hello/Versions/1.0.0"
            else
                "/Users/me/Applications/Hello",
            .fallback_active = state == .fallback,
        }),
        .@"progress-bar" => try b.leaf(
            .{ .kind = .progress_bar, .id = id, .value = 0.37, .width = .fill },
        ),
        .@"progress-ring" => try b.leaf(.{ .kind = .progress_ring, .id = id }),
        .divider => try b.leaf(.{ .kind = .divider, .width = .fill }),
        .image => try b.leaf(.{ .kind = .image, .id = id, .text = "Hello logo" }),
        .card, .scroll, .modal => try container(b, component),
    }
}

fn radio(b: *Builder, variant: catalog.Variant) Error!void {
    const cjk = variant == .content and variant.content == .cjk;
    try b.open(.{ .kind = .radio_group, .id = id, .text = "Install for", .gap = .xs });
    try b.leaf(
        .{
            .kind = .radio_option,
            .id = id,
            .index = 0,
            .selected = true,
            .text = if (cjk) "仅我" else "Just me",
        },
    );
    try b.leaf(.{
        .kind = .radio_option,
        .id = id,
        .index = 1,
        .text = if (cjk) "此计算机上的所有用户" else "Everyone on this computer",
    });
    b.close();
}

fn text(b: *Builder, variant: catalog.Variant) Error!void {
    const copy: Copy = .{
        .normal = "Hello will be installed for your user account.",
        .long = "Hello will be installed for your user account. No administrator rights are " ++
            "needed, and you can remove it at any time from the settings.",
        .cjk = "Hello 将安装到你的用户目录，无需管理员权限，可以随时卸载。",
    };
    const cjk = variant == .content and variant.content == .cjk;
    const title = if (cjk) "安装 Hello" else "Install Hello";
    try b.leaf(.{ .kind = .text, .style = .title, .text = title });
    try b.leaf(.{ .kind = .text, .text = copy.pick(variant), .width = .fill });
    try b.leaf(.{ .kind = .text, .style = .caption, .tone = .muted, .text = "Version 1.0.0" });
}

fn container(b: *Builder, component: Component) Error!void {
    const paragraph = "Hello keeps your files in sync. This text is long enough to " ++
        "overflow the scroll area so that its scrollbar shows.";
    switch (component) {
        .card => {
            try b.open(.{ .kind = .card, .padding = .md, .gap = .xs, .width = .fill });
            try b.leaf(.{ .kind = .text, .style = .heading, .text = "Ready to install" });
            try b.leaf(.{ .kind = .text, .tone = .muted, .text = "Takes about a minute." });
            b.close();
        },
        .scroll => {
            try b.open(
                .{
                    .kind = .scroll,
                    .id = id,
                    .text = "Details",
                    .width = .fill,
                    .max_height = .logo,
                },
            );
            try b.leaf(.{ .kind = .text, .text = paragraph, .width = .fill });
            b.close();
        },
        .modal => {
            try b.leaf(.{ .kind = .text, .text = paragraph, .width = .fill });
            try b.open(
                .{
                    .kind = .modal,
                    .id = id,
                    .text = "Stop installation?",
                    .padding = .lg,
                    .gap = .md,
                },
            );
            try b.leaf(.{ .kind = .text, .style = .heading, .text = "Stop installation?" });
            try b.open(.{ .kind = .stack, .axis = .row, .gap = .sm, .width = .fill });
            try b.leaf(.{ .kind = .spacer, .width = .fill });
            try b.leaf(.{ .kind = .button, .id = "keep", .text = "Continue", .action = .back });
            try b.leaf(
                .{
                    .kind = .button,
                    .id = "stop",
                    .text = "Stop",
                    .variant = .primary,
                    .action = .close,
                },
            );
            b.close();
            b.close();
        },
        else => unreachable,
    }
}
