//! TUF profile v1 metadata wire types (docs/spec/tuf-profile-v1.md). Verification is libs/trust.

const std = @import("std");

pub const Map = std.json.ArrayHashMap;

pub const spec_version = "1.0";

pub const Signature = struct {
    keyid: []const u8,
    sig: []const u8,
};

pub const KeyValue = struct { public: []const u8 };

pub const Key = struct {
    keytype: []const u8,
    scheme: []const u8,
    keyval: KeyValue,
};

pub const RoleKeys = struct {
    keyids: []const []const u8,
    threshold: u32,
};

pub const Roles = struct {
    root: RoleKeys,
    targets: RoleKeys,
    snapshot: RoleKeys,
    timestamp: RoleKeys,
};

pub const Hashes = struct { sha256: []const u8 };

pub const MetaFile = struct {
    version: u64,
    length: ?u64 = null,
    hashes: ?Hashes = null,
};

pub const Custom = struct {
    release_sequence: u64,
    app_version: []const u8,
};

pub const TargetFile = struct {
    length: u64,
    hashes: Hashes,
    custom: ?Custom = null,
};

pub const Delegation = struct {
    name: []const u8,
    keyids: []const []const u8,
    threshold: u32,
    paths: []const []const u8,
    terminating: bool,
};

pub const Delegations = struct {
    keys: Map(Key),
    roles: []const Delegation,
};

pub const Root = struct {
    _type: []const u8,
    spec_version: []const u8,
    version: u64,
    expires: []const u8,
    keys: Map(Key),
    roles: Roles,
};

pub const Timestamp = struct {
    _type: []const u8,
    spec_version: []const u8,
    version: u64,
    expires: []const u8,
    meta: Map(MetaFile),
};

pub const Snapshot = Timestamp;

pub const Targets = struct {
    _type: []const u8,
    spec_version: []const u8,
    version: u64,
    expires: []const u8,
    targets: Map(TargetFile),
    delegations: ?Delegations = null,
};

pub fn Envelope(comptime Signed: type) type {
    return struct {
        signed: Signed,
        signatures: []const Signature,
    };
}

pub const RoleName = enum { root, timestamp, snapshot, targets };

test "timestamp envelope decodes" {
    const json = @import("json.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\{"signed":{"_type":"timestamp","spec_version":"1.0","version":7,
        \\ "expires":"2026-10-13T00:00:00Z","meta":{"snapshot.json":{"version":5,"length":412,
        \\ "hashes":{"sha256":"ab"}}}},"signatures":[{"keyid":"k","sig":"s"}]}
    ;
    const envelope = try json.decode(
        Envelope(Timestamp),
        arena.allocator(),
        text,
        .{ .max_bytes = 16 << 10 },
    );
    try std.testing.expectEqual(
        @as(u64, 5),
        envelope.signed.meta.map.get("snapshot.json").?.version,
    );
}
