//! The sample product's binary. Plain runs print a greeting; `--installer-bootstrap-v1`
//! implements App Bootstrap v1 (docs/spec/bootstrap-v1.md) by appending one line per call to
//! `<HOME or USERPROFILE>/.hello-bootstrap.log`, which the e2e suite reads back.

const std = @import("std");

const Request = struct {
    protocol: u32,
    operation: []const u8,
    transaction_id: []const u8,
    from_version: ?[]const u8 = null,
    to_version: []const u8,
    scope: []const u8,
    install_root: []const u8,
};

const max_request = 64 * 1024;
const max_log = 1 << 20;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var buffer: [1024]u8 = undefined; // SAFETY: writer scratch.
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const out = &stdout.interface;
    if (args.len == 2 and std.mem.eql(u8, args[1], "--installer-bootstrap-v1")) {
        const message = bootstrap(io, arena, init.environ_map) catch |err| {
            try out.print("{{\"protocol\":1,\"status\":\"error\",\"message\":\"{t}\"}}\n", .{err});
            try out.flush();
            return 1;
        };
        try out.print("{{\"protocol\":1,\"status\":\"ok\",\"message\":\"{s}\"}}\n", .{message});
    } else {
        try out.writeAll("Hello from the Niobium sample product.\n");
    }
    try out.flush();
    return 0;
}

fn bootstrap(
    io: std.Io,
    arena: std.mem.Allocator,
    env: *const std.process.Environ.Map,
) ![]const u8 {
    var reader_buffer: [4096]u8 = undefined; // SAFETY: reader scratch.
    var stdin = std.Io.File.stdin().readerStreaming(io, &reader_buffer);
    const text = try stdin.interface.allocRemaining(arena, .limited(max_request));
    const request = try std.json.parseFromSliceLeaky(Request, arena, text, .{});
    if (request.protocol != 1) return error.UnsupportedProtocol;
    const home = env.get("HOME") orelse env.get("USERPROFILE") orelse return error.NoHome;
    const path = try std.fs.path.join(arena, &.{ home, ".hello-bootstrap.log" });
    const cwd = std.Io.Dir.cwd();
    const previous = cwd.readFileAlloc(
        io,
        path,
        arena,
        .limited(max_log),
    ) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    const line = try std.fmt.allocPrint(arena, "{s}{s} {s} {s} {s}\n", .{
        previous,
        request.operation,
        request.from_version orelse "-",
        request.to_version,
        request.scope,
    });
    try cwd.writeFile(io, .{ .sub_path = path, .data = line });
    return std.fmt.allocPrint(arena, "{s} {s}", .{ request.operation, request.to_version });
}
