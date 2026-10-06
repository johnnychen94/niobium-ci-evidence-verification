//! Local directory repository (offline bundle `repository/`, `--repo <dir>`).

const std = @import("std");
const root = @import("root.zig");

pub const Directory = struct {
    io: std.Io,
    dir: std.Io.Dir,
    cancel: ?*const std.atomic.Value(bool) = null,

    fn canceled(d: *const Directory) bool {
        const flag = d.cancel orelse return false;
        return flag.load(.acquire);
    }

    pub fn fetch(
        d: *const Directory,
        arena: std.mem.Allocator,
        path: []const u8,
        max: u64,
    ) root.FetchError![]u8 {
        if (d.canceled()) return error.Canceled;
        // readFileAlloc fails on reaching the limit, so allow one byte past `max`.
        const limit: std.Io.Limit = .limited64(max +| 1);
        const bytes = d.dir.readFileAlloc(
            d.io,
            path,
            arena,
            limit,
        ) catch |err| return switch (err) {
            error.FileNotFound, error.NotDir, error.IsDir => error.RepoNotFound,
            error.StreamTooLong, error.FileTooBig => error.RepoTooLarge,
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            else => error.RepoUnavailable,
        };
        if (bytes.len > max) return error.RepoTooLarge;
        return bytes;
    }

    pub fn download(
        d: *const Directory,
        path: []const u8,
        max: u64,
        dest: std.Io.Dir,
        name: []const u8,
    ) root.DownloadError!root.Downloaded {
        if (d.canceled()) return error.Canceled;
        const file = d.dir.openFile(d.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.IsDir => return error.RepoNotFound,
            else => return error.RepoUnavailable,
        };
        defer file.close(d.io);
        const out = dest.createFile(
            d.io,
            name,
            .{ .truncate = true },
        ) catch return error.RepoWriteFailed;
        defer out.close(d.io);
        var read_buffer: [64 << 10]u8 = undefined; // SAFETY: reader scratch.
        var write_buffer: [64 << 10]u8 = undefined; // SAFETY: writer scratch.
        var reader = file.reader(d.io, &read_buffer);
        var writer = out.writer(d.io, &write_buffer);
        return root.pump(&reader.interface, &writer.interface, max);
    }
};

test "directory fetch and download" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "metadata");
    try tmp.dir.writeFile(io, .{ .sub_path = "metadata/timestamp.json", .data = "{}" });
    const repo: root.Repository = .{ .directory = .{ .io = io, .dir = tmp.dir } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "{}",
        try repo.fetch(arena.allocator(), "metadata/timestamp.json", 16),
    );
    try std.testing.expectEqualStrings(
        "{}",
        try repo.fetch(arena.allocator(), "metadata/timestamp.json", 2),
    );
    try std.testing.expectError(
        error.RepoNotFound,
        repo.fetch(arena.allocator(), "metadata/none.json", 16),
    );
    try std.testing.expectError(
        error.RepoTooLarge,
        repo.fetch(arena.allocator(), "metadata/timestamp.json", 1),
    );
    try std.testing.expectError(
        error.RepoNotFound,
        repo.fetch(arena.allocator(), "../etc/passwd", 16),
    );
    const got = try repo.download("metadata/timestamp.json", 16, tmp.dir, "copy");
    try std.testing.expectEqual(@as(u64, 2), got.length);
    try std.testing.expectError(
        error.RepoTooLarge,
        repo.download("metadata/timestamp.json", 1, tmp.dir, "copy2"),
    );
}
