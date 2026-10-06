//! ThreadSanitizer lane (`zig build tsan`): engine worker + UI snapshot, broker IPC, crash state.

const std = @import("std");
const core = @import("core");

test "crash context phase updates are race-free" {
    const Worker = struct {
        fn run(rounds: u32) void {
            for (0..rounds) |round| {
                core.crash.setPhase(if (round % 2 == 0) .download else .verify);
                core.crash.setTransaction(round);
            }
        }
    };
    var threads: [4]std.Thread = undefined; // SAFETY: each slot is assigned by spawn below.
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Worker.run, .{1000});
    for (threads) |thread| thread.join();
}
