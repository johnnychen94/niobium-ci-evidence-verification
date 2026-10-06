//! Bounds-checked little-endian reads over an untrusted binary image.

const std = @import("std");

pub const Error = error{Truncated};

pub const Image = struct {
    data: []const u8,

    pub fn int(image: Image, comptime T: type, offset: u64) Error!T {
        const size = @sizeOf(T);
        const start = std.math.cast(usize, offset) orelse return error.Truncated;
        if (start > image.data.len or image.data.len - start < size) return error.Truncated;
        return std.mem.readInt(T, image.data[start..][0..size], .little);
    }

    pub fn slice(image: Image, offset: u64, len: u64) Error![]const u8 {
        const start = std.math.cast(usize, offset) orelse return error.Truncated;
        const n = std.math.cast(usize, len) orelse return error.Truncated;
        if (start > image.data.len or image.data.len - start < n) return error.Truncated;
        return image.data[start..][0..n];
    }

    /// NUL-terminated string starting at offset, at most `max` bytes.
    pub fn cstr(image: Image, offset: u64, max: usize) Error![]const u8 {
        const start = std.math.cast(usize, offset) orelse return error.Truncated;
        if (start >= image.data.len) return error.Truncated;
        const tail = image.data[start..@min(image.data.len, start +| max)];
        const end = std.mem.findScalar(u8, tail, 0) orelse return error.Truncated;
        return tail[0..end];
    }
};

/// Facts extracted from one binary; the policy lives in main.zig.
pub const Facts = struct {
    format: Format,
    dependencies: []const []const u8,
    writable_executable: []const []const u8,
    executable_stack: bool = false,
    /// PE only.
    aslr: ?bool = null,
    dep_nx: ?bool = null,
    high_entropy_va: ?bool = null,
};

pub const Format = enum { pe, macho, elf };

test "reads are bounds checked" {
    const image: Image = .{ .data = &.{ 1, 0, 0, 0, 'a', 0 } };
    try std.testing.expectEqual(@as(u32, 1), try image.int(u32, 0));
    try std.testing.expectError(error.Truncated, image.int(u32, 4));
    try std.testing.expectEqualStrings("a", try image.cstr(4, 16));
    try std.testing.expectError(error.Truncated, image.slice(std.math.maxInt(u64), 1));
}
