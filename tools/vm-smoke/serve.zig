//! Serves one bundle directory to guests over the Parallels shared network, so a guest needs
//! no shared folders: it downloads each file with its own tools (guest.fetch).

const std = @import("std");

const max_file = 64 << 20;

pub const Server = struct {
    io: std.Io,
    listener: std.Io.net.Server,
    address: std.Io.net.IpAddress,
    root: std.Io.Dir,
    thread: std.Thread,
    stop: std.atomic.Value(bool) = .init(false),

    /// `s` must stay at a fixed address until `shutdown`.
    pub fn start(s: *Server, io: std.Io, host: []const u8, root: std.Io.Dir) !void {
        const any = try std.Io.net.IpAddress.parse(host, 0);
        s.* = .{
            .io = io,
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
        if (s.address.connect(s.io, .{ .mode = .stream })) |stream| {
            stream.close(s.io);
        } else |err| std.log.warn("vm-smoke server wake: {t}", .{err});
        s.thread.join();
        s.listener.deinit(s.io);
    }

    pub fn url(s: *const Server, arena: std.mem.Allocator, rel: []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, "http://{f}/{s}", .{ s.address, rel });
    }

    fn loop(s: *Server) void {
        // loop-bound: one iteration per connection; `shutdown` connects once more to end it.
        while (true) {
            const stream = s.listener.accept(s.io) catch return;
            defer stream.close(s.io);
            if (s.stop.load(.acquire)) return;
            s.handle(stream) catch |err| std.log.warn("vm-smoke server: {t}", .{err});
        }
    }

    fn handle(s: *Server, stream: std.Io.net.Stream) !void {
        var recv: [8192]u8 = undefined; // SAFETY: connection reader scratch.
        var send: [8192]u8 = undefined; // SAFETY: connection writer scratch.
        var conn_reader = stream.reader(s.io, &recv);
        var conn_writer = stream.writer(s.io, &send);
        var http = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);
        var request = try http.receiveHead();
        const gpa = std.heap.smp_allocator;
        const body = s.file(gpa, request.head.target) catch |err| {
            return request.respond(@errorName(err), .{ .status = .not_found, .keep_alive = false });
        };
        defer gpa.free(body);
        try request.respond(body, .{ .keep_alive = false });
    }

    fn file(s: *Server, gpa: std.mem.Allocator, target: []const u8) ![]u8 {
        const path = std.mem.cutPrefix(u8, target, "/") orelse return error.OutsideBundle;
        if (std.mem.indexOf(u8, path, "..") != null) return error.OutsideBundle;
        return s.root.readFileAlloc(s.io, path, gpa, .limited(max_file));
    }
};
