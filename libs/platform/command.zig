//! Runs the system managers integrations notify (launchctl, systemctl, update-desktop-database).
//! Fixed argv only, never a shell; output is capped and discarded.

const std = @import("std");
const api = @import("api.zig");

const Error = api.Error;

pub const Outcome = enum { ok, failed };

pub fn run(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) Error!Outcome {
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return .failed,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return if (result.term.success()) .ok else .failed;
}

/// Failure is an integration failure.
pub fn require(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) Error!void {
    if (try run(io, gpa, argv) == .failed) return error.PlatformIntegrationFailed;
}
