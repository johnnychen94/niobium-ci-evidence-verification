//! Portable Run (profile PortableRun, docs/spec/cli-v1.md `setup run`): a TUF-authorized release
//! is unpacked into a content-addressed cache and one entrypoint is executed, unprivileged and
//! without machine integration. Cache layout under `<cache>`:
//!
//!   sha256/<hex>/component.json   validated component metadata
//!   sha256/<hex>/files/…          extracted artifact
//!   sha256/<hex>/last-used        unix seconds, read by `gc`
//!   sha256/<hex>.tmp-<rand>/      extraction in progress; published by one directory rename
//!   downloads/<hex>.tar.zst       transient
//!   trust.json                    TUF versions of the last refresh (rollback protection)

const std = @import("std");
const contracts = @import("contracts");
const manifest = @import("manifest");
const repository = @import("repository");
const resolver = @import("resolver");

pub const artifact = @import("artifact.zig");
pub const testing = @import("testing.zig");

const Dir = std.Io.Dir;

pub const Error = resolver.Error || artifact.Error || error{
    PortableBadTarget,
    PortableNoEntrypoint,
    PortableSpawnFailed,
};

/// `<product-id>[:<component>.<entrypoint>]`; without an entrypoint the first shortcut runs.
pub const Target = struct {
    product_id: []const u8,
    entrypoint: ?[]const u8 = null,
};

pub fn parseTarget(text: []const u8) error{PortableBadTarget}!Target {
    const colon = std.mem.findScalar(u8, text, ':');
    const id = if (colon) |at| text[0..at] else text;
    if (!contracts.ids.isProductId(id)) return error.PortableBadTarget;
    const at = colon orelse return .{ .product_id = id };
    const entry = text[at + 1 ..];
    if (contracts.ids.parseEntrypointRef(entry) == null) return error.PortableBadTarget;
    return .{ .product_id = id, .entrypoint = entry };
}

pub const Request = struct {
    target: Target,
    root_bytes: []const u8,
    channel: contracts.Channel = .stable,
    platform: contracts.Platform,
    installer_version: []const u8,
    now: i64,
    limits: contracts.Limits = .{},
    cancel: ?*const std.atomic.Value(bool) = null,
};

pub const Prepared = struct {
    /// Absolute path of the entrypoint inside the cache.
    exe: []const u8,
    /// Cache entries this run uses; pass them to `gc` as `keep`.
    digests: []const contracts.Digest,
    product_version: []const u8,
};

pub const Cache = struct {
    io: std.Io,
    /// Absolute cache directory (per user, per product).
    path: []const u8,

    fn join(c: Cache, arena: std.mem.Allocator, parts: []const []const u8) Error![]const u8 {
        var all: std.ArrayList([]const u8) = .empty;
        try all.append(arena, c.path);
        try all.appendSlice(arena, parts);
        return std.fs.path.join(arena, all.items);
    }

    pub fn entry(c: Cache, arena: std.mem.Allocator, digest: contracts.Digest) Error![]const u8 {
        return c.join(arena, &.{ "sha256", &contracts.ids.hexDigest(digest) });
    }

    fn openRoot(c: Cache, sub: []const u8) Error!Dir {
        const cwd = Dir.cwd();
        var root = cwd.createDirPathOpen(c.io, c.path, .{}) catch |err| return fsError(err);
        defer root.close(c.io);
        return root.createDirPathOpen(
            c.io,
            sub,
            .{ .open_options = .{ .iterate = true } },
        ) catch |err|
            fsError(err);
    }

    /// Validated metadata of the cached artifact, downloading and publishing it when missing.
    pub fn ensure(
        c: Cache,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        repo: *const repository.Repository,
        art: resolver.Artifact,
        expected: artifact.Expected,
    ) Error!manifest.ComponentMeta {
        var store = try c.openRoot("sha256");
        defer store.close(c.io);
        const hex = contracts.ids.hexDigest(art.digest);
        if (try c.cached(arena, store, &hex, expected)) |meta| return meta;
        var downloads = try c.openRoot("downloads");
        defer downloads.close(c.io);
        const name = artifact.fileName(art.digest);
        try artifact.download(c.io, repo, art, downloads, &name);
        defer downloads.deleteFile(c.io, &name) catch |err| logIgnored("download", err);
        var random: [8]u8 = undefined; // SAFETY: filled by random.
        c.io.random(&random);
        const temp = try arena.print("{s}.tmp-{s}", .{ &hex, &std.fmt.bytesToHex(random, .lower) });
        errdefer store.deleteTree(c.io, temp) catch |err| logIgnored("temp", err);
        const meta = try c.extractInto(gpa, arena, store, temp, downloads, &name, expected);
        store.rename(temp, store, &hex, c.io) catch |err| switch (err) {
            // Another run published the same content first; ours is redundant.
            error.DirNotEmpty, error.AccessDenied => {
                store.deleteTree(c.io, temp) catch |e| logIgnored("temp", e);
            },
            else => return fsError(err),
        };
        try c.touch(store, &hex);
        return meta;
    }

    fn extractInto(
        c: Cache,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        store: Dir,
        temp: []const u8,
        downloads: Dir,
        name: []const u8,
        expected: artifact.Expected,
    ) Error!manifest.ComponentMeta {
        var entry_dir = store.createDirPathOpen(c.io, temp, .{}) catch |err| return fsError(err);
        defer entry_dir.close(c.io);
        var files = entry_dir.createDirPathOpen(c.io, "files", .{}) catch |err| return fsError(err);
        defer files.close(c.io);
        const unpacked = try artifact.unpack(gpa, arena, c.io, downloads, name, files, expected);
        entry_dir.writeFile(c.io, .{
            .sub_path = "component.json",
            .data = unpacked.component_json,
        }) catch |err| return fsError(err);
        return unpacked.meta;
    }

    fn cached(
        c: Cache,
        arena: std.mem.Allocator,
        store: Dir,
        hex: []const u8,
        expected: artifact.Expected,
    ) Error!?manifest.ComponentMeta {
        const path = try std.fs.path.join(arena, &.{ hex, "component.json" });
        const limit: std.Io.Limit = .limited(expected.limits.manifest_bytes);
        const bytes = store.readFileAlloc(c.io, path, arena, limit) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return fsError(err),
        };
        const meta = try manifest.parseComponent(arena, bytes, expected.platform, expected.limits);
        if (!std.mem.eql(u8, meta.id, expected.component)) return error.ComponentIdMismatch;
        try c.touch(store, hex);
        return meta;
    }

    fn touch(c: Cache, store: Dir, hex: []const u8) Error!void {
        var buffer: [24]u8 = undefined; // SAFETY: written by bufPrint.
        const now = std.Io.Clock.real.now(c.io).toSeconds();
        const text = std.fmt.bufPrint(&buffer, "{d}", .{now}) catch return error.FsWriteFailed;
        var entry_dir = store.openDir(c.io, hex, .{}) catch |err| return fsError(err);
        defer entry_dir.close(c.io);
        entry_dir.writeFile(c.io, .{ .sub_path = "last-used", .data = text }) catch |err|
            return fsError(err);
    }

    /// Delete unfinished extractions, and entries not in `keep` unused for `max_age_s`.
    /// Returns how many entries were removed.
    pub fn gc(
        c: Cache,
        arena: std.mem.Allocator,
        now: i64,
        max_age_s: i64,
        keep: []const contracts.Digest,
    ) Error!u32 {
        var store = try c.openRoot("sha256");
        defer store.close(c.io);
        var stale: std.ArrayList([]const u8) = .empty;
        var it = store.iterate();
        while (it.next(c.io) catch |err| return fsError(err)) |item| {
            if (item.kind != .directory) continue;
            const unfinished = std.mem.find(u8, item.name, ".tmp-") != null;
            const expired = !kept(item.name, keep) and
                c.lastUsed(store, item.name) + max_age_s <= now;
            if (unfinished or expired) try stale.append(arena, try arena.dupe(u8, item.name));
        }
        for (stale.items) |name| {
            store.deleteTree(c.io, name) catch |err| return fsError(err);
        }
        return std.math.cast(u32, stale.items.len) orelse std.math.maxInt(u32);
    }

    fn lastUsed(c: Cache, store: Dir, name: []const u8) i64 {
        var entry_dir = store.openDir(c.io, name, .{}) catch return 0;
        defer entry_dir.close(c.io);
        var buffer: [24]u8 = undefined; // SAFETY: filled by readFile.
        const text = entry_dir.readFile(c.io, "last-used", &buffer) catch return 0;
        return std.fmt.parseInt(i64, std.mem.trim(u8, text, " \n"), 10) catch 0;
    }

    pub fn trustState(c: Cache, arena: std.mem.Allocator) ?contracts.installation.TrustState {
        const path = c.join(arena, &.{"trust.json"}) catch return null;
        const bytes = Dir.cwd().readFileAlloc(c.io, path, arena, .limited(64 << 10)) catch
            return null;
        return contracts.installation.decodeTrustState(arena, bytes) catch null;
    }

    pub fn saveTrustState(
        c: Cache,
        arena: std.mem.Allocator,
        state: contracts.installation.TrustState,
    ) Error!void {
        const bytes = try contracts.installation.encode(arena, state);
        var root = Dir.cwd().createDirPathOpen(c.io, c.path, .{}) catch |err| return fsError(err);
        defer root.close(c.io);
        root.writeFile(c.io, .{ .sub_path = "trust.json", .data = bytes }) catch |err|
            return fsError(err);
    }
};

fn kept(name: []const u8, keep: []const contracts.Digest) bool {
    const digest = contracts.ids.parseHex32(name) orelse return false;
    for (keep) |item| {
        if (std.mem.eql(u8, &item, &digest)) return true;
    }
    return false;
}

fn fsError(err: anyerror) Error {
    return switch (err) {
        error.NoSpaceLeft, error.DiskQuota => error.FsNoSpace,
        error.AccessDenied, error.PermissionDenied => error.FsAccessDenied,
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.FsWriteFailed,
    };
}

fn logIgnored(what: []const u8, err: anyerror) void {
    std.log.debug("portable cache cleanup ({s}): {t}", .{ what, err });
}

/// Resolve the target through TUF and make every selected artifact present in the cache.
pub fn prepare(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    repo: *const repository.Repository,
    cache: Cache,
    request: Request,
) Error!Prepared {
    const resolution = try resolver.resolve(arena, repo, .{
        .product_id = request.target.product_id,
        .root_bytes = request.root_bytes,
        .channel = request.channel,
        .platform = request.platform,
        .installer_version = request.installer_version,
        .now = request.now,
        .trusted = cache.trustState(arena),
        .limits = request.limits,
    });
    const metas = try arena.alloc(manifest.ComponentMeta, resolution.artifacts.len);
    const digests = try arena.alloc(contracts.Digest, resolution.artifacts.len);
    for (resolution.artifacts, metas, digests) |art, *meta, *digest| {
        meta.* = try cache.ensure(gpa, arena, repo, art, .{
            .component = art.component,
            .platform = request.platform,
            .limits = request.limits,
            .cancel = request.cancel,
        });
        digest.* = art.digest;
    }
    try cache.saveTrustState(arena, resolution.trust_state);
    const ref = request.target.entrypoint orelse defaultEntrypoint(resolution.manifest) orelse
        return error.PortableNoEntrypoint;
    const entry = try manifest.validate.resolveEntrypoint(metas, ref);
    const component = contracts.ids.parseEntrypointRef(ref).?.component;
    for (resolution.artifacts) |art| {
        if (!std.mem.eql(u8, art.component, component)) continue;
        const base = try cache.entry(arena, art.digest);
        return .{
            .exe = try std.fs.path.join(arena, &.{ base, "files", entry.path }),
            .digests = digests,
            .product_version = resolution.manifest.product.version,
        };
    }
    return error.PortableNoEntrypoint;
}

fn defaultEntrypoint(m: manifest.Manifest) ?[]const u8 {
    if (m.integrations.shortcuts.len == 0) return null;
    return m.integrations.shortcuts[0].entrypoint;
}

/// Run the prepared entrypoint with inherited stdio as the current (unprivileged) user and
/// return its exit code; termination by signal reports 128 + signal number, like a shell.
pub fn run(
    io: std.Io,
    prepared: Prepared,
    arena: std.mem.Allocator,
    args: []const []const u8,
    env: ?*const std.process.Environ.Map,
) Error!u8 {
    const argv = try arena.alloc([]const u8, args.len + 1);
    argv[0] = prepared.exe;
    @memcpy(argv[1..], args);
    var child = std.process.spawn(io, .{ .argv = argv, .environ_map = env }) catch
        return error.PortableSpawnFailed;
    const term = child.wait(io) catch return error.PortableSpawnFailed;
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped => |sig| 128 +| (std.math.cast(u8, @backingInt(sig)) orelse 127),
        .unknown => 255,
    };
}

test {
    _ = artifact;
    _ = testing;
    _ = @import("portable_test.zig");
}
