//! Product manifest v1 and component metadata v1 wire types (docs/spec/manifest-v1.md,
//! docs/spec/component-v1.md). Semantic rules live in libs/manifest.

const std = @import("std");
const ids = @import("ids.zig");

pub const schema_version = 1;

pub const Map = std.json.ArrayHashMap;

pub const Manifest = struct {
    schema: u32,
    min_installer: []const u8,
    product: Product,
    install: Install,
    components: []const Component,
    integrations: Integrations = .{},
    bootstrap: ?Bootstrap = null,
    experience: Experience = .{},
};

pub const Product = struct {
    id: []const u8,
    name: []const u8,
    publisher: []const u8,
    version: []const u8,
    release_sequence: u64,
};

pub const Install = struct {
    default_scope: ids.Scope,
    allowed_scopes: []const ids.Scope,
};

pub const Component = struct {
    id: []const u8,
    title: []const u8,
    required: bool = false,
    default: bool = true,
    /// `<os>-<arch>` -> `sha256:<hex>`.
    artifacts: Map([]const u8),
};

pub const Integrations = struct {
    shortcuts: []const Shortcut = &.{},
    file_associations: []const FileAssociation = &.{},
    services: []const Service = &.{},
};

pub const Shortcut = struct {
    name: []const u8,
    entrypoint: []const u8,
};

pub const FileAssociation = struct {
    extension: []const u8,
    entrypoint: []const u8,
    description: []const u8,
};

pub const ServiceStart = enum { auto, manual };

pub const Service = struct {
    id: []const u8,
    entrypoint: []const u8,
    start: ServiceStart,
};

pub const Bootstrap = struct {
    entrypoint: []const u8,
    protocol: u32,
};

pub const Experience = struct {
    accent: ?[]const u8 = null,
    license_text: ?[]const u8 = null,
    welcome_text: ?[]const u8 = null,
    icon_png: ?[]const u8 = null,
};

pub const ComponentMeta = struct {
    schema: u32,
    id: []const u8,
    version: []const u8,
    platform: ids.Platform,
    entrypoints: Map(Entrypoint),
    executables: []const []const u8 = &.{},
};

pub const Entrypoint = struct {
    path: []const u8,
    bootstrap: bool = false,
};

test "manifest example decodes strictly" {
    const json = @import("json.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\{"schema":1,"min_installer":"0.1.0",
        \\ "product":{"id":"com.example.hello","name":"Hello","publisher":"Example Inc.",
        \\            "version":"1.2.0","release_sequence":3},
        \\ "install":{"default_scope":"user","allowed_scopes":["user","machine"]},
        \\ "components":[{"id":"runtime","title":"Hello Runtime","required":true,"default":true,
        \\   "artifacts":{"macos-aarch64":"sha256:00"}}],
        \\ "integrations":{"services":[
        \\   {"id":"agent","entrypoint":"runtime.agent","start":"manual"}]},
        \\ "bootstrap":{"entrypoint":"runtime.main","protocol":1},
        \\ "experience":{"accent":"#3B5BDB"}}
    ;
    const manifest = try json.decode(Manifest, arena.allocator(), text, .{
        .max_bytes = 1 << 20,
        .max_schema = schema_version,
    });
    try std.testing.expectEqual(@as(u64, 3), manifest.product.release_sequence);
    try std.testing.expectEqual(ids.Scope.user, manifest.install.default_scope);
    try std.testing.expectEqualStrings(
        "sha256:00",
        manifest.components[0].artifacts.map.get("macos-aarch64").?,
    );
}
