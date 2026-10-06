//! The component catalog: which states, themes, scales and content variants of each component
//! must have a pixel golden, and the sample tree each case renders.
//!
//! Cases per entry: every state in every theme at 100%; the default state in every theme at
//! each extra scale; every content variant (long, CJK, RTL) in light at 100%. Goldens live at
//! `tests/golden/kit/<name>/<state|content>-<theme>@<scale>.png`.

const std = @import("std");
const ui = @import("ui_core");
const tokens = @import("ui_tokens");
const samples = @import("catalog_samples.zig");

pub const State = enum { default, hover, pressed, focus, disabled, checked, fallback };
pub const Content = enum { long, cjk, rtl };

pub const Entry = struct {
    name: []const u8,
    states: []const State,
    themes: []const tokens.ThemeName = &.{ .light, .dark },
    scales: []const u16 = &.{ 150, 200 },
    content: []const Content = &.{},
    width: u16 = 240,
    height: u16 = 64,
};

pub const Catalog = struct { components: []const Entry };

pub const catalog: Catalog = @import("catalog.zon");

pub const Variant = union(enum) {
    state: State,
    content: Content,

    pub fn name(v: Variant) []const u8 {
        return switch (v) {
            .state => |s| @tagName(s),
            .content => |c| @tagName(c),
        };
    }
};

pub const Case = struct {
    variant: Variant,
    theme: tokens.ThemeName,
    scale: u16,
};

pub fn find(name: []const u8) ?Entry {
    for (catalog.components) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

pub fn cases(arena: std.mem.Allocator, entry: Entry) error{OutOfMemory}![]Case {
    var out: std.ArrayList(Case) = .empty;
    for (entry.states) |state| {
        for (entry.themes) |theme| {
            try out.append(
                arena,
                .{ .variant = .{ .state = state }, .theme = theme, .scale = 100 },
            );
        }
    }
    for (entry.scales) |scale| {
        for (entry.themes) |theme| {
            try out.append(
                arena,
                .{ .variant = .{ .state = .default }, .theme = theme, .scale = scale },
            );
        }
    }
    for (entry.content) |content| {
        try out.append(
            arena,
            .{ .variant = .{ .content = content }, .theme = .light, .scale = 100 },
        );
    }
    return out.items;
}

/// Path below the golden directory.
pub fn goldenPath(
    arena: std.mem.Allocator,
    entry: Entry,
    case: Case,
) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "kit/{s}/{s}-{t}@{d}.png", .{
        entry.name,
        case.variant.name(),
        case.theme,
        case.scale,
    });
}

pub const Sample = struct {
    tree: ui.Tree,
    interaction: ui.Interaction,
    direction: ui.env.Direction,
    capabilities: ui.env.Capabilities,
    /// Logical pixels; the renderer scales by the case.
    viewport: ui.geometry.Size,
};

/// `error.UiCatalogUnknown`: the entry names a component without a sample builder.
pub fn sample(arena: std.mem.Allocator, entry: Entry, case: Case) samples.Error!Sample {
    return samples.build(arena, entry, case);
}

test "catalog cases follow the documented matrix" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const button = find("button-primary").?;
    const all = try cases(arena, button);
    try std.testing.expectEqual(@as(usize, 5 * 2 + 2 * 2 + 3), all.len);
    try std.testing.expectEqualStrings(
        "kit/button-primary/hover-dark@100.png",
        try goldenPath(arena, button, all[3]),
    );
    try std.testing.expectEqualStrings(
        "kit/button-primary/rtl-light@100.png",
        try goldenPath(arena, button, all[all.len - 1]),
    );
}
