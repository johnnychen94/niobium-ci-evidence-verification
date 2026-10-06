//! HTTP(S) repository on std.http.Client. 404 is RepoNotFound; other non-200 statuses and
//! transport failures are RepoUnavailable. Bodies are bounded before they reach memory or disk.

const std = @import("std");
const root = @import("root.zig");

pub const Http = struct {
    client: *std.http.Client,
    /// Base URL without trailing slash, e.g. `https://dl.example.com/hello`.
    base: []const u8,
    cancel: ?*const std.atomic.Value(bool) = null,

    fn canceled(h: *const Http) bool {
        const flag = h.cancel orelse return false;
        return flag.load(.acquire);
    }

    fn start(h: *const Http, path: []const u8) root.FetchError!std.http.Client.Request {
        if (h.canceled()) return error.Canceled;
        var url_buffer: [2048]u8 = undefined; // SAFETY: written by bufPrint before use.
        const url = std.fmt.bufPrint(
            &url_buffer,
            "{s}/{s}",
            .{ h.base, path },
        ) catch return error.RepoNotFound;
        const uri = std.Uri.parse(url) catch return error.RepoUnavailable;
        var request = h.client.request(.GET, uri, .{
            .redirect_behavior = .init(3),
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
        }) catch |err| return mapError(err);
        errdefer request.deinit();
        request.sendBodiless() catch |err| return mapError(err);
        return request;
    }

    /// `request` must stay at a fixed address while the response is read.
    fn receive(
        request: *std.http.Client.Request,
        max: u64,
        redirect: []u8,
    ) root.FetchError!std.http.Client.Response {
        const response = request.receiveHead(redirect) catch |err| return mapError(err);
        switch (response.head.status) {
            .ok => {},
            .not_found, .gone => return error.RepoNotFound,
            else => return error.RepoUnavailable,
        }
        if (response.head.content_length) |length| {
            if (length > max) return error.RepoTooLarge;
        }
        return response;
    }

    pub fn fetch(
        h: *const Http,
        arena: std.mem.Allocator,
        path: []const u8,
        max: u64,
    ) root.FetchError![]u8 {
        var redirect: [8 << 10]u8 = undefined; // SAFETY: response head scratch.
        var request = try h.start(path);
        defer request.deinit();
        var response = try receive(&request, max, &redirect);
        var transfer: [64]u8 = undefined; // SAFETY: body reader scratch.
        const reader = response.reader(&transfer);
        // allocRemaining fails on reaching the limit, so allow one byte past `max`.
        const limit: std.Io.Limit = .limited64(max +| 1);
        const bytes = reader.allocRemaining(arena, limit) catch |err| return switch (err) {
            error.StreamTooLong => error.RepoTooLarge,
            error.OutOfMemory => error.OutOfMemory,
            error.ReadFailed => error.RepoUnavailable,
        };
        if (bytes.len > max) return error.RepoTooLarge;
        return bytes;
    }

    pub fn download(
        h: *const Http,
        path: []const u8,
        max: u64,
        dest: std.Io.Dir,
        name: []const u8,
    ) root.DownloadError!root.Downloaded {
        var redirect: [8 << 10]u8 = undefined; // SAFETY: response head scratch.
        var request = try h.start(path);
        defer request.deinit();
        var response = try receive(&request, max, &redirect);
        const io = h.client.io;
        const out = dest.createFile(
            io,
            name,
            .{ .truncate = true },
        ) catch return error.RepoWriteFailed;
        defer out.close(io);
        var write_buffer: [64 << 10]u8 = undefined; // SAFETY: writer scratch.
        var transfer: [64]u8 = undefined; // SAFETY: body reader scratch.
        var writer = out.writer(io, &write_buffer);
        const reader = response.reader(&transfer);
        return root.pump(reader, &writer.interface, max);
    }
};

const TestServer = struct {
    listener: std.Io.net.Server,
    requests: usize,

    fn serve(server: *TestServer) void {
        const io = std.testing.io;
        for (0..server.requests) |_| {
            const stream = server.listener.accept(io) catch return;
            defer stream.close(io);
            var recv: [4096]u8 = undefined; // SAFETY: connection reader scratch.
            var send: [4096]u8 = undefined; // SAFETY: connection writer scratch.
            var conn_reader = stream.reader(io, &recv);
            var conn_writer = stream.writer(io, &send);
            var http_server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);
            var request = http_server.receiveHead() catch return;
            const found = std.mem.eql(u8, request.head.target, "/r/metadata/timestamp.json");
            const body: []const u8 = if (found) "{\"ok\":1}" else "missing";
            request.respond(body, .{
                .status = if (found) .ok else .not_found,
                .keep_alive = false,
            }) catch return;
        }
    }
};

test "http fetch maps statuses and bounds bodies" {
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server: TestServer = .{
        .listener = try address.listen(io, .{ .reuse_address = true }),
        .requests = 4,
    };
    defer server.listener.deinit(io);
    const thread = try std.Thread.spawn(.{}, TestServer.serve, .{&server});
    defer thread.join();

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer client.deinit();
    var base_buffer: [64]u8 = undefined; // SAFETY: written by bufPrint.
    const port = server.listener.socket.address.getPort();
    const base = try std.fmt.bufPrint(&base_buffer, "http://127.0.0.1:{d}/r", .{port});
    const repo: root.Repository = .{ .http = .{ .client = &client, .base = base } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "{\"ok\":1}",
        try repo.fetch(a, "metadata/timestamp.json", 64),
    );
    try std.testing.expectError(error.RepoNotFound, repo.fetch(a, "metadata/1.root.json", 64));
    try std.testing.expectError(error.RepoTooLarge, repo.fetch(a, "metadata/timestamp.json", 3));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const got = try repo.download("metadata/timestamp.json", 64, tmp.dir, "t.json");
    try std.testing.expectEqual(@as(u64, 8), got.length);
}

fn mapError(err: anyerror) root.FetchError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.RepoUnavailable,
    };
}
