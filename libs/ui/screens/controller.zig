//! Screen flow: welcome → options (install only) → progress → complete | failure. The
//! controller turns input intents into ViewModel changes and engine commands; the frontend
//! rebinds the current screen after every call that returns or changes state.

const std = @import("std");
const contracts = @import("contracts");
const ui = @import("ui_core");
const copy = @import("copy.zig");

const Screen = contracts.ui.Screen;
const ViewModel = contracts.ui.ViewModel;
const Intent = ui.input.Intent;

/// What the frontend asks the engine for. `start` carries the same choices the CLI flags
/// carry, so GUI and CLI build the same request (N1-INV-07).
pub const Start = struct {
    operation: contracts.ui.Operation,
    scope: contracts.Scope,
    /// Set only when the user picked a folder; otherwise the engine default applies.
    install_dir: ?[]const u8 = null,
};

pub const Command = union(enum) {
    start: Start,
    /// Stop the running operation; it ends with `finish(.canceled)` or its real outcome.
    cancel,
    launch,
    close,
    choose_folder,
};

pub const Outcome = union(enum) {
    succeeded,
    failed: Failure,
    canceled,
};

pub const Failure = struct {
    /// Stable error name.
    code: []const u8,
    message: []const u8,
    retryable: bool,
};

/// Radio option order of `scope` in templates/options.zon.
pub const scope_options = [_]contracts.Scope{ .user, .machine };

/// The engine's default install location per scope, shown until the user picks a folder.
pub const Defaults = struct {
    user_location: []const u8 = "",
    machine_location: []const u8 = "",

    pub fn location(d: Defaults, scope: contracts.Scope) []const u8 {
        return switch (scope) {
            .user => d.user_location,
            .machine => d.machine_location,
        };
    }
};

pub const Controller = struct {
    arena: std.mem.Allocator,
    screen: Screen = .welcome,
    vm: ViewModel,
    defaults: Defaults,
    install_dir: ?[]const u8 = null,

    pub fn init(arena: std.mem.Allocator, vm: ViewModel, defaults: Defaults) Controller {
        var c: Controller = .{ .arena = arena, .vm = vm, .defaults = defaults };
        if (c.vm.location.len == 0) c.vm.location = defaults.location(vm.scope);
        return c;
    }

    pub fn handle(c: *Controller, intent: Intent) ?Command {
        return switch (intent) {
            .toggle => null,
            .select => |s| select(c, s.id, s.index),
            .choose_folder => c.chooseFolder(),
            .action => |a| c.action(a),
        };
    }

    fn chooseFolder(c: *Controller) ?Command {
        return if (c.screen == .options and c.vm.location_editable) .choose_folder else null;
    }

    fn select(c: *Controller, id: []const u8, index: u32) ?Command {
        if (!std.mem.eql(u8, id, "scope") or !c.vm.scope_editable) return null;
        if (index >= scope_options.len) return null;
        c.vm.scope = scope_options[index];
        if (c.install_dir == null) c.vm.location = c.defaults.location(c.vm.scope);
        return null;
    }

    fn action(c: *Controller, a: ui.ir.Action) ?Command {
        switch (a) {
            .show_license => c.vm.show_license = c.vm.has_license,
            .next => if (c.screen == .welcome and c.vm.has_options) {
                c.screen = .options;
            },
            .back => {
                if (c.vm.confirm_cancel) {
                    c.vm.confirm_cancel = false;
                } else if (c.screen == .options) c.screen = .welcome;
            },
            .install => if (c.screen == .options or (c.screen == .welcome and c.vm.no_options)) {
                return c.start();
            },
            .retry => if (c.screen == .failure and c.vm.can_retry) return c.start(),
            .cancel => return c.cancel(),
            .close => return c.close(),
            .launch => if (c.screen == .complete and c.vm.can_launch) return .launch,
            .choose_folder => return c.chooseFolder(),
        }
        return null;
    }

    fn start(c: *Controller) Command {
        c.screen = .progress;
        c.vm.show_license = false;
        c.vm.confirm_cancel = false;
        c.vm.can_cancel = true;
        c.vm.progress = 0;
        c.vm.progress_known = false;
        c.vm.progress_unknown = true;
        c.vm.phase_label = copy.phase(.prepare);
        c.vm.status_detail = "";
        return .{ .start = .{
            .operation = c.vm.operation,
            .scope = c.vm.scope,
            .install_dir = c.install_dir,
        } };
    }

    fn cancel(c: *Controller) ?Command {
        switch (c.screen) {
            .welcome, .options => return .close,
            .progress => {
                if (!c.vm.can_cancel) return null;
                if (!c.vm.confirm_cancel) {
                    c.vm.confirm_cancel = true;
                    return null;
                }
                c.vm.confirm_cancel = false;
                c.vm.can_cancel = false;
                c.vm.phase_label = copy.canceling;
                return .cancel;
            },
            .failure, .complete => return .close,
        }
    }

    /// Close buttons, Escape in a closable modal, and the window's close box.
    fn close(c: *Controller) ?Command {
        if (c.vm.show_license) {
            c.vm.show_license = false;
            return null;
        }
        if (c.screen == .progress) {
            if (c.vm.can_cancel) c.vm.confirm_cancel = true;
            return null;
        }
        return .close;
    }

    pub fn onEvent(c: *Controller, event: contracts.events.Event) void {
        if (c.screen != .progress) return;
        if (c.vm.can_cancel) c.vm.phase_label = copy.phase(event.phase);
        if (event.progress) |p| {
            c.vm.progress = std.math.clamp(p, 0, 1);
            c.vm.progress_known = true;
            c.vm.progress_unknown = false;
        } else {
            c.vm.progress_known = false;
            c.vm.progress_unknown = true;
        }
        c.vm.status_detail = event.message orelse "";
    }

    pub fn finish(c: *Controller, outcome: Outcome) void {
        c.vm.confirm_cancel = false;
        switch (outcome) {
            .succeeded => c.screen = .complete,
            .failed => |f| {
                c.screen = .failure;
                c.vm.error_title = copy.failureTitle(c.vm.operation);
                c.vm.error_message = f.message;
                c.vm.error_code = f.code;
                c.vm.can_retry = f.retryable;
            },
            .canceled => {
                c.screen = .failure;
                c.vm.error_title = copy.canceled_title;
                c.vm.error_message = copy.canceled_message;
                c.vm.error_code = copy.canceled_code;
                c.vm.can_retry = true;
            },
        }
    }

    /// The system folder dialog's answer; null when the user dismissed it.
    pub fn folderChosen(c: *Controller, path: ?[]const u8) error{OutOfMemory}!void {
        const chosen = path orelse return;
        const owned = try c.arena.dupe(u8, chosen);
        c.vm.location = owned;
        c.install_dir = owned;
    }
};
