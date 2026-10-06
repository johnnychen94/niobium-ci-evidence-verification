//! Generic installer copy (English). Branding overrides welcome and completion text; the
//! rest is the framework's voice: phase names, titles per operation, failure titles.

const std = @import("std");
const contracts = @import("contracts");
const core = @import("core");

const Operation = contracts.ui.Operation;
const Phase = contracts.events.Phase;

pub fn actionLabel(op: Operation) []const u8 {
    return switch (op) {
        .install => "Install",
        .update => "Update",
        .repair => "Repair",
        .uninstall => "Uninstall",
    };
}

pub fn phase(p: Phase) []const u8 {
    return switch (p) {
        .recover => "Finishing an interrupted operation",
        .discover => "Checking for the latest version",
        .validate => "Verifying the update source",
        .resolve => "Choosing components",
        .plan => "Planning changes",
        .prepare => "Preparing",
        .download => "Downloading",
        .verify => "Verifying downloads",
        .execute => "Copying files",
        .commit => "Applying changes",
        .bootstrap => "Updating the installer",
        .verify_install => "Checking the installation",
        .finalize => "Cleaning up",
        .complete => "Done",
        .@"error" => "Stopped",
    };
}

pub const canceling = "Stopping and rolling back";

pub fn welcomeTitle(arena: std.mem.Allocator, op: Operation, product: []const u8) ![]const u8 {
    return switch (op) {
        .install => std.fmt.allocPrint(arena, "Welcome to {s}", .{product}),
        .update => std.fmt.allocPrint(arena, "Update {s}", .{product}),
        .repair => std.fmt.allocPrint(arena, "Repair {s}", .{product}),
        .uninstall => std.fmt.allocPrint(arena, "Uninstall {s}", .{product}),
    };
}

pub fn welcomeBody(arena: std.mem.Allocator, op: Operation, product: []const u8) ![]const u8 {
    return switch (op) {
        .install => std.fmt.allocPrint(arena, "Setup will install {s} on this computer. " ++
            "Every download is verified before anything is changed.", .{product}),
        .update => std.fmt.allocPrint(arena, "Setup will update {s} to the latest version. " ++
            "If anything fails, the current version stays in place.", .{product}),
        .repair => std.fmt.allocPrint(arena, "Setup will restore the files and shortcuts " ++
            "of {s} to their installed state.", .{product}),
        .uninstall => std.fmt.allocPrint(arena, "Setup will remove {s} and everything it " ++
            "installed. Your documents are not touched.", .{product}),
    };
}

pub fn progressTitle(arena: std.mem.Allocator, op: Operation, product: []const u8) ![]const u8 {
    const verb = switch (op) {
        .install => "Installing",
        .update => "Updating",
        .repair => "Repairing",
        .uninstall => "Removing",
    };
    return std.fmt.allocPrint(arena, "{s} {s}", .{ verb, product });
}

pub fn completeTitle(arena: std.mem.Allocator, op: Operation, product: []const u8) ![]const u8 {
    const state = switch (op) {
        .install => "is installed",
        .update => "is up to date",
        .repair => "is repaired",
        .uninstall => "has been removed",
    };
    return std.fmt.allocPrint(arena, "{s} {s}", .{ product, state });
}

pub fn completeBody(arena: std.mem.Allocator, op: Operation, product: []const u8) ![]const u8 {
    return switch (op) {
        .install, .repair => std.fmt.allocPrint(arena, "{s} is ready to use. Updates are " ++
            "verified and applied the same way.", .{product}),
        .update => std.fmt.allocPrint(arena, "{s} now runs the latest version. The previous " ++
            "version was kept until the new one checked out.", .{product}),
        .uninstall => std.fmt.allocPrint(arena, "{s} and everything setup installed for it " ++
            "were removed.", .{product}),
    };
}

pub fn failureTitle(op: Operation) []const u8 {
    return switch (op) {
        .install => "Installation failed",
        .update => "Update failed",
        .repair => "Repair failed",
        .uninstall => "Uninstall failed",
    };
}

/// What a failed operation tells the user, by exit-code category; the error name is shown
/// under it for support.
pub fn failureMessage(code: core.ExitCode) []const u8 {
    return switch (code) {
        .network => "Setup could not reach the update source. Check the connection and try " ++
            "again.",
        .trust => "The downloaded files did not pass verification, so nothing was changed.",
        .validation => "The release is damaged or incomplete, so nothing was changed.",
        .filesystem => "Setup could not write to the installation folder. Check free space " ++
            "and permissions, then try again.",
        .permission => "Setup is not allowed to install there. Choose another folder or " ++
            "install for this user only.",
        .busy => "Another setup is changing this product. Try again when it has finished.",
        .unsupported_schema => "This release needs a newer version of setup.",
        .unsupported_platform => "This product is not available for this computer.",
        .not_installed => "The product is not installed.",
        .cancelled => canceled_message,
        .ok, .bootstrap_pending, .usage, .internal => "Something went wrong and nothing was " ++
            "changed. The code below helps support find the cause.",
    };
}

/// Failures a second attempt can fix without the user changing anything.
pub fn retryable(code: core.ExitCode) bool {
    return switch (code) {
        .network, .busy, .filesystem => true,
        else => false,
    };
}

pub const canceled_title = "Setup was stopped";
pub const canceled_message = "No changes were kept. You can run setup again at any time.";
pub const canceled_code = "Canceled";
