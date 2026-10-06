//! Ed25519 keys, keyids (SHA-256 of the canonical key object) and threshold verification.

const std = @import("std");
const contracts = @import("contracts");

const tuf = contracts.tuf;
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Error = error{ TrustBadKey, SignatureThreshold, OutOfMemory };

pub const KeyId = [64]u8;

/// Canonical key object bytes:
/// {"keytype":"ed25519","keyval":{"public":"<hex>"},"scheme":"ed25519"}.
pub fn keyObject(buffer: *[160]u8, public: [32]u8) []const u8 {
    const hex = std.fmt.bytesToHex(public, .lower);
    const prefix = "{\"keytype\":\"ed25519\",\"keyval\":{\"public\":\"";
    const suffix = "\"},\"scheme\":\"ed25519\"}";
    @memcpy(buffer[0..prefix.len], prefix);
    @memcpy(buffer[prefix.len..][0..64], &hex);
    @memcpy(buffer[prefix.len + 64 ..][0..suffix.len], suffix);
    return buffer[0 .. prefix.len + 64 + suffix.len];
}

pub fn keyId(public: [32]u8) KeyId {
    var buffer: [160]u8 = @splat(0);
    var digest: [32]u8 = @splat(0);
    Sha256.hash(keyObject(&buffer, public), &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn publicKey(key: tuf.Key) Error!Ed25519.PublicKey {
    if (!std.mem.eql(u8, key.keytype, "ed25519") or !std.mem.eql(u8, key.scheme, "ed25519")) {
        return error.TrustBadKey;
    }
    const bytes = contracts.ids.parseHex32(key.keyval.public) orelse return error.TrustBadKey;
    return Ed25519.PublicKey.fromBytes(bytes) catch error.TrustBadKey;
}

/// A key entry must be listed under the id derived from its own bytes.
pub fn checkKeyId(id: []const u8, key: tuf.Key) Error!void {
    const pk = try publicKey(key);
    const expected = keyId(pk.toBytes());
    if (!std.mem.eql(u8, id, &expected)) return error.TrustBadKey;
}

/// At least `role.threshold` distinct authorized keys produced a valid signature over `message`.
pub fn verifyThreshold(
    message: []const u8,
    signatures: []const tuf.Signature,
    keys: tuf.Map(tuf.Key),
    role: tuf.RoleKeys,
) Error!void {
    if (role.threshold == 0) return error.SignatureThreshold;
    var counted: [64]KeyId = undefined; // SAFETY: only the first `valid` entries are read.
    var valid: usize = 0;
    for (signatures) |signature| {
        if (valid >= counted.len) break;
        if (!authorized(role, signature.keyid)) continue;
        if (seen(counted[0..valid], signature.keyid)) continue;
        const key = keys.map.get(signature.keyid) orelse continue;
        try checkKeyId(signature.keyid, key);
        if (!signatureValid(message, signature, key)) continue;
        @memcpy(&counted[valid], signature.keyid[0..64]);
        valid += 1;
    }
    if (valid < role.threshold) return error.SignatureThreshold;
}

fn authorized(role: tuf.RoleKeys, keyid: []const u8) bool {
    if (keyid.len != 64) return false;
    for (role.keyids) |id| {
        if (std.mem.eql(u8, id, keyid)) return true;
    }
    return false;
}

fn seen(ids: []const KeyId, keyid: []const u8) bool {
    for (ids) |*id| {
        if (std.mem.eql(u8, id, keyid)) return true;
    }
    return false;
}

fn signatureValid(message: []const u8, signature: tuf.Signature, key: tuf.Key) bool {
    const pk = publicKey(key) catch return false;
    if (signature.sig.len != 128) return false;
    var raw: [64]u8 = @splat(0);
    _ = std.fmt.hexToBytes(&raw, signature.sig) catch return false;
    Ed25519.Signature.fromBytes(raw).verify(message, pk) catch return false;
    return true;
}

/// A signing key with its precomputed keyid (packager and tests).
pub const Signer = struct {
    pair: Ed25519.KeyPair,
    id: KeyId,

    pub fn fromSeed(seed: [32]u8) error{TrustBadKey}!Signer {
        const pair = Ed25519.KeyPair.generateDeterministic(seed) catch return error.TrustBadKey;
        return .{ .pair = pair, .id = keyId(pair.public_key.toBytes()) };
    }

    pub fn sign(signer: Signer, message: []const u8) error{TrustBadKey}![128]u8 {
        const signature = signer.pair.sign(message, null) catch return error.TrustBadKey;
        return std.fmt.bytesToHex(signature.toBytes(), .lower);
    }

    pub fn publicHex(signer: Signer) [64]u8 {
        return std.fmt.bytesToHex(signer.pair.public_key.toBytes(), .lower);
    }
};

test "keyid is stable and signatures verify against the threshold" {
    const a = try Signer.fromSeed(@splat(1));
    const b = try Signer.fromSeed(@splat(2));
    try std.testing.expectEqualStrings(&a.id, &keyId(a.pair.public_key.toBytes()));
    var keys: tuf.Map(tuf.Key) = .{};
    defer keys.deinit(std.testing.allocator);
    const a_hex = a.publicHex();
    const b_hex = b.publicHex();
    const a_key: tuf.Key = .{
        .keytype = "ed25519",
        .scheme = "ed25519",
        .keyval = .{ .public = &a_hex },
    };
    const b_key: tuf.Key = .{
        .keytype = "ed25519",
        .scheme = "ed25519",
        .keyval = .{ .public = &b_hex },
    };
    try keys.map.put(std.testing.allocator, &a.id, a_key);
    try keys.map.put(std.testing.allocator, &b.id, b_key);
    const message = "{\"x\":1}";
    const sig_a = try a.sign(message);
    const sig_b = try b.sign(message);
    const role: tuf.RoleKeys = .{ .keyids = &.{ &a.id, &b.id }, .threshold = 2 };
    const both = [_]tuf.Signature{ .{
        .keyid = &a.id,
        .sig = &sig_a,
    }, .{ .keyid = &b.id, .sig = &sig_b } };
    try verifyThreshold(message, &both, keys, role);
    const twice = [_]tuf.Signature{ both[0], both[0] };
    try std.testing.expectError(
        error.SignatureThreshold,
        verifyThreshold(message, &twice, keys, role),
    );
    try std.testing.expectError(
        error.SignatureThreshold,
        verifyThreshold("{\"x\":2}", &both, keys, role),
    );
}
