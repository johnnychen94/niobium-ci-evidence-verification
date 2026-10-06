//! The installer's five screens: ZON templates compiled against the contracts ViewModel at
//! comptime, the copy they show, the initial ViewModel, and the screen-flow controller.

const std = @import("std");
const contracts = @import("contracts");
const ui = @import("ui_core");
const kit = @import("ui_kit");

pub const copy = @import("copy.zig");
pub const model = @import("model.zig");
pub const controller = @import("controller.zig");

pub const ViewModel = contracts.ui.ViewModel;
pub const Screen = contracts.ui.Screen;
pub const Controller = controller.Controller;
pub const Command = controller.Command;

pub const templates = struct {
    pub const welcome = ui.compile(ViewModel, @import("templates/welcome.zon"));
    pub const options = ui.compile(ViewModel, @import("templates/options.zon"));
    pub const progress = ui.compile(ViewModel, @import("templates/progress.zon"));
    pub const failure = ui.compile(ViewModel, @import("templates/failure.zon"));
    pub const complete = ui.compile(ViewModel, @import("templates/complete.zon"));
};

pub fn template(screen: Screen) *const ui.TemplateNode {
    return switch (screen) {
        inline else => |s| &@field(templates, @tagName(s)),
    };
}

pub fn bindScreen(
    arena: std.mem.Allocator,
    c: *const Controller,
    capabilities: ui.env.Capabilities,
) ui.bind_mod.Error!ui.bind_mod.Bound {
    return ui.bind(ViewModel, arena, template(c.screen), &c.vm, capabilities);
}

/// Binds the current screen and builds its frame with the installer kit.
pub fn frame(
    arena: std.mem.Allocator,
    env: *const ui.Env,
    c: *const Controller,
    viewport: ui.geometry.Size,
    s: *const ui.Interaction,
) ui.bind_mod.Error!ui.Frame {
    const bound = try bindScreen(arena, c, env.capabilities);
    return ui.buildFrame(kit.Kit, arena, env, bound.tree, viewport, s);
}

test {
    _ = copy;
    _ = model;
    _ = controller;
    _ = @import("screens_test.zig");
}
