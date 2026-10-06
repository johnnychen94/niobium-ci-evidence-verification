//! `zig build sim -Dseeds=N`: deterministic fault simulation. Each scenario runs once per seed;
//! a failure prints the seed so `zig build sim -Dseeds=1 -Dseed-start=<seed>` replays it.

const std = @import("std");
const options = @import("suite_options");
const scenarios = @import("scenarios.zig");

test "N1-AC-07 seeded faults never violate invariants" {
    var failures: u32 = 0;
    for (0..options.seeds) |offset| {
        const seed: u64 = options.seed_start + offset;
        inline for (scenarios.all) |scenario| {
            scenario.run(std.testing.allocator, seed) catch |err| {
                std.debug.print("sim: scenario {s} seed {d}: {s}\n", .{
                    scenario.name, seed, @errorName(err),
                });
                failures += 1;
            };
        }
    }
    try std.testing.expectEqual(@as(u32, 0), failures);
}
