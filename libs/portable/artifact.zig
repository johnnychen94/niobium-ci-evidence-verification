//! Artifact acquisition shared by the engine and Portable Run: download by content address with
//! length and SHA-256 checks, then strict extraction and component metadata validation.

const std = @import("std");
const contracts = @import("contracts");
const manifest = @import("manifest");
const package = @import("package");
const repository = @import("repository");
const resolver = @import("resolver");

const Dir = std.Io.Dir;

pub const Error = repository.DownloadError || package.Error || manifest.Error || error{
    HashMismatch,
    LengthMismatch,
    ComponentIdMismatch,
};

/// Download `artifact` to `dir/name` unless a file with the right length and hash is already
/// there (an interrupted earlier run). A mismatching download is deleted before returning.
pub fn download(
    io: std.Io,
    repo: *const repository.Repository,
    artifact: resolver.Artifact,
    dir: Dir,
    name: []const u8,
) Error!void {
    if (try alreadyThere(io, dir, name, artifact)) return;
    const path = targetPath(artifact.digest);
    const got = try repo.download(&path, artifact.length, dir, name);
    const length_ok = got.length == artifact.length;
    const digest_ok = std.crypto.timing_safe.eql([32]u8, got.digest, artifact.digest);
    if (length_ok and digest_ok) return;
    dir.deleteFile(io, name) catch |err| std.log.debug("discard download: {t}", .{err});
    return if (length_ok) error.HashMismatch else error.LengthMismatch;
}

fn alreadyThere(io: std.Io, dir: Dir, name: []const u8, artifact: resolver.Artifact) Error!bool {
    const file = dir.openFile(io, name, .{}) catch return false;
    defer file.close(io);
    const stat = file.stat(io) catch return false;
    if (stat.size != artifact.length) return false;
    var buffer: [64 << 10]u8 = undefined; // SAFETY: reader scratch.
    var reader = file.reader(io, &buffer);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    // loop-bound: the file has `artifact.length` bytes; every iteration consumes at least one.
    while (true) {
        const chunk = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return false,
        };
        hasher.update(chunk);
        reader.interface.toss(chunk.len);
    }
    return std.crypto.timing_safe.eql([32]u8, hasher.finalResult(), artifact.digest);
}

pub const Unpacked = struct {
    meta: manifest.ComponentMeta,
    /// Validated `component.json` bytes, for callers that persist them.
    component_json: []const u8,
    expanded: u64,
};

/// Extract `dir/name` into `dest` (an empty directory) and validate `component.json` against the
/// expected component and platform; executables get their mode bit.
pub fn unpack(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    dir: Dir,
    name: []const u8,
    dest: Dir,
    expected: Expected,
) Error!Unpacked {
    const file = dir.openFile(io, name, .{}) catch return error.RepoNotFound;
    defer file.close(io);
    const stat = file.stat(io) catch return error.FsWriteFailed;
    var buffer: [64 << 10]u8 = undefined; // SAFETY: reader scratch.
    var reader = file.reader(io, &buffer);
    const extracted = try package.extract(gpa, arena, io, &reader.interface, dest, .{
        .compressed_len = stat.size,
        .limits = expected.limits,
        .cancel = expected.cancel,
    });
    const meta = try manifest.parseComponent(
        arena,
        extracted.component_json,
        expected.platform,
        expected.limits,
    );
    if (!std.mem.eql(u8, meta.id, expected.component)) return error.ComponentIdMismatch;
    try package.markExecutables(io, dest, meta.executables);
    return .{
        .meta = meta,
        .component_json = extracted.component_json,
        .expanded = extracted.expanded,
    };
}

pub const Expected = struct {
    component: []const u8,
    platform: contracts.Platform,
    limits: contracts.Limits = .{},
    cancel: ?*const std.atomic.Value(bool) = null,
};

/// `targets/<hex>`, the repository path of a content-addressed target.
pub fn targetPath(digest: contracts.Digest) [8 + 64]u8 {
    return "targets/".* ++ contracts.ids.hexDigest(digest);
}

/// `<hex>.tar.zst`, the download file name of an artifact.
pub fn fileName(digest: contracts.Digest) [64 + 8]u8 {
    return contracts.ids.hexDigest(digest) ++ ".tar.zst".*;
}
