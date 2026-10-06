//! Programmer invariants. Expected failures (IO, parsing, network, user cancel) are errors,
//! never asserts. This file and crash.zig are the only owners of @panic in libs/.

const std = @import("std");

pub const assert = std.debug.assert;

/// An invariant with a message that survives ReleaseSafe and names the broken guarantee.
pub fn invariant(ok: bool, comptime guarantee: []const u8) void {
    if (!ok) @panic("invariant violated: " ++ guarantee);
}

/// Unreachable state reached at runtime. Prefer an error when the input is external.
pub fn broken(comptime guarantee: []const u8) noreturn {
    @panic("invariant violated: " ++ guarantee);
}

test "invariant holds" {
    invariant(true, "true is true");
    assert(1 + 1 == 2);
}
