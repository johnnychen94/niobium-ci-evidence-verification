//! Small Win32 helpers shared by the Windows integration files.

const std = @import("std");
const api = @import("api.zig");

const Error = api.Error;
const Allocator = std.mem.Allocator;

pub fn u32Of(value: usize) Error!u32 {
    return std.math.cast(u32, value) orelse error.PlatformIntegrationFailed;
}

pub fn wideOf(arena: Allocator, text: []const u8) Error![]const u16 {
    return std.unicode.wtf8ToWtf16LeAlloc(arena, text) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.PlatformIntegrationFailed,
    };
}

pub fn wideZ(arena: Allocator, text: []const u8) Error![:0]const u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(arena, text) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.PlatformIntegrationFailed,
    };
}

pub fn quoted(arena: Allocator, exe: []const u8) Error![]const u8 {
    if (std.mem.findScalar(u8, exe, '"') != null) return error.PlatformIntegrationFailed;
    return std.fmt.allocPrint(arena, "\"{s}\"", .{exe});
}

/// `GetLastError` after a failed Win32 call.
pub fn lastError() Error {
    return switch (std.os.windows.GetLastError()) {
        .ACCESS_DENIED => error.FsAccessDenied,
        else => error.PlatformIntegrationFailed,
    };
}
