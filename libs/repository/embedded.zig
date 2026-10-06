//! Embedded repository: files compiled into the binary or loaded into memory (tests, sim).

const std = @import("std");
const root = @import("root.zig");

pub const File = struct { path: []const u8, bytes: []const u8 };

pub const Embedded = struct {
    io: std.Io,
    files: []const File,

    fn find(e: *const Embedded, path: []const u8) ?[]const u8 {
        for (e.files) |file| {
            if (std.mem.eql(u8, file.path, path)) return file.bytes;
        }
        return null;
    }

    pub fn fetch(
        e: *const Embedded,
        arena: std.mem.Allocator,
        path: []const u8,
        max: u64,
    ) root.FetchError![]u8 {
        const bytes = e.find(path) orelse return error.RepoNotFound;
        if (bytes.len > max) return error.RepoTooLarge;
        return arena.dupe(u8, bytes);
    }

    pub fn download(
        e: *const Embedded,
        path: []const u8,
        max: u64,
        dest: std.Io.Dir,
        name: []const u8,
    ) root.DownloadError!root.Downloaded {
        const bytes = e.find(path) orelse return error.RepoNotFound;
        if (bytes.len > max) return error.RepoTooLarge;
        dest.writeFile(
            e.io,
            .{ .sub_path = name, .data = bytes },
        ) catch return error.RepoWriteFailed;
        var digest: [32]u8 = @splat(0);
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        return .{ .length = bytes.len, .digest = digest };
    }
};

test "embedded lookups" {
    const repo: root.Repository = .{ .embedded = .{
        .io = std.testing.io,
        .files = &.{.{ .path = "targets/aa", .bytes = "x" }},
    } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("x", try repo.fetch(arena.allocator(), "targets/aa", 1));
    try std.testing.expectError(error.RepoNotFound, repo.fetch(arena.allocator(), "targets/bb", 1));
}
