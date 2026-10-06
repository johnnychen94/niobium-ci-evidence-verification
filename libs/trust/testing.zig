//! Deterministic signed repositories for tests (resolver, engine, sim, e2e). Keys derive from
//! fixed seeds; never use these keys outside tests.

const std = @import("std");
const contracts = @import("contracts");
const keys = @import("keys.zig");
const publish = @import("publish.zig");

pub const day = 86_400;
/// Fixed "now" (2026-09-21) that every fixture's expiry is relative to.
pub const now: i64 = 1_790_000_000;

pub fn signers(arena: std.mem.Allocator, seed: u8, count: usize) ![]const keys.Signer {
    const list = try arena.alloc(keys.Signer, count);
    for (list, 0..) |*signer, index| {
        const offset = std.math.cast(u8, index) orelse return error.TestTooManySigners;
        signer.* = try .fromSeed(@splat(seed + offset));
    }
    return list;
}

/// Root 2-of-3; one key for each other role.
pub fn keySet(arena: std.mem.Allocator) !publish.KeySet {
    return .{
        .root = .{ .signers = try signers(arena, 10, 3), .threshold = 2 },
        .targets = .{ .signers = try signers(arena, 20, 1) },
        .snapshot = .{ .signers = try signers(arena, 30, 1) },
        .timestamp = .{ .signers = try signers(arena, 40, 1) },
        .channel = .{ .signers = try signers(arena, 50, 1) },
    };
}

pub const Release = struct {
    product_id: []const u8,
    sequence: u64,
    version: []const u8,
    manifest: []const u8,
    artifacts: []const []const u8,
    channel: contracts.Channel = .stable,
};

/// Repository files for one release; metadata versions follow the release sequence.
pub fn publishRelease(
    arena: std.mem.Allocator,
    set: publish.KeySet,
    release: Release,
) ![]const publish.File {
    const channel_targets = try arena.alloc(publish.TargetInput, 1);
    channel_targets[0] = .{
        .path = try arena.print("manifests/{s}.json", .{release.product_id}),
        .bytes = release.manifest,
        .custom = .{ .release_sequence = release.sequence, .app_version = release.version },
    };
    const targets = try arena.alloc(publish.TargetInput, release.artifacts.len);
    for (targets, release.artifacts, 0..) |*target, bytes, index| {
        target.* = .{ .path = try arena.print("artifacts/{d}.tar.zst", .{index}), .bytes = bytes };
    }
    const channels = try arena.alloc(publish.ChannelInput, 1);
    channels[0] = .{
        .channel = release.channel,
        .version = release.sequence,
        .targets = channel_targets,
    };
    return publish.publish(arena, .{
        .keys = set,
        .timestamp_version = release.sequence,
        .snapshot_version = release.sequence,
        .targets_version = release.sequence,
        .root_expires = now + 365 * day,
        .expires = now + 30 * day,
        .timestamp_expires = now + day,
        .targets = targets,
        .channels = channels,
    });
}

pub fn find(files: []const publish.File, path: []const u8) ?[]const u8 {
    for (files) |file| {
        if (std.mem.eql(u8, file.path, path)) return file.bytes;
    }
    return null;
}

pub fn sha256(bytes: []const u8) contracts.Digest {
    var digest: contracts.Digest = @splat(0);
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}
