const std = @import("std");
const contracts = @import("contracts");
const manifest = @import("manifest");
const repository = @import("repository");
const trust = @import("trust");
const resolver = @import("root.zig");

const product_id = "com.example.hello";
const platform: contracts.Platform = .@"macos-aarch64";
const other_platform: contracts.Platform = .@"linux-x86_64";

const Component = struct {
    id: []const u8,
    required: bool = false,
    default: bool = true,
    /// Artifact bytes for `platform`; null when the component does not ship there.
    artifact: ?[]const u8,
};

const Spec = struct {
    id: []const u8 = product_id,
    sequence: u64 = 3,
    manifest_sequence: ?u64 = null,
    version: []const u8 = "1.2.0",
    components: []const Component,
    /// Artifacts the publisher signs; defaults to every component artifact.
    signed: ?[]const []const u8 = null,
};

const World = struct {
    arena: std.mem.Allocator,
    repo: repository.Repository,
    root_bytes: []const u8,

    fn request(w: World) resolver.Request {
        return .{
            .product_id = product_id,
            .root_bytes = w.root_bytes,
            .platform = platform,
            .installer_version = "0.1.0",
            .now = trust.testing.now,
        };
    }

    fn resolve(w: World, req: resolver.Request) resolver.Error!resolver.Resolution {
        return resolver.resolve(w.arena, &w.repo, req);
    }
};

fn manifestBytes(arena: std.mem.Allocator, spec: Spec) ![]const u8 {
    const components = try arena.alloc(contracts.manifest.Component, spec.components.len);
    for (components, spec.components) |*out, c| {
        var artifacts: contracts.manifest.Map([]const u8) = .{};
        const fake = try arena.print("sha256:{s}", .{&contracts.ids.hexDigest(@splat(0xee))});
        try artifacts.map.put(arena, @tagName(other_platform), fake);
        if (c.artifact) |bytes| {
            const hex = contracts.ids.hexDigest(trust.testing.sha256(bytes));
            try artifacts.map.put(
                arena,
                @tagName(platform),
                try arena.print("sha256:{s}", .{&hex}),
            );
        }
        out.* = .{
            .id = c.id,
            .title = c.id,
            .required = c.required,
            .default = c.default,
            .artifacts = artifacts,
        };
    }
    const m: contracts.manifest.Manifest = .{
        .schema = 1,
        .min_installer = "0.1.0",
        .product = .{
            .id = spec.id,
            .name = "Hello",
            .publisher = "Example",
            .version = spec.version,
            .release_sequence = spec.manifest_sequence orelse spec.sequence,
        },
        .install = .{ .default_scope = .user, .allowed_scopes = &.{.user} },
        .components = components,
    };
    return std.json.Stringify.valueAlloc(arena, m, .{ .emit_null_optional_fields = false });
}

fn world(arena: std.mem.Allocator, spec: Spec) !World {
    var signed: std.ArrayList([]const u8) = .empty;
    if (spec.signed) |list| {
        try signed.appendSlice(arena, list);
    } else for (spec.components) |c| {
        if (c.artifact) |bytes| try signed.append(arena, bytes);
    }
    const files = try trust.testing.publishRelease(arena, try trust.testing.keySet(arena), .{
        .product_id = product_id,
        .sequence = spec.sequence,
        .version = spec.version,
        .manifest = try manifestBytes(arena, spec),
        .artifacts = signed.items,
    });
    const embedded = try arena.alloc(repository.embedded.File, files.len);
    for (embedded, files) |*out, file| out.* = .{ .path = file.path, .bytes = file.bytes };
    return .{
        .arena = arena,
        .repo = .{ .embedded = .{ .io = std.testing.io, .files = embedded } },
        .root_bytes = trust.testing.find(files, "metadata/1.root.json").?,
    };
}

const standard = [_]Component{
    .{ .id = "runtime", .required = true, .artifact = "runtime-bytes" },
    .{ .id = "docs", .artifact = "docs-bytes" },
    .{ .id = "extras", .default = false, .artifact = "extras-bytes" },
    .{ .id = "linuxonly", .artifact = null },
};

fn ids(resolution: resolver.Resolution, arena: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (resolution.artifacts) |artifact| {
        try out.appendSlice(arena, artifact.component);
        try out.append(arena, ' ');
    }
    return out.items;
}

test "resolves defaults: required + default components, skipping unshipped optional ones" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const w = try world(arena.allocator(), .{ .components = &standard });
    const got = try w.resolve(w.request());
    try std.testing.expectEqualStrings("runtime docs ", try ids(got, arena.allocator()));
    try std.testing.expectEqual(resolver.Relation.fresh, got.relation);
    try std.testing.expectEqual(contracts.Scope.user, got.scope);
    try std.testing.expectEqual(@as(u64, 3), got.trust_state.release_sequence);
    const digest = trust.testing.sha256(got.manifest_bytes);
    try std.testing.expectEqualStrings(&contracts.ids.hexDigest(digest), &got.manifest_sha256);
    try std.testing.expectEqual(@as(u64, "runtime-bytes".len), got.artifacts[0].length);
}

test "explicit selection adds optional components; unknown ones fail" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const w = try world(arena.allocator(), .{ .components = &standard });
    var req = w.request();
    req.components = &.{"extras"};
    try std.testing.expectEqualStrings(
        "runtime extras ",
        try ids(try w.resolve(req), arena.allocator()),
    );
    req.components = &.{"nope"};
    try std.testing.expectError(error.ResolveUnknownComponent, w.resolve(req));
    req.components = &.{"linuxonly"};
    try std.testing.expectError(error.PlatformUnsupported, w.resolve(req));
}

test "required component without an artifact for the platform is unsupported" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const comps = [_]Component{.{ .id = "runtime", .required = true, .artifact = null }};
    const w = try world(arena.allocator(), .{ .components = &comps });
    try std.testing.expectError(error.PlatformUnsupported, w.resolve(w.request()));
}

test "scope must be allowed by the manifest" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const w = try world(arena.allocator(), .{ .components = &standard });
    var req = w.request();
    req.scope = .machine;
    try std.testing.expectError(error.ResolveScopeNotAllowed, w.resolve(req));
}

test "N1-INV-06 older releases are rejected; same and newer are classified" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const w = try world(arena.allocator(), .{ .components = &standard });
    var req = w.request();
    req.installed_sequence = 5;
    try std.testing.expectError(error.ReleaseSequenceRegression, w.resolve(req));
    req.installed_sequence = 3;
    try std.testing.expectEqual(resolver.Relation.same, (try w.resolve(req)).relation);
    req.installed_sequence = 2;
    try std.testing.expectEqual(resolver.Relation.newer, (try w.resolve(req)).relation);
}

test "manifest must match its signed target" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const skewed = try world(a, .{ .components = &standard, .manifest_sequence = 4 });
    try std.testing.expectError(
        error.TrustReleaseSequenceMismatch,
        skewed.resolve(skewed.request()),
    );
    const other = try world(a, .{ .components = &standard, .id = "com.example.other" });
    try std.testing.expectError(error.ResolveProductMismatch, other.resolve(other.request()));
    const unsigned = try world(a, .{ .components = &standard, .signed = &.{"runtime-bytes"} });
    try std.testing.expectError(error.UnauthorizedArtifact, unsigned.resolve(unsigned.request()));
}
