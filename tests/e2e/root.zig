//! L4 end-to-end (docs/development/testing-lanes.md): examples/hello published by the real
//! `nbpack`, installed by the real generic `setup`, with the sample app's bootstrap log as the
//! witness that App Bootstrap v1 ran. Online goes through a local HTTP server; offline through a
//! bundle with no server at all.

const std = @import("std");
const builtin = @import("builtin");
const options = @import("suite_options");
const world = @import("world.zig");
const Server = @import("server.zig").Server;

const io = std.testing.io;
const World = world.World;
const Publisher = world.Publisher;
const product_id = world.product_id;

/// `setup <verb>` against one repository and trust root.
const Online = struct {
    w: *World,
    repo: []const u8,
    root: []const u8,

    fn run(o: Online, verb: []const u8, expected: u8) !void {
        _ = try o.w.setup(expected, &.{
            verb,   "--product", product_id, "--repo",   o.repo,   "--trust-root",
            o.root, "--scope",   "user",     "--silent", "--json",
        });
    }
};

test "N1-UJ-01 N1-UJ-03 N1-UJ-04 N1-INV-06 online install, update and incident rollback" {
    var w: World = undefined;
    try w.init("online");
    defer w.deinit();
    var p: Publisher = .{ .w = &w };
    try p.keygen();
    try p.release("1.0.0", 1, "stable");
    var repo_dir = try std.Io.Dir.cwd().openDir(io, w.path("repo"), .{});
    defer repo_dir.close(io);
    var server: Server = undefined;
    try server.start(repo_dir);
    defer server.shutdown();
    const online: Online = .{ .w = &w, .repo = try server.base(w.arena()), .root = p.trustRoot() };

    try online.run("install", 0);
    try std.testing.expect(server.served.load(.monotonic) > 0);
    var status = try expectRelease(&w, "1.0.0", 1);
    try std.testing.expectEqualStrings("done", status.bootstrap);
    try expectGreeting(&w, status.root);

    try p.release("1.1.0", 2, "stable");
    try online.run("update", 0);
    _ = try expectRelease(&w, "1.1.0", 2);

    // Incident rollback: a newer release that ships the older app version.
    try p.release("1.0.0", 3, "stable");
    try p.publish("1.0.1", 3, "stable", 3);
    try online.run("update", 0);
    status = try expectRelease(&w, "1.0.0", 3);
    try expectGreeting(&w, status.root);
    // Already current: update succeeds without a transaction.
    try online.run("update", 0);

    try expectLines(try w.bootstrapLog(), &.{
        "activate - 1.0.0 user",
        "activate 1.0.0 1.1.0 user",
        "activate 1.1.0 1.0.0 user",
    });
}

test "N1-UJ-05 N1-UJ-06 repair restores deleted and altered files; uninstall leaves nothing" {
    var w: World = undefined;
    try w.init("repair-uninstall");
    defer w.deinit();
    var p: Publisher = .{ .w = &w };
    try p.keygen();
    try p.release("1.0.0", 1, "stable");
    const local: Online = .{ .w = &w, .repo = w.path("repo"), .root = p.trustRoot() };
    try local.run("install", 0);
    const status = try expectRelease(&w, "1.0.0", 1);

    const readme = "current/docs/share/doc/hello/README.txt";
    const original = try w.read(try join(&w, status.root, readme));
    const cwd = std.Io.Dir.cwd();
    try cwd.deleteFile(io, try join(&w, status.root, "current/runtime/bin/hello"));
    try cwd.writeFile(io, .{ .sub_path = try join(&w, status.root, readme), .data = "tampered" });
    try local.run("repair", 0);
    try expectGreeting(&w, status.root);
    try std.testing.expectEqualStrings(original, try w.read(try join(&w, status.root, readme)));

    try local.run("uninstall", 0);
    _ = try w.setup(12, &.{ "status", "--json", "--product", product_id });
    try std.testing.expectError(error.FileNotFound, cwd.access(io, status.root, .{}));
    const log = try w.bootstrapLog();
    try expectLines(log, &.{ "activate - 1.0.0 user", "deactivate 1.0.0 1.0.0 user" });
}

test "N1-UJ-07 offline bundle installs a promoted, re-signed release without a server" {
    var w: World = undefined;
    try w.init("offline");
    defer w.deinit();
    var p: Publisher = .{ .w = &w };
    try p.keygen();
    try p.release("1.0.0", 1, "stable");
    try p.release("1.1.0", 2, "beta");
    const repo = w.path("repo");
    const keys = w.path("keys");
    const validated = try w.nbpack(
        0,
        &.{ "component", "validate", w.path("build-2/runtime.tar.zst") },
    );
    try std.testing.expect(std.mem.startsWith(u8, validated.stdout, "runtime 1.1.0 "));

    try promote(&w, "9", 3);
    try promote(&w, "2", 0);
    const before = try timestampVersion(&w);
    _ = try w.nbpack(0, &.{ "sign", "--repo", repo, "--keys", keys, "--timestamp-days", "365" });
    try std.testing.expectEqual(before + 1, try timestampVersion(&w));

    const config = w.path("product-config.json");
    _ = try w.nbpack(0, &.{
        "config",
        "--repo",
        repo,
        "--product",
        "examples/hello/product.json",
        "--branding",
        "examples/hello/branding.json",
        "--out",
        config,
    });
    const bundle = w.path("bundle");
    _ = try w.nbpack(
        0,
        &.{ "bundle", "--repo", repo, "--setup", options.setup_exe, "--out", bundle },
    );
    const setup = try join(&w, bundle, std.fs.path.basename(options.setup_exe));
    _ = try w.expectExit(
        0,
        &.{ setup, "install", "--config", config, "--scope", "user", "--silent", "--json" },
    );
    const status = try expectRelease(&w, "1.1.0", 2);
    try expectGreeting(&w, status.root);
    _ = try w.expectExit(0, &.{ setup, "uninstall", "--config", config, "--silent", "--json" });
    try expectLines(
        try w.bootstrapLog(),
        &.{ "activate - 1.1.0 user", "deactivate 1.1.0 1.1.0 user" },
    );
}

/// `nbpack promote` of release `sequence` to stable, expecting exit `expected`.
fn promote(w: *World, sequence: []const u8, expected: u8) !void {
    _ = try w.nbpack(expected, &.{
        "promote",
        "--repo",
        w.path("repo"),
        "--keys",
        w.path("keys"),
        "--product-id",
        product_id,
        "--sequence",
        sequence,
        "--channel",
        "stable",
        "--timestamp-days",
        "365",
    });
}

fn expectRelease(w: *World, version: []const u8, sequence: u64) !world.Status {
    const status = try w.status(&.{});
    try std.testing.expectEqualStrings(version, status.version);
    try std.testing.expectEqual(sequence, status.release_sequence);
    return status;
}

/// The installed app runs from `current/`.
fn expectGreeting(w: *World, root: []const u8) !void {
    const exe = if (builtin.os.tag == .windows) "hello.exe" else "hello";
    const path = try join(
        w,
        root,
        try std.fmt.allocPrint(w.arena(), "current/runtime/bin/{s}", .{exe}),
    );
    const result = try w.expectExit(0, &.{path});
    try std.testing.expectEqualStrings("Hello from the Niobium sample product.\n", result.stdout);
}

/// `wanted` appear in `text` as whole lines, in this order.
fn expectLines(text: []const u8, wanted: []const []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var index: usize = 0;
    while (lines.next()) |line| {
        if (index < wanted.len and std.mem.eql(u8, line, wanted[index])) index += 1;
    }
    if (index != wanted.len) {
        std.debug.print("e2e: bootstrap log lacks \"{s}\"\n{s}\n", .{ wanted[index], text });
        return error.TestExpectedLine;
    }
}

fn timestampVersion(w: *World) !i64 {
    const text = try w.read("repo/metadata/timestamp.json");
    const value = try std.json.parseFromSliceLeaky(std.json.Value, w.arena(), text, .{});
    return value.object.get("signed").?.object.get("version").?.integer;
}

fn join(w: *World, root: []const u8, sub: []const u8) ![]const u8 {
    return std.fs.path.join(w.arena(), &.{ root, sub });
}
