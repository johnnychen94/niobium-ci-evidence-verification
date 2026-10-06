//! The publisher's view of a TUF repository directory (docs/spec/tuf-profile-v1.md): the
//! current targets and channel entries are read back from the newest metadata, changed, and the
//! whole snapshot is signed again with every version incremented. Existing roots and
//! content-addressed targets are never rewritten; `metadata/timestamp.json` is replaced last
//! and atomically, so a client never sees metadata that points at missing files.

const std = @import("std");
const contracts = @import("contracts");
const trust = @import("trust");

const tuf = contracts.tuf;
const publish = trust.publish;
const Dir = std.Io.Dir;

pub const day = 86_400;

/// Expiry policy, from the signing machine's clock.
pub const Clock = struct {
    now: i64,
    days: u32 = 30,
    timestamp_days: u32 = 1,
    root_days: u32 = 365,
};

pub const Channel = struct {
    channel: contracts.Channel,
    version: u64,
    targets: std.ArrayList(publish.TargetInput) = .empty,
};

pub const State = struct {
    /// 0 for a repository that has no metadata yet.
    root_version: u64 = 0,
    timestamp_version: u64 = 0,
    snapshot_version: u64 = 0,
    targets_version: u64 = 0,
    targets: std.ArrayList(publish.TargetInput) = .empty,
    channels: std.ArrayList(Channel) = .empty,

    pub fn channel(s: *State, arena: std.mem.Allocator, name: contracts.Channel) !*Channel {
        for (s.channels.items) |*c| if (c.channel == name) return c;
        try s.channels.append(arena, .{ .channel = name, .version = 0 });
        return &s.channels.items[s.channels.items.len - 1];
    }
};

const max_metadata = (contracts.Limits{}).tuf_metadata_bytes;

fn readSigned(
    comptime T: type,
    io: std.Io,
    arena: std.mem.Allocator,
    dir: Dir,
    path: []const u8,
) !T {
    const bytes = try dir.readFileAlloc(io, path, arena, .limited(max_metadata));
    const envelope = try contracts.json.decode(tuf.Envelope(T), arena, bytes, .{
        .max_bytes = max_metadata,
    });
    return envelope.signed;
}

fn exists(io: std.Io, dir: Dir, path: []const u8) bool {
    dir.access(io, path, .{}) catch return false;
    return true;
}

fn latestRoot(io: std.Io, arena: std.mem.Allocator, dir: Dir) !u64 {
    var version: u64 = 0;
    const rotations = (contracts.Limits{}).tuf_root_rotations;
    // loop-bound: at most `tuf_root_rotations` root versions.
    while (version < rotations) : (version += 1) {
        const path = try std.fmt.allocPrint(arena, "metadata/{d}.root.json", .{version + 1});
        if (!exists(io, dir, path)) break;
    }
    return version;
}

/// Target entries with their bytes from `targets/<sha256>`, checked against the metadata.
fn loadTargets(
    io: std.Io,
    arena: std.mem.Allocator,
    dir: Dir,
    map: tuf.Map(tuf.TargetFile),
    out: *std.ArrayList(publish.TargetInput),
) !void {
    var it = map.map.iterator();
    while (it.next()) |entry| {
        const file = entry.value_ptr.*;
        const path = try std.fmt.allocPrint(arena, "targets/{s}", .{file.hashes.sha256});
        const length = std.math.cast(usize, file.length) orelse return error.PackRepoCorrupt;
        const bytes = try dir.readFileAlloc(io, path, arena, .limited(length + 1));
        if (bytes.len != length) return error.PackRepoCorrupt;
        const actual = try publish.targetPath(arena, bytes);
        if (!std.mem.eql(u8, actual, path)) return error.PackRepoCorrupt;
        try out.append(arena, .{ .path = entry.key_ptr.*, .bytes = bytes, .custom = file.custom });
    }
}

/// The repository's current state; an empty state when it has no metadata.
pub fn load(io: std.Io, arena: std.mem.Allocator, dir: Dir) !State {
    var s: State = .{ .root_version = try latestRoot(io, arena, dir) };
    if (!exists(io, dir, "metadata/timestamp.json")) {
        if (s.root_version != 0) return error.PackRepoCorrupt;
        return s;
    }
    const timestamp = try readSigned(tuf.Timestamp, io, arena, dir, "metadata/timestamp.json");
    s.timestamp_version = timestamp.version;
    const snapshot_meta = timestamp.meta.map.get("snapshot.json") orelse
        return error.PackRepoCorrupt;
    s.snapshot_version = snapshot_meta.version;
    const snapshot_path = try std.fmt.allocPrint(
        arena,
        "metadata/{d}.snapshot.json",
        .{s.snapshot_version},
    );
    const snapshot = try readSigned(tuf.Snapshot, io, arena, dir, snapshot_path);
    var it = snapshot.meta.map.iterator();
    while (it.next()) |entry| {
        const name = std.mem.cutSuffix(u8, entry.key_ptr.*, ".json") orelse
            return error.PackRepoCorrupt;
        const version = entry.value_ptr.version;
        const path = try std.fmt.allocPrint(arena, "metadata/{d}.{s}.json", .{ version, name });
        const targets = try readSigned(tuf.Targets, io, arena, dir, path);
        if (std.mem.eql(u8, name, "targets")) {
            s.targets_version = version;
            try loadTargets(io, arena, dir, targets.targets, &s.targets);
        } else {
            const channel_name = std.meta.stringToEnum(contracts.Channel, name) orelse
                return error.PackRepoCorrupt;
            const c = try s.channel(arena, channel_name);
            c.version = version;
            try loadTargets(io, arena, dir, targets.targets, &c.targets);
        }
    }
    return s;
}

fn manifestPath(arena: std.mem.Allocator, product_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "manifests/{s}.json", .{product_id});
}

fn put(
    arena: std.mem.Allocator,
    list: *std.ArrayList(publish.TargetInput),
    t: publish.TargetInput,
) !void {
    for (list.items) |*existing| if (std.mem.eql(u8, existing.path, t.path)) {
        existing.* = t;
        return;
    };
    try list.append(arena, t);
}

/// The logical path of an artifact target: content-addressed, so releases share artifacts.
pub fn artifactPath(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const target = try publish.targetPath(arena, bytes);
    return std.fmt.allocPrint(arena, "artifacts/{s}.tar.zst", .{target["targets/".len..]});
}

/// Adds the release described by `manifest_bytes` to `channel`. Its sequence must exceed the
/// one the channel serves for the product (an incident rollback is a new, higher sequence).
pub fn addRelease(
    arena: std.mem.Allocator,
    s: *State,
    manifest_bytes: []const u8,
    artifacts: []const []const u8,
    channel: contracts.Channel,
) !void {
    const m = try contracts.json.decode(contracts.manifest.Manifest, arena, manifest_bytes, .{
        .max_bytes = (contracts.Limits{}).manifest_bytes,
    });
    const path = try manifestPath(arena, m.product.id);
    const c = try s.channel(arena, channel);
    for (c.targets.items) |t| if (std.mem.eql(u8, t.path, path)) {
        const current = t.custom orelse return error.PackRepoCorrupt;
        if (m.product.release_sequence <= current.release_sequence) {
            return error.PackSequenceNotIncreasing;
        }
    };
    for (artifacts) |bytes| {
        try put(arena, &s.targets, .{ .path = try artifactPath(arena, bytes), .bytes = bytes });
    }
    try put(arena, &c.targets, .{ .path = path, .bytes = manifest_bytes, .custom = .{
        .release_sequence = m.product.release_sequence,
        .app_version = m.product.version,
    } });
}

/// Serves the release with `sequence` of `product_id`, found in any channel, on `channel` too.
pub fn promote(
    arena: std.mem.Allocator,
    s: *State,
    product_id: []const u8,
    sequence: u64,
    channel: contracts.Channel,
) !void {
    const path = try manifestPath(arena, product_id);
    const target = findRelease(s, path, sequence) orelse return error.PackReleaseNotFound;
    try put(arena, &(try s.channel(arena, channel)).targets, target);
}

fn findRelease(s: *const State, path: []const u8, sequence: u64) ?publish.TargetInput {
    for (s.channels.items) |c| {
        for (c.targets.items) |t| {
            const custom = t.custom orelse continue;
            if (std.mem.eql(u8, t.path, path) and custom.release_sequence == sequence) return t;
        }
    }
    return null;
}

/// The existing root must list exactly the keys we sign with, or clients reject the result.
fn checkRootKeys(
    io: std.Io,
    arena: std.mem.Allocator,
    dir: Dir,
    version: u64,
    set: publish.KeySet,
) !void {
    const path = try std.fmt.allocPrint(arena, "metadata/{d}.root.json", .{version});
    const root = try readSigned(tuf.Root, io, arena, dir, path);
    const pairs = .{
        .{ root.roles.root, set.root },         .{ root.roles.targets, set.targets },
        .{ root.roles.snapshot, set.snapshot }, .{ root.roles.timestamp, set.timestamp },
    };
    inline for (pairs) |pair| {
        const listed = pair[0].keyids;
        if (listed.len != pair[1].signers.len) return error.PackRootKeyMismatch;
        for (listed, pair[1].signers) |id, signer| {
            if (!std.mem.eql(u8, id, &signer.id)) return error.PackRootKeyMismatch;
        }
    }
}

/// Signs and writes the next version of every role for `s`.
pub fn write(
    io: std.Io,
    arena: std.mem.Allocator,
    dir: Dir,
    s: *const State,
    set: publish.KeySet,
    clock: Clock,
) !void {
    const root_version = if (s.root_version == 0) 1 else s.root_version;
    if (s.root_version != 0) try checkRootKeys(io, arena, dir, root_version, set);
    const channels = try arena.alloc(publish.ChannelInput, s.channels.items.len);
    for (channels, s.channels.items) |*out, c| out.* = .{
        .channel = c.channel,
        .version = c.version + 1,
        .targets = c.targets.items,
    };
    const files = try publish.publish(arena, .{
        .keys = set,
        .root_version = root_version,
        .timestamp_version = s.timestamp_version + 1,
        .snapshot_version = s.snapshot_version + 1,
        .targets_version = s.targets_version + 1,
        .root_expires = clock.now + @as(i64, clock.root_days) * day,
        .expires = clock.now + @as(i64, clock.days) * day,
        .timestamp_expires = clock.now + @as(i64, clock.timestamp_days) * day,
        .targets = s.targets.items,
        .channels = channels,
    });
    try dir.createDirPath(io, "metadata");
    try dir.createDirPath(io, "targets");
    for (files) |file| try writeFile(io, arena, dir, file);
}

fn writeFile(io: std.Io, arena: std.mem.Allocator, dir: Dir, file: publish.File) !void {
    const immutable = std.mem.startsWith(u8, file.path, "targets/") or
        std.mem.endsWith(u8, file.path, ".root.json");
    if (immutable and exists(io, dir, file.path)) return;
    if (!std.mem.eql(u8, file.path, "metadata/timestamp.json")) {
        return dir.writeFile(io, .{ .sub_path = file.path, .data = file.bytes });
    }
    const temp = try std.fmt.allocPrint(arena, "{s}.tmp", .{file.path});
    try dir.writeFile(io, .{ .sub_path = temp, .data = file.bytes });
    try Dir.rename(dir, temp, dir, file.path, io);
}

/// Bytes of the newest root: what a setup built for this repository embeds.
pub fn rootBytes(io: std.Io, arena: std.mem.Allocator, dir: Dir) ![]const u8 {
    const version = try latestRoot(io, arena, dir);
    if (version == 0) return error.PackRepoEmpty;
    const path = try std.fmt.allocPrint(arena, "metadata/{d}.root.json", .{version});
    return dir.readFileAlloc(io, path, arena, .limited(max_metadata));
}
