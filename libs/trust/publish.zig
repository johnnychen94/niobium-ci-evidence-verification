//! Repository publisher: typed metadata -> canonical `signed` bytes -> signed envelope files.
//! Used by libs/packager (nbpack publish) and by the negative test suite.

const std = @import("std");
const contracts = @import("contracts");
const keys = @import("keys.zig");

const tuf = contracts.tuf;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Error = error{ OutOfMemory, TrustBadKey } ||
    contracts.json.DecodeError || contracts.canonical.Error;

pub const RoleSigners = struct {
    signers: []const keys.Signer,
    threshold: u32 = 1,
};

pub const KeySet = struct {
    root: RoleSigners,
    targets: RoleSigners,
    snapshot: RoleSigners,
    timestamp: RoleSigners,
    /// One key set for every channel delegation (stable, beta, nightly).
    channel: RoleSigners,
};

pub const TargetInput = struct {
    path: []const u8,
    bytes: []const u8,
    custom: ?tuf.Custom = null,
};

pub const ChannelInput = struct {
    channel: contracts.Channel,
    version: u64,
    targets: []const TargetInput,
};

pub const Input = struct {
    keys: KeySet,
    root_version: u64 = 1,
    timestamp_version: u64,
    snapshot_version: u64,
    targets_version: u64,
    root_expires: i64,
    expires: i64,
    timestamp_expires: i64,
    targets: []const TargetInput,
    channels: []const ChannelInput,
};

pub const File = struct { path: []const u8, bytes: []const u8 };

fn rfc3339(arena: std.mem.Allocator, unix: i64) error{OutOfMemory}![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    contracts.time.formatUtc(&out.writer, unix) catch return error.OutOfMemory;
    return out.written();
}

fn hexOf(arena: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}![]const u8 {
    var digest: [32]u8 = @splat(0);
    Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return arena.dupe(u8, &hex);
}

/// Sign the canonical form of `signed` with every signer; returns envelope bytes.
pub fn signEnvelope(
    arena: std.mem.Allocator,
    signed: anytype,
    signers: []const keys.Signer,
) Error![]const u8 {
    const json = try std.json.Stringify.valueAlloc(
        arena,
        signed,
        .{ .emit_null_optional_fields = false },
    );
    const value = try contracts.json.decodeValue(arena, json, .{ .max_bytes = 64 << 20 });
    const message = try contracts.canonical.encode(arena, value);
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.print("{{\"signed\":{s},\"signatures\":[", .{message}) catch return error.OutOfMemory;
    for (signers, 0..) |signer, index| {
        const sig = try signer.sign(message);
        if (index > 0) w.writeByte(',') catch return error.OutOfMemory;
        w.print(
            "{{\"keyid\":\"{s}\",\"sig\":\"{s}\"}}",
            .{ &signer.id, &sig },
        ) catch return error.OutOfMemory;
    }
    w.writeAll("]}\n") catch return error.OutOfMemory;
    return out.written();
}

pub fn keyMap(
    arena: std.mem.Allocator,
    groups: []const RoleSigners,
) error{OutOfMemory}!tuf.Map(tuf.Key) {
    var map: tuf.Map(tuf.Key) = .{};
    for (groups) |group| {
        for (group.signers) |signer| {
            const public = try arena.dupe(u8, &signer.publicHex());
            const id = try arena.dupe(u8, &signer.id);
            try map.map.put(
                arena,
                id,
                .{ .keytype = "ed25519", .scheme = "ed25519", .keyval = .{ .public = public } },
            );
        }
    }
    return map;
}

fn roleKeys(arena: std.mem.Allocator, group: RoleSigners) error{OutOfMemory}!tuf.RoleKeys {
    const ids = try arena.alloc([]const u8, group.signers.len);
    for (group.signers, ids) |signer, *id| id.* = try arena.dupe(u8, &signer.id);
    return .{ .keyids = ids, .threshold = group.threshold };
}

pub fn rootMetadata(
    arena: std.mem.Allocator,
    set: KeySet,
    version: u64,
    expires: i64,
) Error!tuf.Root {
    return .{
        ._type = "root",
        .spec_version = tuf.spec_version,
        .version = version,
        .expires = try rfc3339(arena, expires),
        .keys = try keyMap(arena, &.{ set.root, set.targets, set.snapshot, set.timestamp }),
        .roles = .{
            .root = try roleKeys(arena, set.root),
            .targets = try roleKeys(arena, set.targets),
            .snapshot = try roleKeys(arena, set.snapshot),
            .timestamp = try roleKeys(arena, set.timestamp),
        },
    };
}

fn targetMap(
    arena: std.mem.Allocator,
    inputs: []const TargetInput,
) error{OutOfMemory}!tuf.Map(tuf.TargetFile) {
    var map: tuf.Map(tuf.TargetFile) = .{};
    for (inputs) |input| {
        try map.map.put(arena, input.path, .{
            .length = input.bytes.len,
            .hashes = .{ .sha256 = try hexOf(arena, input.bytes) },
            .custom = input.custom,
        });
    }
    return map;
}

/// All metadata and target files of a repository snapshot, in write order (targets first,
/// timestamp last) so a reader never sees metadata that points at missing files.
pub fn publish(arena: std.mem.Allocator, input: Input) Error![]const File {
    var files: std.ArrayList(File) = .empty;
    try appendTargetFiles(arena, &files, input.targets);
    for (input.channels) |c| try appendTargetFiles(arena, &files, c.targets);
    const root = try rootMetadata(arena, input.keys, input.root_version, input.root_expires);
    try files.append(arena, .{
        .path = try arena.print("metadata/{d}.root.json", .{input.root_version}),
        .bytes = try signEnvelope(arena, root, input.keys.root.signers),
    });
    var snapshot_meta: tuf.Map(tuf.MetaFile) = .{};
    const roles = try appendChannels(arena, &files, input, &snapshot_meta);
    const targets: tuf.Targets = .{
        ._type = "targets",
        .spec_version = tuf.spec_version,
        .version = input.targets_version,
        .expires = try rfc3339(arena, input.expires),
        .targets = try targetMap(arena, input.targets),
        .delegations = .{ .keys = try keyMap(arena, &.{input.keys.channel}), .roles = roles },
    };
    try files.append(arena, .{
        .path = try arena.print("metadata/{d}.targets.json", .{input.targets_version}),
        .bytes = try signEnvelope(arena, targets, input.keys.targets.signers),
    });
    try snapshot_meta.map.put(arena, "targets.json", .{ .version = input.targets_version });
    try appendSnapshotAndTimestamp(arena, &files, input, snapshot_meta);
    return files.items;
}

fn appendTargetFiles(
    arena: std.mem.Allocator,
    files: *std.ArrayList(File),
    inputs: []const TargetInput,
) Error!void {
    for (inputs) |t| {
        try files.append(arena, .{ .path = try targetPath(arena, t.bytes), .bytes = t.bytes });
    }
}

fn appendChannels(
    arena: std.mem.Allocator,
    files: *std.ArrayList(File),
    input: Input,
    snapshot_meta: *tuf.Map(tuf.MetaFile),
) Error![]const tuf.Delegation {
    var roles: std.ArrayList(tuf.Delegation) = .empty;
    const channel_keys = try roleKeys(arena, input.keys.channel);
    for (input.channels) |c| {
        const name = @tagName(c.channel);
        try roles.append(arena, .{
            .name = name,
            .keyids = channel_keys.keyids,
            .threshold = channel_keys.threshold,
            .paths = &.{"manifests/*"},
            .terminating = true,
        });
        const signed: tuf.Targets = .{
            ._type = "targets",
            .spec_version = tuf.spec_version,
            .version = c.version,
            .expires = try rfc3339(arena, input.expires),
            .targets = try targetMap(arena, c.targets),
        };
        try files.append(arena, .{
            .path = try arena.print("metadata/{d}.{s}.json", .{ c.version, name }),
            .bytes = try signEnvelope(arena, signed, input.keys.channel.signers),
        });
        try snapshot_meta.map.put(
            arena,
            try arena.print("{s}.json", .{name}),
            .{ .version = c.version },
        );
    }
    return roles.items;
}

fn appendSnapshotAndTimestamp(
    arena: std.mem.Allocator,
    files: *std.ArrayList(File),
    input: Input,
    snapshot_meta: tuf.Map(tuf.MetaFile),
) Error!void {
    const snapshot: tuf.Snapshot = .{
        ._type = "snapshot",
        .spec_version = tuf.spec_version,
        .version = input.snapshot_version,
        .expires = try rfc3339(arena, input.expires),
        .meta = snapshot_meta,
    };
    const snapshot_bytes = try signEnvelope(arena, snapshot, input.keys.snapshot.signers);
    try files.append(
        arena,
        .{
            .path = try arena.print("metadata/{d}.snapshot.json", .{input.snapshot_version}),
            .bytes = snapshot_bytes,
        },
    );
    var timestamp_meta: tuf.Map(tuf.MetaFile) = .{};
    try timestamp_meta.map.put(arena, "snapshot.json", .{
        .version = input.snapshot_version,
        .length = snapshot_bytes.len,
        .hashes = .{ .sha256 = try hexOf(arena, snapshot_bytes) },
    });
    const timestamp: tuf.Timestamp = .{
        ._type = "timestamp",
        .spec_version = tuf.spec_version,
        .version = input.timestamp_version,
        .expires = try rfc3339(arena, input.timestamp_expires),
        .meta = timestamp_meta,
    };
    const timestamp_bytes = try signEnvelope(arena, timestamp, input.keys.timestamp.signers);
    try files.append(arena, .{ .path = "metadata/timestamp.json", .bytes = timestamp_bytes });
}

pub fn targetPath(arena: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}![]const u8 {
    return arena.print("targets/{s}", .{try hexOf(arena, bytes)});
}
