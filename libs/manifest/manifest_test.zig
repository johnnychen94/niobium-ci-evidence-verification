const std = @import("std");
const contracts = @import("contracts");
const manifest = @import("root.zig");

const digest = "sha256:" ++ "0123456789abcdef" ++ "0123456789abcdef" ++ "0123456789abcdef" ++
    "0123456789abcdef";

fn sample(comptime product: []const u8, comptime components: []const u8) []const u8 {
    return "{\"schema\":1,\"min_installer\":\"0.1.0\",\"product\":" ++ product ++
        ",\"install\":{\"default_scope\":\"user\",\"allowed_scopes\":[\"user\"]}," ++
        "\"components\":" ++ components ++
        ",\"integrations\":{\"shortcuts\":[{\"name\":\"Hello\",\"entrypoint\":\"runtime." ++
        "main\"}]}," ++
        "\"bootstrap\":{\"entrypoint\":\"runtime.main\",\"protocol\":1}}";
}

const good_product =
    "{\"id\":\"com.example.hello\",\"name\":\"Hello\",\"publisher\":\"E\",\"version\":\"1.0.0\"," ++
    "\"release_sequence\":1}";
const good_components = "[{\"id\":\"runtime\",\"title\":\"Runtime\",\"required\":true," ++
    "\"artifacts\":{\"macos-aarch64\":\"" ++ digest ++ "\"}}]";

fn parse(bytes: []const u8, installer: []const u8) manifest.Error!void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const m = try manifest.parse(arena.allocator(), bytes, installer, contracts.limits.default);
    std.debug.assert(m.product.release_sequence >= 1);
}

test "N1-AC-01 valid manifest passes semantic validation" {
    try parse(sample(good_product, good_components), "0.1.0");
}

test "N1-INV-08 installer older than min_installer fails closed" {
    try std.testing.expectError(
        error.InstallerTooOld,
        parse(sample(good_product, good_components), "0.0.9"),
    );
}

test "N1-INV-03 forbidden and reserved fields are rejected" {
    const forbidden = "[{\"id\":\"runtime\",\"title\":\"R\",\"required\":true,\"post_ins" ++
        "tall\":\"x\"," ++
        "\"artifacts\":{\"macos-aarch64\":\"" ++ digest ++ "\"}}]";
    try std.testing.expectError(
        error.ForbiddenField,
        parse(sample(good_product, forbidden), "0.1.0"),
    );
    const reserved = "[{\"id\":\"__installer_runtime\",\"title\":\"R\",\"required\":true," ++
        "\"artifacts\":{\"macos-aarch64\":\"" ++ digest ++ "\"}}]";
    try std.testing.expectError(
        error.ManifestReservedComponent,
        parse(sample(good_product, reserved), "0.1.0"),
    );
}

test "semantic errors" {
    const bad_id = "{\"id\":\"Hello\",\"name\":\"H\",\"publisher\":\"E\",\"version\":\"1" ++
        ".0.0\",\"release_sequence\":1}";
    try std.testing.expectError(
        error.ManifestInvalidProductId,
        parse(sample(bad_id, good_components), "0.1.0"),
    );
    const zero = "{\"id\":\"com.e.h\",\"name\":\"H\",\"publisher\":\"E\",\"version\":\"1" ++
        ".0.0\",\"release_sequence\":0}";
    try std.testing.expectError(
        error.ManifestInvalidReleaseSequence,
        parse(sample(zero, good_components), "0.1.0"),
    );
    const bad_digest = "[{\"id\":\"runtime\",\"title\":\"R\",\"required\":true,\"artifac" ++
        "ts\":{\"macos-aarch64\":\"sha256:00\"}}]";
    try std.testing.expectError(
        error.ManifestInvalidArtifact,
        parse(sample(good_product, bad_digest), "0.1.0"),
    );
    const bad_platform = "[{\"id\":\"runtime\",\"title\":\"R\",\"required\":true,\"artif" ++
        "acts\":{\"beos-m68k\":\"" ++ digest ++ "\"}}]";
    try std.testing.expectError(
        error.ManifestInvalidArtifact,
        parse(sample(good_product, bad_platform), "0.1.0"),
    );
    const optional = "[{\"id\":\"runtime\",\"title\":\"R\",\"required\":false,\"artifact" ++
        "s\":{\"macos-aarch64\":\"" ++ digest ++ "\"}}]";
    try std.testing.expectError(
        error.ManifestNoRequiredComponent,
        parse(sample(good_product, optional), "0.1.0"),
    );
}

test "component metadata paths and entrypoints" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const good = "{\"schema\":1,\"id\":\"runtime\",\"version\":\"1.0.0\",\"platform\":\"" ++
        "macos-aarch64\"," ++
        "\"entrypoints\":{\"main\":{\"path\":\"bin/hello\",\"bootstrap\":true}},\"execut" ++
        "ables\":[\"bin/hello\"]}";
    const meta = try manifest.parseComponent(
        arena.allocator(),
        good,
        .@"macos-aarch64",
        contracts.limits.default,
    );
    try std.testing.expectError(
        error.ComponentPlatformMismatch,
        manifest.parseComponent(
            arena.allocator(),
            good,
            .@"linux-x86_64",
            contracts.limits.default,
        ),
    );
    const escape = "{\"schema\":1,\"id\":\"runtime\",\"version\":\"1.0.0\",\"platform\":" ++
        "\"macos-aarch64\"," ++
        "\"entrypoints\":{\"main\":{\"path\":\"../../bin/sh\"}}}";
    try std.testing.expectError(
        error.ComponentInvalidPath,
        manifest.parseComponent(arena.allocator(), escape, null, contracts.limits.default),
    );
    const m = try manifest.parse(
        arena.allocator(),
        sample(good_product, good_components),
        "0.1.0",
        contracts.limits.default,
    );
    try manifest.validate.entrypoints(m, &.{meta});
}
