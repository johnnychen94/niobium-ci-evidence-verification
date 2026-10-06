//! Load a signed metadata file once as a dynamic value (for the canonical `signed` bytes) and
//! once strictly typed; check `_type` and `spec_version`.

const std = @import("std");
const contracts = @import("contracts");

const tuf = contracts.tuf;

pub const Error = contracts.json.DecodeError || contracts.canonical.Error || error{
    MetadataTooLarge,
    TrustBadMetadata,
};

pub fn Loaded(comptime Signed: type) type {
    return struct {
        envelope: tuf.Envelope(Signed),
        /// Canonical JSON of `signed`; the exact bytes signatures cover.
        message: []const u8,
    };
}

pub fn load(
    comptime Signed: type,
    arena: std.mem.Allocator,
    bytes: []const u8,
    expected_type: []const u8,
    limits: contracts.Limits,
) Error!Loaded(Signed) {
    const options: contracts.json.Options = .{
        .max_bytes = limits.tuf_metadata_bytes,
        .limits = limits,
    };
    if (bytes.len > options.max_bytes) return error.MetadataTooLarge;
    const value = try contracts.json.decodeValue(arena, bytes, options);
    if (value != .object) return error.TrustBadMetadata;
    const signed = value.object.get("signed") orelse return error.TrustBadMetadata;
    const message = try contracts.canonical.encode(arena, signed);
    const envelope = try contracts.json.decode(tuf.Envelope(Signed), arena, bytes, options);
    if (!std.mem.eql(u8, envelope.signed._type, expected_type)) return error.TrustBadMetadata;
    if (!std.mem.eql(
        u8,
        envelope.signed.spec_version,
        tuf.spec_version,
    )) return error.TrustBadMetadata;
    if (envelope.signatures.len > limits.tuf_signatures) return error.TrustBadMetadata;
    return .{ .envelope = envelope, .message = message };
}

test "metadata type is checked" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\{"signed":{"_type":"snapshot","spec_version":"1.0","version":1,
        \\ "expires":"2030-01-01T00:00:00Z","meta":{}},"signatures":[]}
    ;
    const loaded = try load(
        tuf.Timestamp,
        arena.allocator(),
        text,
        "snapshot",
        contracts.limits.default,
    );
    try std.testing.expect(std.mem.startsWith(u8, loaded.message, "{\"_type\":\"snapshot\""));
    try std.testing.expectError(
        error.TrustBadMetadata,
        load(tuf.Timestamp, arena.allocator(), text, "timestamp", contracts.limits.default),
    );
}
