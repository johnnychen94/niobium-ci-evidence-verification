//! Installer UI kit: the `Kit` that ui_core's layout and frame builder call for every node,
//! dispatching to one directory per component, plus brand theming and the component catalog.

const ui = @import("ui_core");
const paint = @import("paint.zig");

pub const theme = @import("theme.zig");
pub const catalog = @import("catalog.zig");
pub const button = @import("button/root.zig");
pub const text = @import("text/root.zig");
pub const checkbox = @import("checkbox/root.zig");
pub const radio = @import("radio/root.zig");
pub const progress = @import("progress/root.zig");
pub const surface = @import("surface/root.zig");
pub const folder_picker = @import("folder_picker/root.zig");
pub const image = @import("image/root.zig");

const Env = ui.Env;
const Node = ui.Node;

pub const Kit = struct {
    pub fn measure(env: *const Env, n: *const Node, max_w: i32) ui.geometry.Size {
        return switch (n.kind) {
            .text, .link => text.measure(env, n, max_w),
            .button => button.measure(env, n, max_w),
            .checkbox => checkbox.measure(env, n, max_w),
            .radio_option => radio.measure(env, n, max_w),
            .progress_bar, .progress_ring => progress.measure(env, n, max_w),
            .folder_picker => folder_picker.measure(env, n, max_w),
            .image => image.measure(env, n, max_w),
            .divider => surface.measureDivider(env, max_w),
            .window, .stack, .card, .radio_group, .scroll, .modal, .spacer => .zero,
        };
    }

    pub fn emit(
        env: *const Env,
        n: *const Node,
        at: paint.Placement,
        state: paint.NodeState,
        list: *paint.DisplayList,
    ) paint.Error!void {
        switch (n.kind) {
            .window, .card, .modal, .divider => try surface.emit(env, n, at, list),
            .text => try text.emitText(env, n, at, list),
            .link => try text.emitLink(env, n, at, state, list),
            .button => try button.emit(env, n, at, state, list),
            .checkbox => try checkbox.emit(env, n, at, state, list),
            .radio_option => try radio.emit(env, n, at, state, list),
            .progress_bar => try progress.emitBar(env, n, at, list),
            .progress_ring => try progress.emitRing(env, n, at, list),
            .folder_picker => try folder_picker.emit(env, n, at, state, list),
            .image => try image.emit(env, n, at, list),
            .stack, .radio_group, .scroll, .spacer => {},
        }
    }

    pub fn overlay(
        env: *const Env,
        n: *const Node,
        at: paint.Placement,
        state: paint.NodeState,
        list: *paint.DisplayList,
    ) paint.Error!void {
        _ = state;
        try surface.overlay(env, n, at, list);
    }
};

test {
    _ = paint;
    _ = theme;
    _ = catalog;
    _ = button;
    _ = text;
    _ = checkbox;
    _ = radio;
    _ = progress;
    _ = surface;
    _ = folder_picker;
    _ = image;
    _ = @import("kit_test.zig");
}
