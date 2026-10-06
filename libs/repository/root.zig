//! Repository sources with the same layout (docs/spec/tuf-profile-v1.md#repository-layout):
//! HTTP, a local directory (offline bundle) and embedded bytes. `fetch` satisfies the trust
//! client's source contract; `download` streams a target to a file while hashing it.

const std = @import("std");
const contracts = @import("contracts");

pub const http = @import("http.zig");
pub const directory = @import("directory.zig");
pub const embedded = @import("embedded.zig");

pub const FetchError = error{ RepoNotFound, RepoUnavailable, RepoTooLarge, Canceled, OutOfMemory };
pub const DownloadError = FetchError || error{RepoWriteFailed};

pub const Downloaded = struct {
    length: u64,
    digest: contracts.Digest,
};

pub const Repository = union(enum) {
    http: http.Http,
    directory: directory.Directory,
    embedded: embedded.Embedded,

    pub fn fetch(
        repo: *const Repository,
        arena: std.mem.Allocator,
        path: []const u8,
        max: u64,
    ) FetchError![]u8 {
        try checkPath(path);
        return switch (repo.*) {
            inline else => |*source| source.fetch(arena, path, max),
        };
    }

    /// Stream `path` into `dest/name`, at most `max` bytes, returning length and SHA-256.
    pub fn download(
        repo: *const Repository,
        path: []const u8,
        max: u64,
        dest: std.Io.Dir,
        name: []const u8,
    ) DownloadError!Downloaded {
        try checkPath(path);
        return switch (repo.*) {
            inline else => |*source| source.download(path, max, dest, name),
        };
    }
};

/// Repository paths are fixed shapes; reject anything that could escape the root.
fn checkPath(path: []const u8) FetchError!void {
    contracts.ids.checkRelativePath(path, 512) catch return error.RepoNotFound;
    if (!std.mem.startsWith(u8, path, "metadata/") and !std.mem.startsWith(u8, path, "targets/")) {
        return error.RepoNotFound;
    }
}

/// Copy at most `max` bytes from `reader` into `out`, hashing on the way. One extra byte is
/// read past `max` so an oversize body is detected instead of silently truncated.
pub fn pump(reader: *std.Io.Reader, out: *std.Io.Writer, max: u64) DownloadError!Downloaded {
    var limit_buffer: [4096]u8 = undefined; // SAFETY: limited reader scratch.
    var hash_buffer: [4096]u8 = undefined; // SAFETY: hashed writer scratch.
    var limited = reader.limited(.limited64(max +| 1), &limit_buffer);
    var hashed = out.hashed(std.crypto.hash.sha2.Sha256.init(.{}), &hash_buffer);
    const count = limited.interface.streamRemaining(&hashed.writer) catch |err| switch (err) {
        error.ReadFailed => return error.RepoUnavailable,
        error.WriteFailed => return error.RepoWriteFailed,
    };
    if (count > max) return error.RepoTooLarge;
    hashed.writer.flush() catch return error.RepoWriteFailed;
    out.flush() catch return error.RepoWriteFailed;
    return .{ .length = count, .digest = hashed.hasher.finalResult() };
}

test {
    _ = http;
    _ = directory;
    _ = embedded;
}

test "pump enforces the byte limit and hashes" {
    var out: [64]u8 = undefined; // SAFETY: fixed writer scratch.
    var inner: std.Io.Writer = .fixed(&out);
    var source: std.Io.Reader = .fixed("hello");
    const done = try pump(&source, &inner, 10);
    try std.testing.expectEqual(@as(u64, 5), done.length);
    var expected: [32]u8 = @splat(0);
    std.crypto.hash.sha2.Sha256.hash("hello", &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &done.digest);
    var big: std.Io.Reader = .fixed("way too many bytes");
    var sink: std.Io.Writer = .fixed(&out);
    try std.testing.expectError(error.RepoTooLarge, pump(&big, &sink, 4));
}
