const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts");
const bootstrap = @import("root.zig");

const request: contracts.bootstrap.Request = .{
    .operation = .activate,
    .transaction_id = "tx-2-test",
    .from_version = "1.0.0",
    .to_version = "2.0.0",
    .scope = .user,
    .install_root = "/r",
};

const Scripts = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,

    fn init() Scripts {
        return .{ .tmp = std.testing.tmpDir(.{}), .arena = .init(std.testing.allocator) };
    }

    fn deinit(s: *Scripts) void {
        s.arena.deinit();
        s.tmp.cleanup();
    }

    /// Shell builtins only, so the child needs no PATH.
    fn write(s: *Scripts, name: []const u8, body: []const u8) ![]const u8 {
        const io = std.testing.io;
        const text = try s.arena.allocator().print("#!/bin/sh\n{s}\n", .{body});
        try s.tmp.dir.writeFile(io, .{ .sub_path = name, .data = text });
        const file = try s.tmp.dir.openFile(io, name, .{});
        defer file.close(io);
        try file.setPermissions(io, .executable_file);
        return s.tmp.dir.realPathFileAlloc(io, name, s.arena.allocator());
    }

    fn run(
        s: *Scripts,
        exe: []const u8,
        options: bootstrap.Options,
    ) bootstrap.Error!bootstrap.Result {
        return bootstrap.run(std.testing.io, s.arena.allocator(), exe, request, options);
    }
};

const ok_body =
    \\[ "$1" = "--installer-bootstrap-v1" ] || exit 9
    \\[ -z "$SECRET" ] || exit 4
    \\read -r line
    \\case "$line" in
    \\  *'"operation":"activate"'*'"from_version":"1.0.0"'*)
    \\    echo '{"protocol":1,"status":"ok","message":"migrated 2 tables"}' ;;
    \\  *) exit 3 ;;
    \\esac
;

test "N1-AC-08 bootstrap activate succeeds with a minimal environment" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var s: Scripts = .init();
    defer s.deinit();
    var parent: std.process.Environ.Map = .init(s.arena.allocator());
    try parent.put("SECRET", "do-not-leak");
    try parent.put("HOME", "/home/ann");
    const exe = try s.write("ok", ok_body);
    const result = try s.run(exe, .{ .parent_env = &parent });
    try std.testing.expectEqualStrings("migrated 2 tables", result.message.?);
    const env = try bootstrap.minimalEnv(s.arena.allocator(), &parent);
    try std.testing.expectEqualStrings("/home/ann", env.get("HOME").?);
    try std.testing.expect(env.get("SECRET") == null);
}

test "N1-AC-08 bootstrap failure semantics" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var s: Scripts = .init();
    defer s.deinit();
    const rejected = try s.write(
        "rejected",
        "read -r line\necho '{\"protocol\":1,\"status\":\"error\",\"message\":\"no\"}'",
    );
    try std.testing.expectError(error.BootstrapRejected, s.run(rejected, .{}));
    const crashed = try s.write(
        "crashed",
        "read -r line\necho '{\"protocol\":1,\"status\":\"ok\"}'\nexit 1",
    );
    try std.testing.expectError(error.BootstrapFailed, s.run(crashed, .{}));
    const silent = try s.write("silent", "read -r line");
    try std.testing.expectError(error.BootstrapBadResponse, s.run(silent, .{}));
    const extra = try s.write(
        "extra",
        "echo '{\"protocol\":1,\"status\":\"ok\",\"extra\":1}'",
    );
    try std.testing.expectError(error.BootstrapBadResponse, s.run(extra, .{}));
    const two = try s.write(
        "two",
        "echo '{\"protocol\":1,\"status\":\"ok\"}'\necho '{\"protocol\":1,\"status\":\"ok\"}'",
    );
    try std.testing.expectError(error.BootstrapBadResponse, s.run(two, .{}));
    try std.testing.expectError(
        error.BootstrapSpawnFailed,
        s.run("/nonexistent/niobium-bootstrap", .{}),
    );
}

test "N1-AC-08 bootstrap is killed at the deadline and on output floods" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var s: Scripts = .init();
    defer s.deinit();
    const spin = try s.write("spin", "while :; do :; done");
    try std.testing.expectError(error.BootstrapTimeout, s.run(spin, .{ .timeout_ms = 200 }));
    const flood = try s.write("flood", "while :; do echo xxxxxxxxxxxxxxxx; done");
    try std.testing.expectError(
        error.BootstrapBadResponse,
        s.run(flood, .{ .max_output = 1024, .timeout_ms = 10_000 }),
    );
}
