//! Role signing keys on disk: `<dir>/<role>.key.json` holds one Ed25519 seed. One key per role,
//! threshold 1 (docs/runbooks/release-signing.md). Key files never leave the signing machine.

const std = @import("std");
const contracts = @import("contracts");
const trust = @import("trust");

pub const roles = [_][]const u8{ "root", "targets", "snapshot", "timestamp", "channel" };

pub const KeyFile = struct {
    schema: u32,
    role: []const u8,
    /// 32-byte Ed25519 seed, lowercase hex.
    seed: []const u8,
    public: []const u8,
};

fn fileName(arena: std.mem.Allocator, role: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.key.json", .{role});
}

/// Writes a fresh key for every role; refuses to replace an existing key file.
pub fn generate(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir) !void {
    for (roles) |role| {
        var seed: [32]u8 = undefined; // SAFETY: filled by randomSecure.
        try io.randomSecure(&seed);
        const signer = try trust.keys.Signer.fromSeed(seed);
        const text = try std.json.Stringify.valueAlloc(arena, KeyFile{
            .schema = 1,
            .role = role,
            .seed = &std.fmt.bytesToHex(seed, .lower),
            .public = &signer.publicHex(),
        }, .{});
        const file = try dir.createFile(io, try fileName(arena, role), .{
            .exclusive = true,
            .permissions = private_file,
        });
        defer file.close(io);
        try file.writeStreamingAll(io, text);
    }
}

/// Owner-only on POSIX; on Windows the key directory's ACL is what protects the seed.
const private_file: std.Io.File.Permissions = if (@hasDecl(std.Io.File.Permissions, "fromMode"))
    .fromMode(0o600)
else
    .default_file;

fn load(
    io: std.Io,
    arena: std.mem.Allocator,
    dir: std.Io.Dir,
    role: []const u8,
) !trust.keys.Signer {
    const bytes = try dir.readFileAlloc(io, try fileName(arena, role), arena, .limited(4096));
    const key = try contracts.json.decode(KeyFile, arena, bytes, .{ .max_bytes = 4096 });
    if (!std.mem.eql(u8, key.role, role)) return error.PackKeyRole;
    var seed: [32]u8 = undefined; // SAFETY: hexToBytes fills all 32 bytes or fails.
    const raw = std.fmt.hexToBytes(&seed, key.seed) catch return error.PackKeyInvalid;
    if (raw.len != seed.len) return error.PackKeyInvalid;
    const signer = try trust.keys.Signer.fromSeed(seed);
    if (!std.mem.eql(u8, &signer.publicHex(), key.public)) return error.PackKeyInvalid;
    return signer;
}

pub fn loadSet(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir) !trust.publish.KeySet {
    var signers: [roles.len][]const trust.keys.Signer = undefined; // SAFETY: filled below.
    for (roles, &signers) |role, *out| {
        out.* = try arena.dupe(trust.keys.Signer, &.{try load(io, arena, dir, role)});
    }
    return .{
        .root = .{ .signers = signers[0] },
        .targets = .{ .signers = signers[1] },
        .snapshot = .{ .signers = signers[2] },
        .timestamp = .{ .signers = signers[3] },
        .channel = .{ .signers = signers[4] },
    };
}

test "generated keys load back and refuse to be overwritten" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try generate(io, arena.allocator(), tmp.dir);
    const set = try loadSet(io, arena.allocator(), tmp.dir);
    try std.testing.expect(!std.mem.eql(u8, &set.root.signers[0].id, &set.targets.signers[0].id));
    try std.testing.expectError(error.PathAlreadyExists, generate(io, arena.allocator(), tmp.dir));
}
