const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts");
const repository = @import("repository");
const trust = @import("trust");
const portable = @import("root.zig");
const testing = @import("testing.zig");

test "portable targets are closed" {
    const plain = try portable.parseTarget("com.example.hello");
    try std.testing.expect(plain.entrypoint == null);
    const entry = try portable.parseTarget("com.example.hello:tool.main");
    try std.testing.expectEqualStrings("tool.main", entry.entrypoint.?);
    const bad = [_][]const u8{ "", "Hello", "com.example.hello:", "com.example.hello:x", "a:b.c" };
    for (bad) |text| try std.testing.expectError(
        error.PortableBadTarget,
        portable.parseTarget(text),
    );
}

const tool_script =
    \\#!/bin/sh
    \\exit "$1"
    \\
;

const release: testing.Release = .{
    .sequence = 1,
    .version = "1.0.0",
    .components = &.{.{
        .id = "tool",
        .files = &.{.{ .path = "bin/tool", .data = tool_script, .executable = true }},
        .entrypoints = &.{.{ .name = "main", .path = "bin/tool" }},
    }},
    .shortcuts = &.{.{ .name = "Tool", .entrypoint = "tool.main" }},
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    cache: portable.Cache,
    published: testing.Repo,

    fn init(f: *Fixture) !void {
        f.tmp = std.testing.tmpDir(.{});
        f.arena = .init(std.testing.allocator);
        const a = f.arena.allocator();
        const base = try f.tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
        f.cache = .{ .io = std.testing.io, .path = try std.fs.path.join(a, &.{ base, "cache" }) };
        f.published = try testing.publish(std.testing.io, a, release);
    }

    fn deinit(f: *Fixture) void {
        f.arena.deinit();
        f.tmp.cleanup();
    }

    fn prepare(f: *Fixture, repo: *const repository.Repository) portable.Error!portable.Prepared {
        const a = f.arena.allocator();
        return portable.prepare(std.testing.allocator, a, repo, f.cache, .{
            .target = .{ .product_id = testing.product_id },
            .root_bytes = f.published.root_bytes,
            .platform = testing.platform,
            .installer_version = "0.1.0",
            .now = trust.testing.now,
        });
    }

    /// The same repository with every artifact target replaced by `edit(bytes)`.
    fn without(
        f: *Fixture,
        comptime edit: fn (std.mem.Allocator, []const u8) anyerror![]const u8,
    ) !repository.Repository {
        const a = f.arena.allocator();
        const files = f.published.repo.embedded.files;
        const copy = try a.dupe(repository.embedded.File, files);
        for (copy) |*file| {
            for (f.published.artifacts) |bytes| {
                const path = try trust.publish.targetPath(a, bytes);
                if (std.mem.eql(u8, file.path, path)) file.bytes = try edit(a, file.bytes);
            }
        }
        return .{ .embedded = .{ .io = std.testing.io, .files = copy } };
    }
};

fn flipLast(arena: std.mem.Allocator, bytes: []const u8) anyerror![]const u8 {
    const out = try arena.dupe(u8, bytes);
    out[out.len - 1] ^= 0xff;
    return out;
}

fn empty(_: std.mem.Allocator, _: []const u8) anyerror![]const u8 {
    return "";
}

test "N1-UJ-08 portable run: TUF authorization, content-addressed cache, execution, GC" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();

    const tampered = try f.without(flipLast);
    try std.testing.expectError(error.HashMismatch, f.prepare(&tampered));

    const first = try f.prepare(&f.published.repo);
    const hex = contracts.ids.hexDigest(first.digests[0]);
    const want = try std.fs.path.join(a, &.{ f.cache.path, "sha256", &hex, "files", "bin/tool" });
    try std.testing.expectEqualStrings(want, first.exe);
    try std.testing.expectEqualStrings("1.0.0", first.product_version);

    // Cached: preparing again needs only metadata (the offline targets are truncated).
    const offline = try f.without(empty);
    const again = try f.prepare(&offline);
    try std.testing.expectEqualStrings(first.exe, again.exe);

    if (builtin.os.tag != .windows) {
        try std.testing.expectEqual(
            @as(u8, 0),
            try portable.run(std.testing.io, first, a, &.{"0"}, null),
        );
        try std.testing.expectEqual(
            @as(u8, 5),
            try portable.run(std.testing.io, first, a, &.{"5"}, null),
        );
    }

    const store = try std.fs.path.join(a, &.{ f.cache.path, "sha256" });
    const leftover = try std.fs.path.join(a, &.{ store, "abc.tmp-1234" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, leftover);
    const now = std.Io.Clock.real.now(std.testing.io).toSeconds();
    const day = trust.testing.day;
    try std.testing.expectEqual(@as(u32, 1), try f.cache.gc(a, now, day, first.digests));
    try std.testing.expectEqual(@as(u32, 0), try f.cache.gc(a, now, day, &.{}));
    try std.testing.expectEqual(@as(u32, 1), try f.cache.gc(a, now + 2 * day, day, &.{}));
    // Collected: the truncated offline target is downloaded again and refused.
    try std.testing.expectError(error.LengthMismatch, f.prepare(&offline));
}
