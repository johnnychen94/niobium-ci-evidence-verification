//! TUF profile v1: canonical JSON signatures, Ed25519 thresholds, root rotation, timestamp /
//! snapshot / targets, one channel delegation layer, release_sequence monotonicity.

pub const keys = @import("keys.zig");
pub const metadata = @import("metadata.zig");
pub const client = @import("client.zig");
pub const publish = @import("publish.zig");
pub const testing = @import("testing.zig");

pub const Signer = keys.Signer;
pub const Verified = client.Verified;
pub const Error = client.Error;
pub const FetchError = client.FetchError;
pub const refresh = client.refresh;
pub const fetchTarget = client.fetchTarget;
pub const checkReleaseSequence = client.checkReleaseSequence;
pub const matchDigest = client.matchDigest;

test {
    _ = keys;
    _ = metadata;
    _ = client;
    _ = publish;
    _ = @import("trust_test.zig");
}
