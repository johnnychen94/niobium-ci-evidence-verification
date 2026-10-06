const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts");
const portable = @import("portable");
const trust = @import("trust");
const abi = @import("root.zig");

const io = std.testing.io;
const testing = portable.testing;

/// Statuses from distribution.h.
const DIST_OK = 0;
const DIST_E_USAGE = -2;
const DIST_E_NETWORK = -5;

const Events = struct {
    count: usize = 0,
    saw_complete: bool = false,
    saw_error: bool = false,

    fn record(user: ?*anyopaque, json: [*]const u8, len: usize) callconv(.c) void {
        const events: *Events = @ptrCast(@alignCast(user.?));
        const line = json[0..len];
        events.count += 1;
        if (std.mem.find(u8, line, "\"phase\":\"complete\"") != null) events.saw_complete = true;
        if (std.mem.find(u8, line, "\"phase\":\"error\"") != null) events.saw_error = true;
    }
};

const World = struct {
    tmp: std.testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    published: testing.Repo,
    repo: [:0]const u8,
    root: [:0]const u8,
    cache: [:0]const u8,

    fn init(w: *World) !void {
        w.tmp = std.testing.tmpDir(.{});
        w.arena_state = .init(std.testing.allocator);
        const a = w.arena_state.allocator();
        const base = try w.tmp.dir.realPathFileAlloc(io, ".", a);
        w.repo = try std.fs.path.joinZ(a, &.{ base, "repository" });
        w.root = try std.fs.path.joinZ(a, &.{ base, "root" });
        w.cache = try std.fs.path.joinZ(a, &.{ base, "cache" });
        const script = "#!/bin/sh\nexit 3\n";
        const files = try a.dupe(testing.File, &.{
            .{ .path = "bin/hello", .data = script, .executable = true },
        });
        const components = try a.dupe(testing.Component, &.{.{
            .id = "runtime",
            .files = files,
            .entrypoints = &.{.{ .name = "main", .path = "bin/hello" }},
        }});
        w.published = try testing.publish(io, a, .{
            .sequence = 1,
            .version = "1.0.0",
            // No integrations: the C ABI reads the real process environment, so a shortcut
            // would land in the developer's home directory.
            .components = components,
            .platform = contracts.Platform.current() orelse return error.SkipZigTest,
        });
        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, w.repo, .{});
        defer dir.close(io);
        for (w.published.repo.embedded.files) |file| {
            if (std.fs.path.dirname(file.path)) |parent| try dir.createDirPath(io, parent);
            try dir.writeFile(io, .{ .sub_path = file.path, .data = file.bytes });
        }
    }

    fn deinit(w: *World) void {
        w.arena_state.deinit();
        w.tmp.cleanup();
    }

    fn config(w: *const World) abi.Config {
        return .{
            .struct_size = @sizeOf(abi.Config),
            .repository = w.repo,
            .trust_root = w.published.root_bytes.ptr,
            .trust_root_len = w.published.root_bytes.len,
            .product_id = testing.product_id,
            .channel = null,
            .scope = 0,
            .install_dir = w.root,
            .work_dir = w.cache,
        };
    }

    fn open(w: *const World, api: *const abi.Api, cfg: *const abi.Config) !*abi.Handle {
        _ = w;
        var handle: ?*abi.Handle = null;
        try std.testing.expectEqual(DIST_OK, api.context_create(cfg, &handle));
        const c: *abi.Context = @ptrCast(@alignCast(handle.?));
        c.now = trust.testing.now;
        return handle.?;
    }
};

fn getApi() !*const abi.Api {
    var api: ?*const abi.Api = null;
    try std.testing.expectEqual(DIST_OK, abi.dist_get_api(abi.abi_v1, &api));
    try std.testing.expectEqual(@as(u32, @sizeOf(abi.Api)), api.?.struct_size);
    return api.?;
}

test "N1-UJ-09 C ABI host runs check, resolve, fetch, stage, commit" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const api = try getApi();
    const cfg = w.config();

    const first = try w.open(api, &cfg);
    var events: Events = .{};
    try std.testing.expectEqual(DIST_OK, api.event_subscribe(first, Events.record, &events));
    try std.testing.expectEqual(DIST_E_USAGE, api.fetch(first));
    var info: abi.UpdateInfo = .{
        .struct_size = @sizeOf(abi.UpdateInfo),
        .update_available = 0,
        .release_sequence = 0,
        .installed_release_sequence = 0,
        .version = @splat(0),
    };
    try std.testing.expectEqual(DIST_OK, api.check_update(first, &info));
    try std.testing.expectEqual(@as(i32, 1), info.update_available);
    try std.testing.expectEqual(@as(u64, 1), info.release_sequence);
    try std.testing.expectEqual(@as(u64, 0), info.installed_release_sequence);
    try std.testing.expectEqualStrings("1.0.0", std.mem.sliceTo(&info.version, 0));
    try std.testing.expectEqual(DIST_OK, api.resolve(first));
    try std.testing.expectEqual(DIST_OK, api.fetch(first));
    try std.testing.expectEqual(DIST_OK, api.stage(first));
    try std.testing.expectEqual(DIST_OK, api.transaction_commit(first));
    try std.testing.expect(events.saw_complete and events.count > 5);
    api.context_destroy(first);

    const hello = try std.fs.path.join(w.arena_state.allocator(), &.{
        w.root, "current", "runtime", "bin", "hello",
    });
    try std.Io.Dir.cwd().access(io, hello, .{});

    const second = try w.open(api, &cfg);
    defer api.context_destroy(second);
    try std.testing.expectEqual(DIST_OK, api.check_update(second, &info));
    try std.testing.expectEqual(@as(i32, 0), info.update_available);
    try std.testing.expectEqual(@as(u64, 1), info.installed_release_sequence);
    try std.testing.expectEqual(DIST_OK, api.fetch(second));
    try std.testing.expectEqual(DIST_OK, api.transaction_commit(second));

    if (builtin.os.tag == .windows) return;
    var path: abi.Buffer = .{ .data = null, .len = 0 };
    try std.testing.expectEqual(
        DIST_OK,
        api.portable_resolve(second, testing.product_id ++ ":runtime.main", &path),
    );
    try std.testing.expect(std.mem.endsWith(u8, path.data.?[0..path.len], "bin/hello"));
    var code: i32 = -1;
    const argv = [_:null]?[*:0]const u8{"ignored"};
    const target = testing.product_id ++ ":runtime.main";
    try std.testing.expectEqual(DIST_OK, api.portable_run(second, target, &argv, &code));
    try std.testing.expectEqual(@as(i32, 3), code);
}

test "C ABI rejects bad versions, configs and arguments with stable statuses" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    var none: ?*const abi.Api = null;
    try std.testing.expectEqual(DIST_E_USAGE, abi.dist_get_api(2, &none));
    try std.testing.expectEqual(DIST_E_USAGE, abi.dist_get_api(abi.abi_v1, null));
    const api = try getApi();
    var handle: ?*abi.Handle = null;
    try std.testing.expectEqual(DIST_E_USAGE, api.context_create(null, &handle));
    var cfg = w.config();
    cfg.scope = 7;
    try std.testing.expectEqual(DIST_E_USAGE, api.context_create(&cfg, &handle));
    cfg = w.config();
    cfg.struct_size = 4;
    try std.testing.expectEqual(DIST_E_USAGE, api.context_create(&cfg, &handle));
    cfg = w.config();
    cfg.product_id = "Not An Id";
    try std.testing.expectEqual(DIST_E_USAGE, api.context_create(&cfg, &handle));
    cfg = w.config();
    cfg.repository = "/nonexistent/niobium-repository";
    try std.testing.expectEqual(
        DIST_E_NETWORK,
        api.context_create(&cfg, &handle),
    );
    try std.testing.expectEqual(@as(?*abi.Handle, null), handle);
    try std.testing.expectEqual(DIST_E_USAGE, api.resolve(null));
    api.context_destroy(null);

    cfg = w.config();
    const ctx = try w.open(api, &cfg);
    defer api.context_destroy(ctx);
    try std.testing.expectEqual(DIST_E_USAGE, api.check_update(ctx, null));
    var err: abi.Buffer = .{ .data = null, .len = 0 };
    try std.testing.expectEqual(DIST_OK, api.last_error(ctx, &err));
    try std.testing.expectEqualStrings(
        "{\"code\":\"usage.null_argument\",\"message\":\"UsageNullArgument\",\"exit_code\":2}",
        err.data.?[0..err.len],
    );
    try std.testing.expectEqual(DIST_OK, api.cancel(ctx));
    try std.testing.expectEqual(@as(i32, -9), api.resolve(ctx));
}
