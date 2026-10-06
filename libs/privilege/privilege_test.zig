//! Broker ↔ helper over real OS pipes with the helper on its own thread and VirtualPlatform as
//! its backend: the closed op set, session authentication, containment and helper loss.

const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts");
const platform = @import("platform");
const broker_mod = @import("broker.zig");
const helper = @import("helper.zig");

const ipc = contracts.ipc;
const File = std.Io.File;
const nonce = "0123456789abcdef0123456789abcdef";
const product = "com.example.hello";

fn pipe() ![2]File {
    const fds = try std.Io.Threaded.pipe2(.{});
    return .{
        .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
        .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
    };
}

/// Two pipes and a helper thread serving `backend` until bye or EOF.
const Rig = struct {
    io: std.Io,
    to_helper: [2]File,
    to_broker: [2]File,
    thread: std.Thread,
    outcome: helper.Outcome = .broker_gone,
    policy: helper.Policy,
    backend: platform.Platform,
    expect: helper.Expect,
    broker_read: [64 * 1024]u8 = undefined, // SAFETY: reader-owned scratch.
    broker_write: [64 * 1024]u8 = undefined, // SAFETY: writer-owned scratch.
    reader: File.Reader = undefined, // SAFETY: set in start.
    writer: File.Writer = undefined, // SAFETY: set in start.
    closed: bool = false,

    fn start(r: *Rig) !void {
        r.to_helper = try pipe();
        r.to_broker = try pipe();
        r.reader = r.to_broker[0].readerStreaming(r.io, &r.broker_read);
        r.writer = r.to_helper[1].writerStreaming(r.io, &r.broker_write);
        r.thread = try std.Thread.spawn(.{}, serveThread, .{r});
    }

    fn serveThread(r: *Rig) void {
        var read_buffer: [64 * 1024]u8 = undefined; // SAFETY: reader-owned scratch.
        var write_buffer: [64 * 1024]u8 = undefined; // SAFETY: writer-owned scratch.
        var reader = r.to_helper[0].readerStreaming(r.io, &read_buffer);
        var writer = r.to_broker[1].writerStreaming(r.io, &write_buffer);
        r.outcome = helper.serve(
            r.io,
            std.testing.allocator,
            &reader.interface,
            &writer.interface,
            r.expect,
            r.policy,
            r.backend,
        );
        // The helper process exits here: its ends close and the broker sees EOF.
        r.to_helper[0].close(r.io);
        r.to_broker[1].close(r.io);
    }

    fn broker(r: *Rig, credentials: broker_mod.Session) broker_mod.Broker {
        return .init(
            std.testing.allocator,
            r.io,
            &r.reader.interface,
            &r.writer.interface,
            credentials,
        );
    }

    fn stop(r: *Rig) void {
        if (r.closed) return;
        r.closed = true;
        r.to_helper[1].close(r.io);
        r.thread.join();
        r.to_broker[0].close(r.io);
    }
};

const World = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    base: []const u8 = "",
    install_base: []const u8 = "",
    root: []const u8 = "",
    staging: []const u8 = "",
    system: []const u8 = "",
    virtual: platform.Virtual = undefined, // SAFETY: set in init.
    dirs: [5][]const u8 = undefined, // SAFETY: set in init.
    bases: [1][]const u8 = undefined, // SAFETY: set in init.

    fn init(w: *World) !void {
        w.tmp = std.testing.tmpDir(.{});
        w.arena = .init(std.testing.allocator);
        const a = w.arena.allocator();
        const io = std.testing.io;
        w.base = try w.tmp.dir.realPathFileAlloc(io, ".", a);
        w.install_base = try std.fs.path.join(a, &.{ w.base, "opt" });
        w.root = try std.fs.path.join(a, &.{ w.install_base, product });
        w.staging = try std.fs.path.join(a, &.{ w.base, "cache", product, "staging", "tx-1" });
        w.system = try std.fs.path.join(a, &.{ w.base, "system" });
        try w.tmp.dir.createDirPath(io, "opt");
        try w.tmp.dir.createDirPath(io, "cache/" ++ product ++ "/staging/tx-1/bin");
        try w.tmp.dir.createDirPath(io, "system");
        w.virtual = .init(io, w.system);
        w.bases = .{w.install_base};
        for (std.enums.values(contracts.installation.IntegrationKind), 0..) |kind, i| {
            w.dirs[i] = try std.fmt.allocPrint(
                a,
                "{s}{c}{t}",
                .{ w.system, std.fs.path.sep, kind },
            );
        }
    }

    fn deinit(w: *World) void {
        w.arena.deinit();
        w.tmp.cleanup();
    }

    fn policy(w: *World) helper.Policy {
        return .{
            .install_bases = &w.bases,
            .integration_dirs = w.dirs[0..std.enums.values(
                contracts.installation.IntegrationKind,
            ).len],
            .self_exe = "/nonexistent/setup",
        };
    }

    fn path(w: *World, parts: []const []const u8) ![]const u8 {
        const a = w.arena.allocator();
        const all = try a.alloc([]const u8, parts.len + 1);
        all[0] = w.root;
        @memcpy(all[1..], parts);
        return std.fs.path.join(a, all);
    }
};

const session: broker_mod.Session = .{ .tx = "tx-1-test", .nonce = nonce };

fn rig(w: *World, expect: helper.Expect) Rig {
    return .{
        .io = std.testing.io,
        // SAFETY: start() creates both pipes and the thread before anything reads them.
        .to_helper = undefined,
        // SAFETY: as above.
        .to_broker = undefined,
        // SAFETY: as above.
        .thread = undefined,
        .policy = w.policy(),
        .backend = w.virtual.platform(),
        .expect = expect,
    };
}

test "broker drives the helper through a machine-scope release" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var w: World = .{ .tmp = undefined, .arena = undefined };
    try w.init();
    defer w.deinit();
    const io = std.testing.io;
    try w.tmp.dir.writeFile(
        io,
        .{ .sub_path = "cache/" ++ product ++ "/staging/tx-1/bin/hello", .data = "elf" },
    );
    var r = rig(&w, .{ .tx = session.tx, .nonce = session.nonce });
    try r.start();
    defer r.stop();
    var b = r.broker(session);
    defer b.deinit();
    try b.hello(&.{w.root}, &.{w.staging});
    const p = b.platform();

    try p.createDirPath(try w.path(&.{ "versions", "1", "bin" }));
    const staged = try std.fs.path.join(w.arena.allocator(), &.{ w.staging, "bin", "hello" });
    try p.copyFile(staged, try w.path(&.{ "versions", "1", "bin", "hello" }), true);
    try p.setPointer(try w.path(&.{"current"}), "versions/1");
    try p.writeFile(try w.path(&.{"installation.json"}), "{\"state\":1}", false);
    try p.appendFile(try w.path(&.{"journal.jsonl"}), "{}\n");
    try std.testing.expect(try p.freeSpace(w.root) > 0);
    const copied = try w.tmp.dir.readFileAlloc(
        io,
        "opt/" ++ product ++ "/current/bin/hello",
        w.arena.allocator(),
        .limited(16),
    );
    try std.testing.expectEqualStrings("elf", copied);

    const request: platform.api.IntegrationRequest = .{
        .integration = .{
            .kind = .shortcut,
            .id = "Hello",
            .label = "Hello",
            .target = "bin/hello",
        },
        .product_id = product,
        .product_name = "Hello",
        .scope = .machine,
        .root = w.root,
        .tx = 1,
    };
    try p.prepareIntegration(&request);
    const location = try p.activateIntegration(w.arena.allocator(), &request);
    try p.removeIntegration(.{ .kind = .shortcut, .id = "Hello", .location = location });

    var user = request;
    user.scope = .user;
    try std.testing.expectError(error.CapabilityUnsupported, p.prepareIntegration(&user));

    // Containment: outside the root, traversal, and a foreign integration location.
    const outside = try std.fs.path.join(w.arena.allocator(), &.{ w.base, "etc", "passwd" });
    try std.testing.expectError(error.FsAccessDenied, p.writeFile(outside, "x", false));
    const traversal = try std.fmt.allocPrint(w.arena.allocator(), "{s}/../x", .{w.root});
    try std.testing.expectError(error.FsAccessDenied, p.deleteTree(traversal));
    try std.testing.expectError(
        error.FsAccessDenied,
        p.setPointer(try w.path(&.{"current"}), "../../x"),
    );
    try std.testing.expectError(error.FsAccessDenied, p.removeIntegration(.{
        .kind = .shortcut,
        .id = "x",
        .location = outside,
    }));
    try std.testing.expectError(
        error.FsAccessDenied,
        p.copyFile(outside, try w.path(&.{"stolen"}), false),
    );

    // A symlink planted in staging is never followed by the privileged copy.
    try w.tmp.dir.symLink(io, outside, "cache/" ++ product ++ "/staging/tx-1/bin/evil", .{});
    const evil = try std.fs.path.join(w.arena.allocator(), &.{ w.staging, "bin", "evil" });
    try std.testing.expectError(
        error.FsAccessDenied,
        p.copyFile(evil, try w.path(&.{"stolen"}), false),
    );

    try b.bye();
    r.stop();
    try std.testing.expectEqual(helper.Outcome.bye, r.outcome);
}

test "N1-INV-04 helper refuses a forged session and roots outside the install base" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var w: World = .{ .tmp = undefined, .arena = undefined };
    try w.init();
    defer w.deinit();
    {
        var r = rig(&w, .{ .tx = session.tx, .nonce = "ffffffffffffffffffffffffffffffff" });
        try r.start();
        defer r.stop();
        var b = r.broker(session);
        defer b.deinit();
        try std.testing.expectError(error.PrivilegeHelperLost, b.hello(&.{w.root}, &.{}));
        try std.testing.expectError(error.PrivilegeHelperLost, b.platform().createDirPath(w.root));
    }
    {
        var r = rig(&w, .{ .tx = session.tx, .nonce = session.nonce });
        try r.start();
        defer r.stop();
        var b = r.broker(session);
        defer b.deinit();
        try std.testing.expectError(error.FsAccessDenied, b.hello(&.{w.base}, &.{}));
        r.stop();
        try std.testing.expectEqual(helper.Outcome.protocol_violation, r.outcome);
    }
}

fn rawFrame(writer: *std.Io.Writer, arena: std.mem.Allocator, message: ipc.Message) !void {
    try ipc.writeFrame(writer, try ipc.encode(arena, message));
}

test "N1-INV-04 helper ends the session on replayed ids and unknown ops" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var w: World = .{ .tmp = undefined, .arena = undefined };
    try w.init();
    defer w.deinit();
    const a = w.arena.allocator();
    {
        var r = rig(&w, .{ .tx = session.tx, .nonce = session.nonce });
        try r.start();
        defer r.stop();
        var b = r.broker(session);
        defer b.deinit();
        try b.hello(&.{w.root}, &.{});
        try b.platform().createDirPath(w.root);
        // Replay id 1.
        try rawFrame(&r.writer.interface, a, .{
            .v = 1,
            .type = .request,
            .tx = session.tx,
            .nonce = nonce,
            .id = 1,
            .op = .create_directory,
            .args = .{ .path = w.root },
        });
        const reply = try ipc.decode(a, try ipc.readFrame(a, &r.reader.interface));
        try std.testing.expectEqualStrings("replayed_id", reply.@"error".?);
        r.stop();
        try std.testing.expectEqual(helper.Outcome.protocol_violation, r.outcome);
    }
    {
        var r = rig(&w, .{ .tx = session.tx, .nonce = session.nonce });
        try r.start();
        defer r.stop();
        var b = r.broker(session);
        defer b.deinit();
        try b.hello(&.{w.root}, &.{});
        const unknown = "{\"v\":1,\"type\":\"request\",\"tx\":\"tx-1-test\"," ++
            "\"nonce\":\"" ++ nonce ++
            "\",\"id\":9,\"op\":\"exec\",\"args\":{\"path\":\"/bin/sh\"}}";
        try ipc.writeFrame(&r.writer.interface, unknown);
        const reply = try ipc.decode(a, try ipc.readFrame(a, &r.reader.interface));
        try std.testing.expectEqualStrings("bad_request", reply.@"error".?);
        r.stop();
        try std.testing.expectEqual(helper.Outcome.protocol_violation, r.outcome);
    }
}

test "a dead helper is PrivilegeHelperLost, and stays lost" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var w: World = .{ .tmp = undefined, .arena = undefined };
    try w.init();
    defer w.deinit();
    var r = rig(&w, .{ .tx = session.tx, .nonce = session.nonce });
    try r.start();
    defer r.stop();
    var b = r.broker(session);
    defer b.deinit();
    try b.hello(&.{w.root}, &.{});
    // Kill: the helper's next platform call dies (VirtualPlatform kill point).
    w.virtual.faults = .init(1, .{ .fault_per_mille = 0, .kill_at = 0 });
    const p = b.platform();
    try std.testing.expectError(error.PlatformKilled, p.createDirPath(w.root));
    // The helper process goes away (here: it quits on a garbage frame and closes its ends).
    try ipc.writeFrame(&r.writer.interface, "not json");
    var drain: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer drain.deinit();
    const goodbye = try ipc.readFrame(drain.allocator(), &r.reader.interface);
    try std.testing.expect(goodbye.len > 0);
    r.thread.join();
    try std.testing.expectEqual(helper.Outcome.protocol_violation, r.outcome);
    try std.testing.expectError(error.PrivilegeHelperLost, p.createDirPath(w.root));
    try std.testing.expectError(error.PrivilegeHelperLost, p.deleteTree(w.root));
    r.closed = true;
    r.to_helper[1].close(r.io);
    r.to_broker[0].close(r.io);
}
