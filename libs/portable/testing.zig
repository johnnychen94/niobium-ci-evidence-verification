//! Signed in-memory repositories with real tar.zst artifacts, for portable, engine and e2e
//! tests. Keys come from trust.testing (fixed seeds); never use them outside tests.

const std = @import("std");
const contracts = @import("contracts");
const package = @import("package");
const repository = @import("repository");
const trust = @import("trust");

pub const product_id = "com.example.hello";
/// Artifacts are published for this platform regardless of the host, so every host runs the
/// same fixtures; callers pass it as the expected platform.
pub const platform: contracts.Platform = .@"macos-aarch64";

pub const File = struct {
    path: []const u8,
    data: []const u8,
    executable: bool = false,
};

pub const Entry = struct {
    name: []const u8,
    path: []const u8,
    bootstrap: bool = false,
};

pub const Component = struct {
    id: []const u8,
    required: bool = true,
    files: []const File,
    entrypoints: []const Entry,
};

pub const Release = struct {
    sequence: u64,
    version: []const u8,
    components: []const Component,
    shortcuts: []const contracts.manifest.Shortcut = &.{},
    services: []const contracts.manifest.Service = &.{},
    file_associations: []const contracts.manifest.FileAssociation = &.{},
    /// `<component>.<entrypoint>` of the App Bootstrap entry.
    bootstrap: ?[]const u8 = null,
    default_scope: contracts.Scope = .user,
    allowed_scopes: []const contracts.Scope = &.{.user},
    channel: contracts.Channel = .stable,
    /// Frontend tests that resolve for the host pass `contracts.Platform.current()`.
    platform: contracts.Platform = platform,
};

pub const Repo = struct {
    repo: repository.Repository,
    root_bytes: []const u8,
    manifest: []const u8,
    artifacts: []const []const u8,
};

/// `component.json` followed by `files/…`, zstd-framed with raw blocks.
pub fn artifact(
    arena: std.mem.Allocator,
    component: Component,
    target: contracts.Platform,
) ![]const u8 {
    var entrypoints: contracts.manifest.Map(contracts.manifest.Entrypoint) = .{};
    var executables: std.ArrayList([]const u8) = .empty;
    for (component.entrypoints) |e| {
        try entrypoints.map.put(arena, e.name, .{ .path = e.path, .bootstrap = e.bootstrap });
    }
    for (component.files) |f| {
        if (f.executable) try executables.append(arena, f.path);
    }
    const meta: contracts.manifest.ComponentMeta = .{
        .schema = 1,
        .id = component.id,
        .version = "1.0.0",
        .platform = target,
        .entrypoints = entrypoints,
        .executables = executables.items,
    };
    var tar: package.fixture.Tar = .{ .gpa = arena };
    try tar.file("component.json", try std.json.Stringify.valueAlloc(arena, meta, .{}));
    for (component.files) |f| {
        try tar.file(try arena.print("files/{s}", .{f.path}), f.data);
    }
    try tar.end();
    return package.fixture.zstdRaw(arena, tar.bytes.items);
}

pub fn manifestBytes(
    arena: std.mem.Allocator,
    release: Release,
    artifacts: []const []const u8,
) ![]const u8 {
    const components = try arena.alloc(contracts.manifest.Component, release.components.len);
    for (components, release.components, artifacts) |*out, c, bytes| {
        var map: contracts.manifest.Map([]const u8) = .{};
        const hex = contracts.ids.hexDigest(trust.testing.sha256(bytes));
        try map.map.put(arena, @tagName(release.platform), try arena.print("sha256:{s}", .{&hex}));
        out.* = .{ .id = c.id, .title = c.id, .required = c.required, .artifacts = map };
    }
    const m: contracts.manifest.Manifest = .{
        .schema = 1,
        .min_installer = "0.1.0",
        .product = .{
            .id = product_id,
            .name = "Hello",
            .publisher = "Example",
            .version = release.version,
            .release_sequence = release.sequence,
        },
        .install = .{
            .default_scope = release.default_scope,
            .allowed_scopes = release.allowed_scopes,
        },
        .components = components,
        .integrations = .{
            .shortcuts = release.shortcuts,
            .services = release.services,
            .file_associations = release.file_associations,
        },
        .bootstrap = if (release.bootstrap) |entry| .{
            .entrypoint = entry,
            .protocol = 1,
        } else null,
    };
    return std.json.Stringify.valueAlloc(arena, m, .{ .emit_null_optional_fields = false });
}

/// A repository whose newest release is `release`. Republishing with a higher sequence models
/// the publisher shipping an update; the root stays the same.
pub fn publish(io: std.Io, arena: std.mem.Allocator, release: Release) !Repo {
    const artifacts = try arena.alloc([]const u8, release.components.len);
    for (artifacts, release.components) |*bytes, c| bytes.* = try artifact(
        arena,
        c,
        release.platform,
    );
    const manifest = try manifestBytes(arena, release, artifacts);
    const files = try trust.testing.publishRelease(arena, try trust.testing.keySet(arena), .{
        .product_id = product_id,
        .sequence = release.sequence,
        .version = release.version,
        .manifest = manifest,
        .artifacts = artifacts,
        .channel = release.channel,
    });
    const embedded = try arena.alloc(repository.embedded.File, files.len);
    for (embedded, files) |*out, file| out.* = .{ .path = file.path, .bytes = file.bytes };
    return .{
        .repo = .{ .embedded = .{ .io = io, .files = embedded } },
        .root_bytes = trust.testing.find(files, "metadata/1.root.json").?,
        .manifest = manifest,
        .artifacts = artifacts,
    };
}
