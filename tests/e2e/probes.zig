//! Independent observations: no status JSON or installer success message is trusted here.
const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts");
const evidence = @import("test_evidence");
const World = @import("world.zig").World;
const options = @import("suite_options");
const io = std.testing.io;

pub fn userData(w: *World) !void {
    try std.testing.expectEqualStrings("owned by the app", try w.read("user-data.txt"));
}

pub fn installed(w: *World, version: []const u8, sequence: u64) !void {
    const state = try contracts.installation.decodeInstallation(
        w.arena(),
        try w.read("managed/installation.json"),
    );
    try std.testing.expectEqualStrings("com.example.hello", state.product_id);
    try std.testing.expectEqualStrings(version, state.app_version);
    try std.testing.expectEqual(sequence, state.release_sequence);
    try std.testing.expectEqual(contracts.Scope.user, state.scope);
    try std.testing.expectEqual(@as(usize, 2), state.components.len);
    try std.testing.expectEqual(@as(usize, 64), state.manifest_sha256.len);
    try generation(w, state.active_tx);
    try payload(w, version);
    try userData(w);
    try evidence.attachment(try std.fmt.allocPrint(w.arena(), "{s}-probe-{d}.json", .{
        w.name, w.invocation,
    }), try std.json.Stringify.valueAlloc(w.arena(), .{
        .active_tx = state.active_tx,
        .version = version,
        .sequence = sequence,
        .manifest_sha256 = state.manifest_sha256,
    }, .{}));
}

fn generation(w: *World, active_tx: u64) !void {
    const desired = w.path(try std.fmt.allocPrint(w.arena(), "managed/versions/{d}", .{
        active_tx,
    }));
    const current = try std.Io.Dir.cwd().realPathFileAlloc(
        io,
        w.path("managed/current"),
        w.arena(),
    );
    const expected = try std.Io.Dir.cwd().realPathFileAlloc(io, desired, w.arena());
    if (!std.mem.eql(u8, expected, current)) return error.WrongGeneration;
}

fn payload(w: *World, version: []const u8) !void {
    const exe = if (builtin.os.tag == .windows) "hello.exe" else "hello";
    const executable = w.path(try std.fmt.allocPrint(
        w.arena(),
        "managed/current/runtime/bin/{s}",
        .{exe},
    ));
    try sameBytes(w, executable, options.hello_exe);
    try sameBytes(
        w,
        w.path("managed/current/docs/share/doc/hello/README.txt"),
        "examples/hello/components/docs/files/share/doc/hello/README.txt",
    );
    try std.testing.expectEqualStrings(
        version,
        try w.read("managed/current/runtime/bin/release.txt"),
    );
    const release = try w.expectExit(0, &.{ executable, "--release-probe" });
    try std.testing.expectEqualStrings(version, release.stdout);
}

fn sameBytes(w: *World, actual: []const u8, expected: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const actual_bytes = try cwd.readFileAlloc(io, actual, w.arena(), .limited(64 << 20));
    const expected_bytes = try cwd.readFileAlloc(io, expected, w.arena(), .limited(64 << 20));
    if (!std.mem.eql(
        u8,
        &evidence.model.digest(expected_bytes),
        &evidence.model.digest(actual_bytes),
    )) return error.PayloadMismatch;
}

test "N1-AC-20 independent probes reject corrupt payloads and lost application data" {
    var w: World = undefined; // SAFETY: init fills the complete fixture.
    try w.init("probe-negative");
    defer w.deinit();
    try userData(&w);
    try w.tmp.dir.writeFile(io, .{ .sub_path = "expected", .data = "correct" });
    try w.tmp.dir.writeFile(io, .{ .sub_path = "actual", .data = "corrupt" });
    try std.testing.expectError(
        error.PayloadMismatch,
        sameBytes(&w, w.path("actual"), w.path("expected")),
    );
    try w.tmp.dir.deleteFile(io, "user-data.txt");
    try std.testing.expectError(error.FileNotFound, userData(&w));
}

test "N1-AC-20 independent generation probe rejects a stale active pointer" {
    var w: World = undefined; // SAFETY: init fills the complete fixture.
    try w.init("wrong-generation");
    defer w.deinit();
    try w.tmp.dir.createDirPath(io, "managed/versions/1");
    try w.tmp.dir.createDirPath(io, "managed/versions/2");
    var host: @import("platform").Host = .init(io, .{ .env = .{} });
    try host.platform().setPointer(w.path("managed/current"), "versions/1");
    try generation(&w, 1);
    try std.testing.expectError(error.WrongGeneration, generation(&w, 2));
}
