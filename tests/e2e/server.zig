//! Static file server for one repository directory at `http://127.0.0.1:<port>/repo/`.
//! One request per connection; `served` counts the files it returned so a test can prove an
//! operation went over the network, or did not.

const std = @import("std");

const io = std.testing.io;
const prefix = "/repo/";
const max_file = 64 << 20;

pub const Server = struct {
    listener: std.Io.net.Server,
    address: std.Io.net.IpAddress,
    root: std.Io.Dir,
    thread: std.Thread,
    stop: std.atomic.Value(bool) = .init(false),
    served: std.atomic.Value(u32) = .init(0),

    /// `s` must stay at a fixed address until `shutdown`.
    pub fn start(s: *Server, root: std.Io.Dir) !void {
        const any = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        s.* = .{
            .listener = try any.listen(io, .{ .reuse_address = true }),
            // SAFETY: assigned below once the listener has its port.
            .address = undefined,
            .root = root,
            // SAFETY: assigned below; `shutdown` is the only reader.
            .thread = undefined,
        };
        errdefer s.listener.deinit(io);
        s.address = s.listener.socket.address;
        s.thread = try std.Thread.spawn(.{}, loop, .{s});
    }

    pub fn shutdown(s: *Server) void {
        s.stop.store(true, .release);
        if (s.address.connect(io, .{ .mode = .stream })) |stream| {
            stream.close(io);
        } else |err| std.debug.print("e2e server wake: {t}\n", .{err});
        s.thread.join();
        s.listener.deinit(io);
    }

    pub fn base(s: *const Server, arena: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/repo", .{s.address.getPort()});
    }

    fn loop(s: *Server) void {
        // loop-bound: one iteration per connection; `shutdown` connects once more to end it.
        while (true) {
            const stream = s.listener.accept(io) catch return;
            defer stream.close(io);
            if (s.stop.load(.acquire)) return;
            s.handle(stream) catch |err| std.debug.print("e2e server: {t}\n", .{err});
        }
    }

    fn handle(s: *Server, stream: std.Io.net.Stream) !void {
        var recv: [8192]u8 = undefined; // SAFETY: connection reader scratch.
        var send: [8192]u8 = undefined; // SAFETY: connection writer scratch.
        var conn_reader = stream.reader(io, &recv);
        var conn_writer = stream.writer(io, &send);
        var http = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);
        var request = try http.receiveHead();
        const gpa = std.heap.smp_allocator;
        const body = s.file(gpa, request.head.target) catch |err| {
            return request.respond(@errorName(err), .{ .status = .not_found, .keep_alive = false });
        };
        defer gpa.free(body);
        try request.respond(body, .{ .keep_alive = false });
        _ = s.served.fetchAdd(1, .monotonic);
    }

    fn file(s: *Server, gpa: std.mem.Allocator, target: []const u8) ![]u8 {
        const path = std.mem.cutPrefix(u8, target, prefix) orelse return error.OutsideRepo;
        if (std.mem.indexOf(u8, path, "..") != null) return error.OutsideRepo;
        return s.root.readFileAlloc(io, path, gpa, .limited(max_file));
    }
};
