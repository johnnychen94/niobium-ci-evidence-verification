//! TUF profile v1 client flow (docs/spec/tuf-profile-v1.md#client-workflow). `source` is any
//! value with `fetch(arena, path, max_bytes) FetchError![]u8`; a missing file is
//! error.RepoNotFound.

const std = @import("std");
const contracts = @import("contracts");
const keys = @import("keys.zig");
const metadata = @import("metadata.zig");

const tuf = contracts.tuf;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const FetchError = error{ RepoNotFound, RepoUnavailable, RepoTooLarge, Canceled, OutOfMemory };

pub const Error = FetchError || metadata.Error || keys.Error || error{
    Expired,
    RollbackAttack,
    HashMismatch,
    LengthMismatch,
    UnknownRole,
    PathNotDelegated,
    UnauthorizedArtifact,
    ReleaseSequenceRegression,
    TrustRootVersion,
    TrustTooManyRotations,
    TrustMissingTarget,
    TrustReleaseSequenceMismatch,
    InvalidTimestamp,
};

pub const Options = struct {
    now: i64,
    channel: contracts.Channel = .stable,
    /// Versions persisted after the previous successful refresh (rollback protection).
    trusted: ?contracts.installation.TrustState = null,
    limits: contracts.Limits = contracts.limits.default,
};

pub const Verified = struct {
    root: tuf.Root,
    /// Bytes of the newest trusted root; persist as `trust/root.json`.
    root_bytes: []const u8,
    timestamp_version: u64,
    snapshot_version: u64,
    targets: tuf.Targets,
    channel: tuf.Targets,

    pub fn manifestTarget(
        v: Verified,
        arena: std.mem.Allocator,
        product_id: []const u8,
    ) Error!Target {
        const path = try arena.print("manifests/{s}.json", .{product_id});
        const file = v.channel.targets.map.get(path) orelse return error.TrustMissingTarget;
        const custom = file.custom orelse return error.TrustMissingTarget;
        return .{
            .digest = contracts.ids.parseHex32(
                file.hashes.sha256,
            ) orelse return error.TrustBadMetadata,
            .length = file.length,
            .release_sequence = custom.release_sequence,
            .app_version = custom.app_version,
        };
    }

    /// The artifact digest must be a top-level target hash; returns its length.
    pub fn authorizeArtifact(v: Verified, digest: contracts.Digest) Error!u64 {
        const hex = contracts.ids.hexDigest(digest);
        for (v.targets.targets.map.values()) |file| {
            if (std.mem.eql(u8, file.hashes.sha256, &hex)) return file.length;
        }
        return error.UnauthorizedArtifact;
    }

    pub fn state(v: Verified, release_sequence: u64) contracts.installation.TrustState {
        return .{
            .root_version = v.root.version,
            .timestamp_version = v.timestamp_version,
            .snapshot_version = v.snapshot_version,
            .targets_version = v.targets.version,
            .channel_version = v.channel.version,
            .release_sequence = release_sequence,
        };
    }
};

pub const Target = struct {
    digest: contracts.Digest,
    length: u64,
    release_sequence: u64,
    app_version: []const u8,
};

pub fn refresh(
    arena: std.mem.Allocator,
    source: anytype,
    root_bytes: []const u8,
    options: Options,
) Error!Verified {
    const root = try updateRoot(arena, source, root_bytes, options);
    try notExpired(root.loaded.envelope.signed.expires, options.now);
    const roles = root.loaded.envelope.signed;
    const timestamp = try loadVerified(tuf.Timestamp, arena, source, "metadata/timestamp.json", .{
        .expected_type = "timestamp",
        .max_bytes = options.limits.tuf_timestamp_bytes,
        .keys = roles.keys,
        .role = roles.roles.timestamp,
        .now = options.now,
        .limits = options.limits,
    });
    if (options.trusted) |t| try notOlder(timestamp.version, t.timestamp_version);
    const snapshot_meta = timestamp.meta.map.get(
        "snapshot.json",
    ) orelse return error.TrustBadMetadata;
    const snapshot = try loadSnapshot(arena, source, roles, snapshot_meta, options);
    const targets_meta = snapshot.meta.map.get("targets.json") orelse return error.TrustBadMetadata;
    const targets = try loadVersioned(arena, source, "targets", targets_meta.version, .{
        .expected_type = "targets",
        .max_bytes = options.limits.tuf_metadata_bytes,
        .keys = roles.keys,
        .role = roles.roles.targets,
        .now = options.now,
        .limits = options.limits,
    });
    const channel = try loadChannel(arena, source, targets, snapshot, options);
    return .{
        .root = roles,
        .root_bytes = root.bytes,
        .timestamp_version = timestamp.version,
        .snapshot_version = snapshot.version,
        .targets = targets,
        .channel = channel,
    };
}

const TrustedRoot = struct { loaded: metadata.Loaded(tuf.Root), bytes: []const u8 };

fn loadRoot(
    arena: std.mem.Allocator,
    bytes: []const u8,
    limits: contracts.Limits,
) Error!TrustedRoot {
    const loaded = try metadata.load(tuf.Root, arena, bytes, "root", limits);
    var it = loaded.envelope.signed.keys.map.iterator();
    if (loaded.envelope.signed.keys.map.count() > limits.tuf_keys) return error.TrustBadMetadata;
    while (it.next()) |entry| try keys.checkKeyId(entry.key_ptr.*, entry.value_ptr.*);
    return .{ .loaded = loaded, .bytes = bytes };
}

/// Walk N+1, N+2, … root versions; each must be signed by the old and the new root threshold.
fn updateRoot(
    arena: std.mem.Allocator,
    source: anytype,
    root_bytes: []const u8,
    options: Options,
) Error!TrustedRoot {
    var current = try loadRoot(arena, root_bytes, options.limits);
    const self_roles = current.loaded.envelope.signed;
    try keys.verifyThreshold(
        current.loaded.message,
        current.loaded.envelope.signatures,
        self_roles.keys,
        self_roles.roles.root,
    );
    if (options.trusted) |t| try notOlder(self_roles.version, t.root_version);
    for (0..options.limits.tuf_root_rotations) |_| {
        const old = current.loaded.envelope.signed;
        const path = try arena.print("metadata/{d}.root.json", .{old.version + 1});
        const bytes = source.fetch(
            arena,
            path,
            options.limits.tuf_metadata_bytes,
        ) catch |err| switch (err) {
            error.RepoNotFound => return current,
            else => |e| return e,
        };
        const next = try loadRoot(arena, bytes, options.limits);
        const new = next.loaded.envelope.signed;
        try keys.verifyThreshold(
            next.loaded.message,
            next.loaded.envelope.signatures,
            old.keys,
            old.roles.root,
        );
        try keys.verifyThreshold(
            next.loaded.message,
            next.loaded.envelope.signatures,
            new.keys,
            new.roles.root,
        );
        if (new.version != old.version + 1) return error.TrustRootVersion;
        current = next;
    }
    return error.TrustTooManyRotations;
}

const RoleCheck = struct {
    expected_type: []const u8,
    max_bytes: u32,
    keys: tuf.Map(tuf.Key),
    role: tuf.RoleKeys,
    now: i64,
    limits: contracts.Limits,
    meta: ?tuf.MetaFile = null,
};

fn loadVerified(
    comptime Signed: type,
    arena: std.mem.Allocator,
    source: anytype,
    path: []const u8,
    check: RoleCheck,
) Error!Signed {
    const bytes = source.fetch(arena, path, check.max_bytes) catch |err| switch (err) {
        error.RepoTooLarge => return error.MetadataTooLarge,
        else => |e| return e,
    };
    if (bytes.len > check.max_bytes) return error.MetadataTooLarge;
    if (check.meta) |meta| try matchMeta(bytes, meta);
    const loaded = try metadata.load(Signed, arena, bytes, check.expected_type, check.limits);
    try keys.verifyThreshold(loaded.message, loaded.envelope.signatures, check.keys, check.role);
    try notExpired(loaded.envelope.signed.expires, check.now);
    if (check.meta) |meta| {
        if (loaded.envelope.signed.version != meta.version) return error.RollbackAttack;
    }
    return loaded.envelope.signed;
}

fn loadVersioned(
    arena: std.mem.Allocator,
    source: anytype,
    name: []const u8,
    version: u64,
    check: RoleCheck,
) Error!tuf.Targets {
    var with_meta = check;
    with_meta.meta = .{ .version = version };
    const path = try arena.print("metadata/{d}.{s}.json", .{ version, name });
    return loadVerified(tuf.Targets, arena, source, path, with_meta);
}

fn loadSnapshot(
    arena: std.mem.Allocator,
    source: anytype,
    root: tuf.Root,
    meta: tuf.MetaFile,
    options: Options,
) Error!tuf.Snapshot {
    const path = try arena.print("metadata/{d}.snapshot.json", .{meta.version});
    const snapshot = try loadVerified(tuf.Snapshot, arena, source, path, .{
        .expected_type = "snapshot",
        .max_bytes = options.limits.tuf_metadata_bytes,
        .keys = root.keys,
        .role = root.roles.snapshot,
        .now = options.now,
        .limits = options.limits,
        .meta = meta,
    });
    if (options.trusted) |t| {
        try notOlder(snapshot.version, t.snapshot_version);
        const targets_meta = snapshot.meta.map.get(
            "targets.json",
        ) orelse return error.TrustBadMetadata;
        try notOlder(targets_meta.version, t.targets_version);
        const channel_name = try arena.print("{s}.json", .{@tagName(options.channel)});
        if (snapshot.meta.map.get(channel_name)) |channel_meta| try notOlder(
            channel_meta.version,
            t.channel_version,
        );
    }
    return snapshot;
}

fn loadChannel(
    arena: std.mem.Allocator,
    source: anytype,
    targets: tuf.Targets,
    snapshot: tuf.Snapshot,
    options: Options,
) Error!tuf.Targets {
    const name = @tagName(options.channel);
    const delegations = targets.delegations orelse return error.UnknownRole;
    const role = for (delegations.roles) |r| {
        if (std.mem.eql(u8, r.name, name)) break r;
    } else return error.UnknownRole;
    const meta = snapshot.meta.map.get(
        try arena.print("{s}.json", .{name}),
    ) orelse return error.UnknownRole;
    const channel = try loadVersioned(arena, source, name, meta.version, .{
        .expected_type = "targets",
        .max_bytes = options.limits.tuf_metadata_bytes,
        .keys = delegations.keys,
        .role = .{ .keyids = role.keyids, .threshold = role.threshold },
        .now = options.now,
        .limits = options.limits,
    });
    for (channel.targets.map.keys()) |path| {
        if (!delegated(role.paths, path)) return error.PathNotDelegated;
    }
    return channel;
}

fn delegated(patterns: []const []const u8, path: []const u8) bool {
    for (patterns) |pattern| {
        if (matchPath(pattern, path)) return true;
    }
    return false;
}

/// `*` matches any run of bytes except `/`.
pub fn matchPath(pattern: []const u8, path: []const u8) bool {
    const star = std.mem.findScalar(u8, pattern, '*') orelse return std.mem.eql(u8, pattern, path);
    const prefix = pattern[0..star];
    const suffix = pattern[star + 1 ..];
    if (std.mem.findScalar(u8, suffix, '*') != null) return false;
    if (path.len < prefix.len + suffix.len) return false;
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return false;
    return std.mem.findScalar(u8, path[prefix.len .. path.len - suffix.len], '/') == null;
}

fn matchMeta(bytes: []const u8, meta: tuf.MetaFile) Error!void {
    if (meta.length) |length| {
        if (bytes.len != length) return error.LengthMismatch;
    }
    if (meta.hashes) |hashes| {
        const expected = contracts.ids.parseHex32(
            hashes.sha256,
        ) orelse return error.TrustBadMetadata;
        try matchDigest(bytes, expected);
    }
}

pub fn matchDigest(bytes: []const u8, expected: contracts.Digest) error{HashMismatch}!void {
    var actual: [32]u8 = @splat(0);
    Sha256.hash(bytes, &actual, .{});
    if (!std.crypto.timing_safe.eql([32]u8, actual, expected)) return error.HashMismatch;
}

fn notExpired(expires: []const u8, now: i64) Error!void {
    const at = try contracts.time.parseUtc(expires);
    if (now >= at) return error.Expired;
}

fn notOlder(version: u64, trusted: u64) Error!void {
    if (version < trusted) return error.RollbackAttack;
}

/// Download a target by content address and verify length and SHA-256 before returning it.
pub fn fetchTarget(
    arena: std.mem.Allocator,
    source: anytype,
    digest: contracts.Digest,
    length: u64,
) Error![]const u8 {
    const hex = contracts.ids.hexDigest(digest);
    const path = try arena.print("targets/{s}", .{&hex});
    const bytes = try source.fetch(arena, path, length);
    if (bytes.len != length) return error.LengthMismatch;
    try matchDigest(bytes, digest);
    return bytes;
}

/// Update requires a strictly greater release_sequence; app_version may go down.
pub fn checkReleaseSequence(offered: u64, installed: ?u64) Error!void {
    if (installed) |current| {
        if (offered <= current) return error.ReleaseSequenceRegression;
    }
}

test "delegation path matching" {
    try std.testing.expect(matchPath("manifests/*", "manifests/com.example.hello.json"));
    try std.testing.expect(!matchPath("manifests/*", "manifests/a/b.json"));
    try std.testing.expect(!matchPath("manifests/*", "artifacts/x"));
    try std.testing.expect(matchPath("manifests/*.json", "manifests/x.json"));
}
