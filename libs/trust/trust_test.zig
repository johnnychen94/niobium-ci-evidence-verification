//! Negative TUF suite (N1-INV-05) over an in-memory repository built by the publisher.

const std = @import("std");
const contracts = @import("contracts");
const trust = @import("root.zig");

const day = 86_400;
const now: i64 = 1_790_000_000;

const MemorySource = struct {
    files: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn fetch(
        source: *const MemorySource,
        arena: std.mem.Allocator,
        path: []const u8,
        max: u64,
    ) trust.FetchError![]u8 {
        const bytes = source.files.get(path) orelse return error.RepoNotFound;
        if (bytes.len > max) return error.RepoTooLarge;
        return arena.dupe(u8, bytes);
    }

    fn put(
        source: *MemorySource,
        arena: std.mem.Allocator,
        files: []const trust.publish.File,
    ) !void {
        for (files) |file| try source.files.put(arena, file.path, file.bytes);
    }
};

const Fixture = struct {
    arena: std.mem.Allocator,
    source: MemorySource = .{},
    root_bytes: []const u8 = "",
    input: trust.publish.Input,
    manifest: []const u8 = "{\"m\":1}",
    artifact: []const u8 = "artifact-bytes",

    fn signers(seed: u8, count: usize, arena: std.mem.Allocator) ![]const trust.Signer {
        const list = try arena.alloc(trust.Signer, count);
        for (list, 0..) |*signer, index| {
            const offset = std.math.cast(u8, index) orelse return error.TestTooManySigners;
            signer.* = try .fromSeed(@splat(seed + offset));
        }
        return list;
    }

    fn init(arena: std.mem.Allocator) !Fixture {
        const set: trust.publish.KeySet = .{
            .root = .{ .signers = try signers(10, 3, arena), .threshold = 2 },
            .targets = .{ .signers = try signers(20, 1, arena) },
            .snapshot = .{ .signers = try signers(30, 1, arena) },
            .timestamp = .{ .signers = try signers(40, 1, arena) },
            .channel = .{ .signers = try signers(50, 1, arena) },
        };
        // SAFETY: `input` is assigned on the next statement.
        var fixture: Fixture = .{ .arena = arena, .input = undefined };
        fixture.input = .{
            .keys = set,
            .timestamp_version = 1,
            .snapshot_version = 1,
            .targets_version = 1,
            .root_expires = now + 365 * day,
            .expires = now + 30 * day,
            .timestamp_expires = now + day,
            .targets = &.{},
            .channels = &.{},
        };
        try fixture.release(3, "1.2.0");
        return fixture;
    }

    fn release(fixture: *Fixture, sequence: u64, version: []const u8) !void {
        const arena = fixture.arena;
        const channel_targets = try arena.alloc(trust.publish.TargetInput, 1);
        channel_targets[0] = .{
            .path = "manifests/com.example.hello.json",
            .bytes = fixture.manifest,
            .custom = .{ .release_sequence = sequence, .app_version = version },
        };
        const targets = try arena.alloc(trust.publish.TargetInput, 1);
        targets[0] = .{ .path = "artifacts/runtime.tar.zst", .bytes = fixture.artifact };
        const channels = try arena.alloc(trust.publish.ChannelInput, 1);
        channels[0] = .{ .channel = .stable, .version = sequence, .targets = channel_targets };
        fixture.input.targets = targets;
        fixture.input.channels = channels;
        try fixture.publish();
    }

    fn publish(fixture: *Fixture) !void {
        const files = try trust.publish.publish(fixture.arena, fixture.input);
        try fixture.source.put(fixture.arena, files);
        if (fixture.root_bytes.len == 0) {
            fixture.root_bytes = fixture.source.files.get("metadata/1.root.json").?;
        }
    }

    fn refresh(fixture: *Fixture, options: trust.client.Options) trust.Error!trust.Verified {
        return trust.refresh(fixture.arena, &fixture.source, fixture.root_bytes, options);
    }
};

fn withFixture(comptime body: fn (*Fixture) anyerror!void) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator());
    try body(&fixture);
}

test "N1-INV-05 happy path verifies manifest and artifact" {
    try withFixture(struct {
        fn run(f: *Fixture) !void {
            const verified = try f.refresh(.{ .now = now });
            const target = try verified.manifestTarget(f.arena, "com.example.hello");
            try std.testing.expectEqual(@as(u64, 3), target.release_sequence);
            const bytes = try trust.fetchTarget(f.arena, &f.source, target.digest, target.length);
            try std.testing.expectEqualStrings(f.manifest, bytes);
            var digest: [32]u8 = @splat(0);
            std.crypto.hash.sha2.Sha256.hash(f.artifact, &digest, .{});
            try std.testing.expectEqual(
                @as(u64, f.artifact.len),
                try verified.authorizeArtifact(digest),
            );
            try std.testing.expectError(
                error.UnauthorizedArtifact,
                verified.authorizeArtifact(@splat(7)),
            );
        }
    }.run);
}

test "N1-INV-05 expired timestamp and expired root are rejected" {
    try withFixture(struct {
        fn run(f: *Fixture) !void {
            try std.testing.expectError(error.Expired, f.refresh(.{ .now = now + 2 * day }));
            try std.testing.expectError(error.Expired, f.refresh(.{ .now = now + 400 * day }));
        }
    }.run);
}

test "N1-INV-05 rollback of timestamp, snapshot and channel versions" {
    try withFixture(struct {
        fn run(f: *Fixture) !void {
            const trusted: contracts.installation.TrustState = .{
                .root_version = 1,
                .timestamp_version = 5,
                .snapshot_version = 1,
                .targets_version = 1,
                .channel_version = 1,
                .release_sequence = 3,
            };
            try std.testing.expectError(
                error.RollbackAttack,
                f.refresh(.{ .now = now, .trusted = trusted }),
            );
            var newer = trusted;
            newer.timestamp_version = 1;
            newer.channel_version = 9;
            try std.testing.expectError(
                error.RollbackAttack,
                f.refresh(.{ .now = now, .trusted = newer }),
            );
        }
    }.run);
}

test "N1-INV-05 forged signatures and missing threshold" {
    try withFixture(struct {
        fn run(f: *Fixture) !void {
            f.input.keys.timestamp.signers = try Fixture.signers(99, 1, f.arena);
            f.input.timestamp_version = 2;
            try f.publish();
            try std.testing.expectError(error.SignatureThreshold, f.refresh(.{ .now = now }));
        }
    }.run);
    try withFixture(struct {
        fn run(f: *Fixture) !void {
            var root = try trust.publish.rootMetadata(f.arena, f.input.keys, 1, now + day);
            root.roles.root.threshold = 2;
            f.root_bytes = try trust.publish.signEnvelope(
                f.arena,
                root,
                f.input.keys.root.signers[0..1],
            );
            try std.testing.expectError(error.SignatureThreshold, f.refresh(.{ .now = now }));
        }
    }.run);
}

test "N1-INV-05 wrong snapshot hash or length" {
    try withFixture(struct {
        fn run(f: *Fixture) !void {
            const original = f.source.files.get("metadata/1.snapshot.json").?;
            const tampered = try f.arena.dupe(u8, original);
            tampered[tampered.len - 2] = ' ';
            try f.source.files.put(f.arena, "metadata/1.snapshot.json", tampered);
            try std.testing.expectError(error.HashMismatch, f.refresh(.{ .now = now }));
            try f.source.files.put(
                f.arena,
                "metadata/1.snapshot.json",
                original[0 .. original.len - 1],
            );
            try std.testing.expectError(error.LengthMismatch, f.refresh(.{ .now = now }));
        }
    }.run);
}

test "N1-INV-05 tampered target bytes" {
    try withFixture(struct {
        fn run(f: *Fixture) !void {
            const verified = try f.refresh(.{ .now = now });
            const target = try verified.manifestTarget(f.arena, "com.example.hello");
            const hex = contracts.ids.hexDigest(target.digest);
            try f.source.files.put(f.arena, try f.arena.print("targets/{s}", .{&hex}), "{\"m\":2}");
            try std.testing.expectError(
                error.HashMismatch,
                trust.fetchTarget(f.arena, &f.source, target.digest, target.length),
            );
        }
    }.run);
}

test "N1-AC-03 root rotation needs old and new thresholds" {
    try withFixture(struct {
        fn run(f: *Fixture) !void {
            const old_root = f.input.keys.root.signers;
            const new_root = try Fixture.signers(60, 2, f.arena);
            var rotated = f.input.keys;
            rotated.root = .{ .signers = new_root, .threshold = 2 };
            const root2 = try trust.publish.rootMetadata(f.arena, rotated, 2, now + 365 * day);
            const both = try std.mem.concat(f.arena, trust.Signer, &.{ old_root[0..2], new_root });
            try f.source.files.put(
                f.arena,
                "metadata/2.root.json",
                try trust.publish.signEnvelope(f.arena, root2, both),
            );
            const verified = try f.refresh(.{ .now = now });
            try std.testing.expectEqual(@as(u64, 2), verified.root.version);

            try f.source.files.put(
                f.arena,
                "metadata/2.root.json",
                try trust.publish.signEnvelope(f.arena, root2, new_root),
            );
            try std.testing.expectError(error.SignatureThreshold, f.refresh(.{ .now = now }));

            const root3 = try trust.publish.rootMetadata(f.arena, rotated, 3, now + 365 * day);
            try f.source.files.put(
                f.arena,
                "metadata/2.root.json",
                try trust.publish.signEnvelope(f.arena, root3, both),
            );
            try std.testing.expectError(error.TrustRootVersion, f.refresh(.{ .now = now }));
        }
    }.run);
}

test "N1-INV-06 release_sequence must increase; app_version may go down" {
    try trust.checkReleaseSequence(4, 3);
    try trust.checkReleaseSequence(1, null);
    try std.testing.expectError(error.ReleaseSequenceRegression, trust.checkReleaseSequence(3, 3));
    try std.testing.expectError(error.ReleaseSequenceRegression, trust.checkReleaseSequence(2, 3));
    try withFixture(struct {
        fn run(f: *Fixture) !void {
            f.input.timestamp_version = 2;
            f.input.snapshot_version = 2;
            try f.release(4, "1.1.0");
            const verified = try f.refresh(.{ .now = now });
            const target = try verified.manifestTarget(f.arena, "com.example.hello");
            try std.testing.expectEqual(@as(u64, 4), target.release_sequence);
            try std.testing.expectEqualStrings("1.1.0", target.app_version);
        }
    }.run);
}

test "N1-INV-05 unknown channel and oversized metadata" {
    try withFixture(struct {
        fn run(f: *Fixture) !void {
            try std.testing.expectError(
                error.UnknownRole,
                f.refresh(.{ .now = now, .channel = .beta }),
            );
            const huge = try f.arena.alloc(u8, 20 << 10);
            @memset(huge, ' ');
            try f.source.files.put(f.arena, "metadata/timestamp.json", huge);
            try std.testing.expectError(error.MetadataTooLarge, f.refresh(.{ .now = now }));
        }
    }.run);
}

test "N1-INV-05 channel role may only list delegated paths" {
    try withFixture(struct {
        fn run(f: *Fixture) !void {
            const evil = try f.arena.alloc(trust.publish.TargetInput, 1);
            evil[0] = .{ .path = "artifacts/evil", .bytes = "x" };
            const channels = try f.arena.alloc(trust.publish.ChannelInput, 1);
            channels[0] = .{ .channel = .stable, .version = 9, .targets = evil };
            f.input.channels = channels;
            f.input.timestamp_version = 2;
            f.input.snapshot_version = 2;
            try f.publish();
            try std.testing.expectError(error.PathNotDelegated, f.refresh(.{ .now = now }));
        }
    }.run);
}
