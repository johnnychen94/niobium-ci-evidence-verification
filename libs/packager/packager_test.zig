//! The packager's output is what the runtime accepts: artifacts pass the strict extractor,
//! manifests the strict parser, and repositories the TUF client, across releases and promotion.

const std = @import("std");
const contracts = @import("contracts");
const trust = @import("trust");
const packager = @import("root.zig");

const io = std.testing.io;
const now: i64 = 1_790_000_000;
const product_id = "com.example.hello";

const runtime_source =
    \\{"schema":1,"id":"runtime","entrypoints":{"main":{"path":"bin/hello","bootstrap":true}},
    \\ "executables":["bin/hello"]}
;

const template =
    \\{"schema":1,"min_installer":"0.1.0",
    \\ "product":{"id":"com.example.hello","name":"Hello","publisher":"Example",
    \\            "version":"1.0.0","release_sequence":1},
    \\ "install":{"default_scope":"user","allowed_scopes":["user"]},
    \\ "components":[{"id":"runtime","title":"Hello","required":true,"artifacts":{}}],
    \\ "bootstrap":{"entrypoint":"runtime.main","protocol":1}}
;

/// TUF client source over a repository directory.
const DirSource = struct {
    dir: std.Io.Dir,

    pub fn fetch(
        s: *const DirSource,
        arena: std.mem.Allocator,
        path: []const u8,
        max: u64,
    ) trust.FetchError![]u8 {
        const limit: std.Io.Limit = .limited(std.math.cast(usize, max) orelse
            return error.RepoTooLarge);
        return s.dir.readFileAlloc(io, path, arena, limit) catch |err| switch (err) {
            error.FileNotFound => error.RepoNotFound,
            error.StreamTooLong => error.RepoTooLarge,
            error.OutOfMemory => error.OutOfMemory,
            else => error.RepoUnavailable,
        };
    }
};

const World = struct {
    tmp: std.testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    repo: std.Io.Dir,
    keys: std.Io.Dir,

    fn init(w: *World) !void {
        w.tmp = std.testing.tmpDir(.{ .iterate = true });
        w.arena_state = .init(std.testing.allocator);
        w.repo = try w.tmp.dir.createDirPathOpen(io, "repo", .{});
        w.keys = try w.tmp.dir.createDirPathOpen(io, "keys", .{});
        try packager.keys.generate(io, w.arena_state.allocator(), w.keys);
    }

    fn deinit(w: *World) void {
        w.repo.close(io);
        w.keys.close(io);
        w.arena_state.deinit();
        w.tmp.cleanup();
    }

    fn artifact(w: *World, greeting: []const u8) !packager.compose.Artifact {
        const a = w.arena_state.allocator();
        const name = try std.fmt.allocPrint(a, "payload-{d}", .{greeting.len});
        var files = try w.tmp.dir.createDirPathOpen(
            io,
            name,
            .{ .open_options = .{ .iterate = true } },
        );
        defer files.close(io);
        try files.createDirPath(io, "bin");
        try files.writeFile(io, .{ .sub_path = "bin/hello", .data = greeting });
        try files.writeFile(io, .{ .sub_path = "README.txt", .data = "hello" });
        const o: packager.component.BuildOptions = .{
            .platform = .@"linux-x86_64",
            .version = "1.0.0",
        };
        const bytes = try packager.component.build(
            io,
            std.testing.allocator,
            a,
            runtime_source,
            files,
            o,
        );
        var scratch = try w.tmp.dir.createDirPathOpen(
            io,
            try std.fmt.allocPrint(a, "x-{s}", .{name}),
            .{},
        );
        defer scratch.close(io);
        const meta = try packager.component.validate(
            io,
            std.testing.allocator,
            a,
            bytes,
            scratch,
            o.platform,
        );
        return .{ .bytes = bytes, .meta = meta };
    }

    fn release(w: *World, sequence: u64, version: []const u8, greeting: []const u8) !void {
        const a = w.arena_state.allocator();
        const built = try w.artifact(greeting);
        const manifest = try packager.compose.compose(a, template, &.{built}, .{
            .version = version,
            .sequence = sequence,
        }, "0.1.0");
        var state = try packager.repo.load(io, a, w.repo);
        try packager.repo.addRelease(a, &state, manifest, &.{built.bytes}, .stable);
        try packager.repo.write(
            io,
            a,
            w.repo,
            &state,
            try packager.keys.loadSet(io, a, w.keys),
            .{ .now = now },
        );
    }

    fn verify(w: *World, channel: contracts.Channel) !trust.Verified {
        const a = w.arena_state.allocator();
        const root = try a.dupe(
            u8,
            try w.repo.readFileAlloc(io, "metadata/1.root.json", a, .unlimited),
        );
        const source: DirSource = .{ .dir = w.repo };
        return trust.refresh(a, &source, root, .{ .now = now + 60, .channel = channel });
    }
};

test "published releases verify with the TUF client; promotion and re-signing keep them" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const a = w.arena_state.allocator();

    try w.release(1, "1.0.0", "v1");
    var v = try w.verify(.stable);
    var target = try v.manifestTarget(a, product_id);
    try std.testing.expectEqual(@as(u64, 1), target.release_sequence);

    try w.release(2, "1.1.0", "v2-binary");
    v = try w.verify(.stable);
    target = try v.manifestTarget(a, product_id);
    try std.testing.expectEqual(@as(u64, 2), target.release_sequence);
    try std.testing.expectEqualStrings("1.1.0", target.app_version);
    try std.testing.expectEqual(@as(u64, 2), v.timestamp_version);
    try std.testing.expectError(error.PackSequenceNotIncreasing, w.release(2, "1.2.0", "again"));

    var state = try packager.repo.load(io, a, w.repo);
    try packager.repo.promote(a, &state, product_id, 2, .beta);
    const set = try packager.keys.loadSet(io, a, w.keys);
    try packager.repo.write(io, a, w.repo, &state, set, .{ .now = now });
    v = try w.verify(.beta);
    try std.testing.expectEqual(
        @as(u64, 2),
        (try v.manifestTarget(a, product_id)).release_sequence,
    );

    state = try packager.repo.load(io, a, w.repo);
    try packager.repo.write(io, a, w.repo, &state, set, .{ .now = now, .timestamp_days = 7 });
    v = try w.verify(.stable);
    try std.testing.expectEqual(@as(u64, 4), v.timestamp_version);
    try std.testing.expectEqual(@as(usize, 2), state.targets.items.len);
}

test "signing with keys the root does not list is refused" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const a = w.arena_state.allocator();
    try w.release(1, "1.0.0", "v1");
    var other = try w.tmp.dir.createDirPathOpen(io, "other-keys", .{});
    defer other.close(io);
    try packager.keys.generate(io, a, other);
    const state = try packager.repo.load(io, a, w.repo);
    try std.testing.expectError(error.PackRootKeyMismatch, packager.repo.write(
        io,
        a,
        w.repo,
        &state,
        try packager.keys.loadSet(io, a, other),
        .{ .now = now },
    ));
}

test "component build rejects missing entrypoints and the template must name every component" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const a = w.arena_state.allocator();
    var empty = try w.tmp.dir.createDirPathOpen(
        io,
        "empty",
        .{ .open_options = .{ .iterate = true } },
    );
    defer empty.close(io);
    try std.testing.expectError(error.PackMissingFile, packager.component.build(
        io,
        std.testing.allocator,
        a,
        runtime_source,
        empty,
        .{ .platform = .@"linux-x86_64", .version = "1.0.0" },
    ));
    try std.testing.expectError(
        error.PackMissingArtifact,
        packager.compose.compose(a, template, &.{}, .{}, "0.1.0"),
    );
}

test "setup config embeds the root and decodes as a branded product config" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try packager.setup.config(a, .{
        .product_id = product_id,
        .root_bytes = "{\"signed\":{}}",
        .branding_json = "{\"product_name\":\"Hello\",\"accent\":\"#0A66C2\"}",
        .logo_png = "\x89PNG",
    });
    const config = try contracts.installation.decodeProductConfig(a, bytes);
    try std.testing.expectEqualStrings(product_id, config.product_id.?);
    try std.testing.expectEqualStrings("{\"signed\":{}}", config.trust_root.?);
    try std.testing.expectEqualStrings("iVBORw==", config.branding.logo_png.?);
}
