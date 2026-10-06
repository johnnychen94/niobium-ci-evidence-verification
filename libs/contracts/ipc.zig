//! Privilege helper IPC v1 (docs/spec/ipc-v1.md): 4-byte little-endian length + JSON, ≤ 1 MiB.
//! The op set mirrors the platform capability vtable one to one, so the broker is just another
//! `Platform` implementation and the helper dispatches onto the host backend.

const std = @import("std");
const json = @import("json.zig");
const limits_mod = @import("limits.zig");
const plan = @import("plan.zig");
const installation = @import("installation.zig");
const ids = @import("ids.zig");

pub const version = 1;
pub const max_frame_bytes = 1 << 20;

pub const Op = enum {
    create_directory,
    write_file,
    append_file,
    copy_file,
    rename,
    remove_file,
    remove_tree,
    set_pointer,
    remove_pointer,
    prepare_integration,
    discard_integration,
    activate_integration,
    remove_integration,
    free_space,
};

pub const MessageType = enum { hello, request, response, bye };

/// Mirrors `platform.api.IntegrationRequest`.
pub const IntegrationArgs = struct {
    integration: plan.Integration,
    product_id: []const u8,
    product_name: []const u8,
    scope: ids.Scope,
    root: []const u8,
    tx: u64,
};

pub const Args = struct {
    /// Directory, file, pointer link or free-space query path.
    path: ?[]const u8 = null,
    /// copy_file / rename source.
    source: ?[]const u8 = null,
    /// copy_file / rename destination, or the pointer target (relative to the link).
    target: ?[]const u8 = null,
    executable: bool = false,
    /// write_file / append_file bytes, standard base64.
    contents: ?[]const u8 = null,
    integration: ?IntegrationArgs = null,
    installed: ?installation.Integration = null,
};

/// Flat wire shape; which fields are required depends on `type` (checked by libs/privilege).
pub const Message = struct {
    v: u32,
    type: MessageType,
    tx: ?[]const u8 = null,
    nonce: ?[]const u8 = null,
    /// hello: install roots this transaction may mutate.
    managed_roots: ?[]const []const u8 = null,
    /// hello: staging roots copy_file may read from (never written by the helper).
    source_roots: ?[]const []const u8 = null,
    id: ?u64 = null,
    op: ?Op = null,
    args: ?Args = null,
    ok: ?bool = null,
    @"error": ?[]const u8 = null,
    /// activate_integration result.
    location: ?[]const u8 = null,
    /// free_space result.
    free_bytes: ?u64 = null,
};

pub const FrameError = error{ IpcFrameTooLarge, IpcTruncated };

pub fn decode(arena: std.mem.Allocator, payload: []const u8) json.DecodeError!Message {
    var limits = limits_mod.default;
    // write_file carries whole state files (plan, installation.json) as one base64 string.
    limits.json_string_bytes = max_frame_bytes;
    return json.decode(Message, arena, payload, .{
        .max_bytes = max_frame_bytes,
        .max_schema = version,
        .schema_field = "v",
        .limits = limits,
    });
}

pub fn encode(arena: std.mem.Allocator, message: Message) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(arena, message, .{ .emit_null_optional_fields = false });
}

pub fn writeFrame(
    writer: *std.Io.Writer,
    payload: []const u8,
) (FrameError || std.Io.Writer.Error)!void {
    if (payload.len > max_frame_bytes) return error.IpcFrameTooLarge;
    var header: [4]u8 = undefined; // SAFETY: fully written by writeInt.
    const len = std.math.cast(u32, payload.len) orelse return error.IpcFrameTooLarge;
    std.mem.writeInt(u32, &header, len, .little);
    try writer.writeAll(&header);
    try writer.writeAll(payload);
    try writer.flush();
}

/// Reads one frame into `arena`. EOF before a complete frame is IpcTruncated.
pub fn readFrame(
    arena: std.mem.Allocator,
    reader: *std.Io.Reader,
) (FrameError || error{OutOfMemory})![]u8 {
    var header: [4]u8 = undefined; // SAFETY: filled by readSliceAll or we return an error.
    reader.readSliceAll(&header) catch return error.IpcTruncated;
    const len = std.mem.readInt(u32, &header, .little);
    if (len > max_frame_bytes) return error.IpcFrameTooLarge;
    const payload = try arena.alloc(u8, len);
    reader.readSliceAll(payload) catch return error.IpcTruncated;
    return payload;
}

test "frames round trip and oversize frames are rejected" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const message: Message = .{
        .v = 1,
        .type = .request,
        .id = 4,
        .tx = "tx-1",
        .nonce = "00",
        .op = .copy_file,
        .args = .{ .source = "/s", .target = "/t", .executable = true },
    };
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try writeFrame(&out.writer, try encode(arena.allocator(), message));
    var reader: std.Io.Reader = .fixed(out.written());
    const decoded = try decode(arena.allocator(), try readFrame(arena.allocator(), &reader));
    try std.testing.expectEqual(Op.copy_file, decoded.op.?);
    try std.testing.expect(decoded.args.?.executable);

    var huge: [4]u8 = undefined; // SAFETY: fully written by writeInt.
    std.mem.writeInt(u32, &huge, max_frame_bytes + 1, .little);
    var bad: std.Io.Reader = .fixed(&huge);
    try std.testing.expectError(error.IpcFrameTooLarge, readFrame(arena.allocator(), &bad));
    var short: std.Io.Reader = .fixed(huge[0..2]);
    try std.testing.expectError(error.IpcTruncated, readFrame(arena.allocator(), &short));
}

test "N1-INV-08 newer IPC version fails closed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.UnsupportedSchema,
        decode(arena.allocator(), "{\"v\":2,\"type\":\"hello\"}"),
    );
    try std.testing.expectError(
        error.JsonType,
        decode(arena.allocator(), "{\"v\":1,\"type\":\"request\",\"op\":\"exec\"}"),
    );
}
