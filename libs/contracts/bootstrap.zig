//! App Bootstrap Protocol v1 (docs/spec/bootstrap-v1.md).

const std = @import("std");
const json = @import("json.zig");
const ids = @import("ids.zig");

pub const protocol = 1;
pub const flag = "--installer-bootstrap-v1";
pub const max_response_bytes = 64 << 10;

pub const Operation = enum { activate, deactivate };

pub const Request = struct {
    protocol: u32 = protocol,
    operation: Operation,
    transaction_id: []const u8,
    from_version: ?[]const u8,
    to_version: []const u8,
    scope: ids.Scope,
    install_root: []const u8,
};

pub const Status = enum { ok, @"error" };

pub const Response = struct {
    protocol: u32,
    status: Status,
    message: ?[]const u8 = null,
};

pub fn encodeRequest(arena: std.mem.Allocator, request: Request) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(arena, request, .{});
}

pub fn decodeResponse(arena: std.mem.Allocator, bytes: []const u8) json.DecodeError!Response {
    const line = std.mem.trimEnd(u8, bytes, "\r\n");
    return json.decode(Response, arena, line, .{
        .max_bytes = max_response_bytes,
        .max_schema = protocol,
        .schema_field = "protocol",
    });
}

pub fn decodeRequest(arena: std.mem.Allocator, bytes: []const u8) json.DecodeError!Request {
    return json.decode(Request, arena, bytes, .{
        .max_bytes = max_response_bytes,
        .max_schema = protocol,
        .schema_field = "protocol",
    });
}

test "N1-AC-08 bootstrap request and response wire shape" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const request = try encodeRequest(arena.allocator(), .{
        .operation = .activate,
        .transaction_id = "tx-3",
        .from_version = null,
        .to_version = "1.2.0",
        .scope = .user,
        .install_root = "/r",
    });
    try std.testing.expect(std.mem.find(u8, request, "\"from_version\":null") != null);
    const back = try decodeRequest(arena.allocator(), request);
    try std.testing.expectEqual(Operation.activate, back.operation);
    const response = try decodeResponse(arena.allocator(), "{\"protocol\":1,\"status\":\"ok\"}\n");
    try std.testing.expectEqual(Status.ok, response.status);
    try std.testing.expectError(
        error.JsonUnknownField,
        decodeResponse(arena.allocator(), "{\"protocol\":1,\"status\":\"ok\",\"x\":1}"),
    );
}
