//! The installer GUI's ViewModel: everything the five screens bind to. Pure data; the screen
//! controller in ui_screens owns the transitions. Bindings cannot negate, so a flag a template
//! needs both ways appears twice (`progress_known` / `progress_unknown`).

const std = @import("std");
const ids = @import("ids.zig");

pub const Screen = enum { welcome, options, progress, failure, complete };

/// Which engine operation the GUI drives.
pub const Operation = enum { install, update, repair, uninstall };

pub const ViewModel = struct {
    operation: Operation = .install,
    product_name: []const u8 = "",
    publisher: []const u8 = "",
    version: []const u8 = "",
    /// "Install", "Update", "Repair", "Uninstall": the primary verb of this run.
    action_label: []const u8 = "Install",
    welcome_title: []const u8 = "",
    welcome_body: []const u8 = "",
    complete_title: []const u8 = "",
    complete_body: []const u8 = "",

    has_logo: bool = false,
    has_license: bool = false,
    license_text: []const u8 = "",
    show_license: bool = false,
    /// Install shows the options page; the other operations start from welcome.
    has_options: bool = true,
    no_options: bool = false,

    scope: ids.Scope = .user,
    scope_editable: bool = true,
    location: []const u8 = "",
    location_editable: bool = true,

    progress_title: []const u8 = "",
    phase_label: []const u8 = "",
    status_detail: []const u8 = "",
    progress: f32 = 0,
    progress_known: bool = false,
    progress_unknown: bool = true,
    can_cancel: bool = true,
    confirm_cancel: bool = false,

    error_title: []const u8 = "",
    error_message: []const u8 = "",
    /// Stable error name (`TrustExpired`), shown for support.
    error_code: []const u8 = "",
    can_retry: bool = false,

    can_launch: bool = false,
    no_launch: bool = true,
};

test "defaults describe an install that has not started" {
    const vm: ViewModel = .{};
    try std.testing.expect(vm.has_options and !vm.no_options);
    try std.testing.expect(vm.progress_unknown and !vm.progress_known);
    try std.testing.expectEqual(ids.Scope.user, vm.scope);
}
