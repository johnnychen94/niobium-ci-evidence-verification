//! On-disk installer state: `installation.json`, `trust/state.json`, and the setup product config.

const std = @import("std");
const json = @import("json.zig");
const ids = @import("ids.zig");

pub const schema_version = 1;
pub const max_state_bytes = 2 << 20;

pub const BootstrapState = enum { none, done, pending };

pub const Installation = struct {
    schema: u32 = schema_version,
    product_id: []const u8,
    product_name: []const u8,
    scope: ids.Scope,
    channel: ids.Channel,
    release_sequence: u64,
    app_version: []const u8,
    /// Transaction number of the active `versions/<n>`; the next transaction uses n + 1.
    active_tx: u64,
    installer_version: []const u8,
    components: []const []const u8,
    /// sha256 hex of the manifest bytes that produced this release.
    manifest_sha256: []const u8,
    bootstrap: BootstrapState = .none,
    /// App Bootstrap executable relative to `current/` (`<component>/<path>`); uninstall sends
    /// `deactivate` to it. Null when the release declares no bootstrap.
    bootstrap_target: ?[]const u8 = null,
    /// Integrations registered for this release (shortcut/association/service ids).
    integrations: []const Integration = &.{},
};

pub const IntegrationKind = enum { shortcut, file_association, service, registration };

pub const Integration = struct {
    kind: IntegrationKind,
    id: []const u8,
    /// Platform location (link path, registry key, unit file) written at install time.
    location: []const u8,
};

pub const TrustState = struct {
    schema: u32 = schema_version,
    root_version: u64,
    timestamp_version: u64,
    snapshot_version: u64,
    targets_version: u64,
    channel_version: u64,
    release_sequence: u64,
};

pub const Mode = enum { generic, branded };

/// What the GUI shows for a branded product. Text is plain UTF-8, never markup; absent fields
/// fall back to the generic copy.
pub const Branding = struct {
    product_name: ?[]const u8 = null,
    publisher: ?[]const u8 = null,
    /// `#RRGGBB`; rejected at startup when no shade of it reaches the contrast rules.
    accent: ?[]const u8 = null,
    welcome_title: ?[]const u8 = null,
    welcome_body: ?[]const u8 = null,
    complete_body: ?[]const u8 = null,
    /// License text shown before install; installing implies accepting it.
    license: ?[]const u8 = null,
    /// Base64 of a PNG logo, at most `max_logo_bytes` decoded.
    logo_png: ?[]const u8 = null,
};

pub const max_logo_bytes = 256 * 1024;
pub const max_license_bytes = 64 * 1024;

/// Embedded in setup at build time (`-Dproduct-config`); generic setups read `--config`.
pub const ProductConfig = struct {
    schema: u32,
    mode: Mode,
    product_id: ?[]const u8 = null,
    channel: ids.Channel = .stable,
    /// URL (`https://…`, `http://127.0.0.1…` in tests) or directory.
    repository: ?[]const u8 = null,
    /// Trusted root metadata envelope (bytes of `<N>.root.json`), embedded as a string.
    trust_root: ?[]const u8 = null,
    default_scope: ?ids.Scope = null,
    branding: Branding = .{},
};

pub fn decodeInstallation(
    arena: std.mem.Allocator,
    bytes: []const u8,
) json.DecodeError!Installation {
    return json.decode(
        Installation,
        arena,
        bytes,
        .{ .max_bytes = max_state_bytes, .max_schema = schema_version },
    );
}

pub fn decodeTrustState(arena: std.mem.Allocator, bytes: []const u8) json.DecodeError!TrustState {
    return json.decode(
        TrustState,
        arena,
        bytes,
        .{ .max_bytes = 64 << 10, .max_schema = schema_version },
    );
}

pub fn decodeProductConfig(
    arena: std.mem.Allocator,
    bytes: []const u8,
) json.DecodeError!ProductConfig {
    return json.decode(
        ProductConfig,
        arena,
        bytes,
        .{ .max_bytes = 1 << 20, .max_schema = schema_version },
    );
}

pub fn encode(arena: std.mem.Allocator, value: anytype) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(arena, value, .{ .whitespace = .indent_2 });
}

test "installation state round trips" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const state: Installation = .{
        .product_id = "com.example.hello",
        .product_name = "Hello",
        .scope = .user,
        .channel = .stable,
        .release_sequence = 3,
        .app_version = "1.2.0",
        .active_tx = 4,
        .installer_version = "0.1.0",
        .components = &.{"runtime"},
        .manifest_sha256 = "00",
        .bootstrap = .pending,
    };
    const bytes = try encode(arena.allocator(), state);
    const back = try decodeInstallation(arena.allocator(), bytes);
    try std.testing.expectEqual(BootstrapState.pending, back.bootstrap);
    try std.testing.expectEqualStrings("runtime", back.components[0]);
    const config = try decodeProductConfig(
        arena.allocator(),
        "{\"schema\":1,\"mode\":\"generic\"}",
    );
    try std.testing.expectEqual(Mode.generic, config.mode);
}
