//! Product manifest composition (docs/spec/manifest-v1.md): a template manifest whose
//! components carry no artifacts, plus built artifacts, becomes the release manifest. The
//! result passes the same strict decode and rules the installer applies.

const std = @import("std");
const contracts = @import("contracts");
const manifest = @import("manifest");

const Manifest = contracts.manifest.Manifest;
const ComponentMeta = contracts.manifest.ComponentMeta;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Artifact = struct {
    bytes: []const u8,
    meta: ComponentMeta,
};

pub const Overrides = struct {
    version: ?[]const u8 = null,
    sequence: ?u64 = null,
};

pub fn digestText(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var digest: contracts.Digest = @splat(0);
    Sha256.hash(bytes, &digest, .{});
    return std.fmt.allocPrint(arena, "sha256:{s}", .{&std.fmt.bytesToHex(digest, .lower)});
}

pub fn parseTemplate(arena: std.mem.Allocator, template: []const u8) !Manifest {
    const limits: contracts.Limits = .{};
    return contracts.json.decode(Manifest, arena, template, .{
        .max_bytes = limits.manifest_bytes,
        .max_schema = contracts.manifest.schema_version,
        .limits = limits,
    });
}

/// Manifest bytes for `artifacts` over `template`; `installer_version` is the packager's own
/// version, which `min_installer` may not exceed.
pub fn compose(
    arena: std.mem.Allocator,
    template: []const u8,
    artifacts: []const Artifact,
    overrides: Overrides,
    installer_version: []const u8,
) ![]const u8 {
    var m = try parseTemplate(arena, template);
    if (overrides.version) |v| m.product.version = v;
    if (overrides.sequence) |s| m.product.release_sequence = s;
    const components = try arena.dupe(contracts.manifest.Component, m.components);
    for (components) |*c| {
        if (c.artifacts.map.count() != 0) return error.PackTemplateHasArtifacts;
        c.artifacts = .{};
    }
    for (artifacts) |a| {
        const c = find(components, a.meta.id) orelse return error.PackUnknownComponent;
        const key = @tagName(a.meta.platform);
        if (c.artifacts.map.contains(key)) return error.PackDuplicateArtifact;
        try c.artifacts.map.put(arena, key, try digestText(arena, a.bytes));
    }
    for (components) |c| if (c.artifacts.map.count() == 0) return error.PackMissingArtifact;
    m.components = components;
    const metas = try arena.alloc(ComponentMeta, artifacts.len);
    for (metas, artifacts) |*out, a| out.* = a.meta;
    try manifest.validate.entrypoints(m, metas);
    const bytes = try std.json.Stringify.valueAlloc(arena, m, .{
        .emit_null_optional_fields = false,
    });
    const parsed = try manifest.parse(arena, bytes, installer_version, .{});
    std.debug.assert(parsed.product.release_sequence == m.product.release_sequence);
    return bytes;
}

fn find(components: []contracts.manifest.Component, id: []const u8) ?*contracts.manifest.Component {
    for (components) |*c| if (std.mem.eql(u8, c.id, id)) return c;
    return null;
}
