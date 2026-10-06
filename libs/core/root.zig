//! Core: assertions, exit codes, crash record, phases. Depends only on std.

pub const assert = @import("assert.zig");
pub const exit_code = @import("exit_code.zig");
pub const crash = @import("crash.zig");

pub const ExitCode = exit_code.ExitCode;
pub const Phase = crash.Phase;
pub const invariant = assert.invariant;

test {
    _ = assert;
    _ = exit_code;
    _ = crash;
}
