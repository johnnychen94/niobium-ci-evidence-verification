//! Initial ViewModel from the product config and what the frontend resolved (version,
//! default location, scope policy), and the theme a brand accent produces.

const std = @import("std");
const contracts = @import("contracts");
const kit = @import("ui_kit");
const tokens = @import("ui_tokens");
const copy = @import("copy.zig");

const ViewModel = contracts.ui.ViewModel;
const Branding = contracts.installation.Branding;

pub const Error = error{ OutOfMemory, UiBrandingInvalid } || kit.theme.Error;

pub const Setup = struct {
    config: *const contracts.installation.ProductConfig,
    operation: contracts.ui.Operation,
    /// Product name when branding has none (generic setups: the product id).
    fallback_name: []const u8,
    version: []const u8 = "",
    scope: contracts.Scope = .user,
    /// False when the scope is fixed (`--scope`, update/repair of an existing install).
    scope_editable: bool = true,
    location: []const u8 = "",
    location_editable: bool = true,
    can_launch: bool = false,
};

/// Rejects branding the GUI cannot show faithfully. Logo bytes are checked by ui_render.
pub fn validate(b: Branding) Error!void {
    const limits = .{
        .{ b.product_name, 128 },
        .{ b.publisher, 128 },
        .{ b.welcome_title, 256 },
        .{ b.welcome_body, 4096 },
        .{ b.complete_body, 4096 },
        .{ b.license, contracts.installation.max_license_bytes },
    };
    inline for (limits) |limit| {
        if (limit[0]) |text| {
            if (text.len > limit[1] or !std.unicode.utf8ValidateSlice(text)) {
                return error.UiBrandingInvalid;
            }
        }
    }
    if (b.accent) |accent| try kit.theme.check(try kit.theme.parseHex(accent));
    if (b.logo_png) |logo| {
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(logo) catch return error.UiBrandingInvalid;
        if (size > contracts.installation.max_logo_bytes) return error.UiBrandingInvalid;
    }
}

pub fn viewModel(arena: std.mem.Allocator, s: Setup) Error!ViewModel {
    const b = s.config.branding;
    try validate(b);
    const name = b.product_name orelse s.fallback_name;
    const op = s.operation;
    const options = op == .install;
    const brand_welcome: Branding = if (op == .install) b else .{};
    return .{
        .operation = op,
        .product_name = name,
        .publisher = b.publisher orelse "",
        .version = s.version,
        .action_label = copy.actionLabel(op),
        .welcome_title = brand_welcome.welcome_title orelse try copy.welcomeTitle(arena, op, name),
        .welcome_body = brand_welcome.welcome_body orelse try copy.welcomeBody(arena, op, name),
        .complete_title = try copy.completeTitle(arena, op, name),
        .complete_body = (if (op == .uninstall) null else b.complete_body) orelse
            try copy.completeBody(arena, op, name),
        .progress_title = try copy.progressTitle(arena, op, name),
        .has_logo = b.logo_png != null,
        .has_license = op == .install and b.license != null,
        .license_text = b.license orelse "",
        .has_options = options,
        .no_options = !options,
        .scope = s.scope,
        .scope_editable = s.scope_editable,
        .location = s.location,
        .location_editable = s.location_editable,
        .can_launch = s.can_launch,
        .no_launch = !s.can_launch,
    };
}

/// Base theme, or the base with the brand accent's derived roles. High-contrast themes keep
/// their own accent: the system setting wins over branding.
pub fn theme(b: Branding, name: tokens.ThemeName) Error!tokens.Theme {
    const base = tokens.theme(name);
    if (tokens.isHighContrast(name)) return base.*;
    const accent = b.accent orelse return base.*;
    return kit.theme.branded(base, try kit.theme.parseHex(accent), tokens.isDark(name));
}
