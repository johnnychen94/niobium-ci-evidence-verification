//! Canonical JSON (tuf-profile-v1): object keys sorted bytewise, no whitespace, integers only,
//! strings escape only `"`, `\` and U+0000–U+001F.

const std = @import("std");

pub const Error = error{ CanonicalNonInteger, OutOfMemory } || std.Io.Writer.Error;

/// Depth is bounded by the strict decoder (Limits.json_depth) that produced `value`.
pub fn write(gpa: std.mem.Allocator, writer: *std.Io.Writer, value: std.json.Value) Error!void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |i| try writer.print("{d}", .{i}),
        .float, .number_string => return error.CanonicalNonInteger,
        .string => |s| try writeString(writer, s),
        .array => |array| {
            try writer.writeByte('[');
            for (array.items, 0..) |item, index| {
                if (index > 0) try writer.writeByte(',');
                // lint-allow(no-recursion): depth bounded by Limits.json_depth (strict prescan).
                try write(gpa, writer, item);
            }
            try writer.writeByte(']');
        },
        .object => |object| {
            const keys = try gpa.dupe([]const u8, object.keys());
            defer gpa.free(keys);
            std.mem.sort([]const u8, keys, {}, lessThan);
            try writer.writeByte('{');
            for (keys, 0..) |key, index| {
                if (index > 0) try writer.writeByte(',');
                try writeString(writer, key);
                try writer.writeByte(':');
                // lint-allow(no-recursion): depth bounded by Limits.json_depth (strict prescan).
                try write(gpa, writer, object.get(key).?);
            }
            try writer.writeByte('}');
        },
    }
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

pub fn writeString(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (text) |char| {
        switch (char) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            0...0x1f => try writer.print("\\u{x:0>4}", .{char}),
            else => try writer.writeByte(char),
        }
    }
    try writer.writeByte('"');
}

/// Canonical bytes of `value`, allocated in `gpa`.
pub fn encode(gpa: std.mem.Allocator, value: std.json.Value) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    write(gpa, &out.writer, value) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return out.toOwnedSlice();
}

test "N1-AC-02 canonical form sorts keys and strips whitespace" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const value = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        "{ \"b\": [1, true, null], \"a\": \"x\\\"y\\n\" , \"A\": {} }",
        .{},
    );
    const bytes = try encode(arena.allocator(), value);
    const expected = "{\"A\":{},\"a\":\"x\\\"y\\u000a\",\"b\":[1,true,null]}";
    try std.testing.expectEqualStrings(expected, bytes);
}

test "floats are not canonical" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "[1.5]", .{});
    try std.testing.expectError(error.CanonicalNonInteger, encode(arena.allocator(), value));
}
