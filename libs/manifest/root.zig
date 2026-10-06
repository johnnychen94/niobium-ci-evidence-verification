//! Product manifest and component metadata: strict decode plus semantic validation.

const std = @import("std");
const contracts = @import("contracts");

pub const validate = @import("validate.zig");

pub const Manifest = contracts.manifest.Manifest;
pub const ComponentMeta = contracts.manifest.ComponentMeta;
pub const Error = validate.Error;

pub fn parse(
    arena: std.mem.Allocator,
    bytes: []const u8,
    installer_version: []const u8,
    limits: contracts.Limits,
) Error!Manifest {
    const m = try contracts.json.decode(Manifest, arena, bytes, .{
        .max_bytes = limits.manifest_bytes,
        .max_schema = contracts.manifest.schema_version,
        .limits = limits,
    });
    try validate.manifestRules(m, installer_version, limits);
    return m;
}

pub fn parseComponent(
    arena: std.mem.Allocator,
    bytes: []const u8,
    expected: ?contracts.Platform,
    limits: contracts.Limits,
) Error!ComponentMeta {
    const meta = try contracts.json.decode(ComponentMeta, arena, bytes, .{
        .max_bytes = limits.manifest_bytes,
        .max_schema = contracts.manifest.schema_version,
        .limits = limits,
    });
    try validate.componentMeta(meta, expected, limits);
    return meta;
}

/// Artifact digest of `component` for `platform`, or null when it does not ship there.
pub fn artifactFor(
    component: contracts.manifest.Component,
    platform: contracts.Platform,
) ?contracts.Digest {
    const text = component.artifacts.map.get(@tagName(platform)) orelse return null;
    return contracts.ids.parseDigest(text);
}

test {
    _ = validate;
    _ = @import("manifest_test.zig");
}
