//! Simulation scenarios. Each exposes `name` and `run(gpa, seed) !void`.

const std = @import("std");
const platform = @import("platform");
const transaction = @import("transaction");

const testing = transaction.testing;

pub const all = .{ FaultReplay, TransactionFaults };

/// The fault schedule itself must replay exactly; every other scenario depends on it.
const FaultReplay = struct {
    pub const name = "fault-replay";

    pub fn run(gpa: std.mem.Allocator, seed: u64) !void {
        _ = gpa;
        const ops = std.enums.values(platform.fault.Op);
        var first = platform.FaultPlan.init(seed, .{ .fault_per_mille = 250 });
        var second = platform.FaultPlan.init(seed, .{ .fault_per_mille = 250 });
        for (0..128) |round| {
            const op = ops[round % ops.len];
            if (first.next(op) != second.next(op)) return error.SimNondeterministic;
        }
    }
};

/// Seeded faults and kills during a transaction and during up to four recovery restarts; a
/// final fault-free recovery must leave Active exactly OLD or NEW (N1-INV-01 under N1-AC-07).
const TransactionFaults = struct {
    pub const name = "transaction-faults";
    const restarts = 4;

    pub fn run(gpa: std.mem.Allocator, seed: u64) !void {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const scenarios = std.enums.values(testing.Scenario);
        const scenario = scenarios[seed % scenarios.len];
        var prng: std.Random.DefaultPrng = .init(seed);
        const random = prng.random();

        const new_world = try world(&tmp, a, "new");
        try testing.prepareOld(new_world, scenario);
        try testing.runClean(new_world, try testing.planFor(new_world, scenario));
        const new = try new_world.snapshot();

        const w = try world(&tmp, a, "sim");
        try testing.prepareOld(w, scenario);
        const old = try w.snapshot();
        const the_plan = try testing.planFor(w, scenario);
        var v: platform.Virtual = .init(w.io, w.system);
        v.faults = .init(seed, faultOptions(random, 6));
        attempt(w, &v, the_plan) catch |err| if (!isFault(err)) return err;

        for (0..restarts) |round| {
            var restarted: platform.Virtual = .init(w.io, w.system);
            restarted.faults = .init(seed +% round +% 1, faultOptions(random, 3));
            const recovered = transaction.recover(w.io, a, restarted.platform(), w.root, .{});
            if (recovered) |_| break else |err| if (!isFault(err)) return err;
        }
        var clean: platform.Virtual = .init(w.io, w.system);
        _ = try transaction.recover(w.io, a, clean.platform(), w.root, .{});
        const after = try w.snapshot();
        if (!std.mem.eql(
            u8,
            after,
            old,
        ) and !std.mem.eql(u8, after, new)) return error.SimMixedState;
    }

    fn world(tmp: *std.testing.TmpDir, a: std.mem.Allocator, sub: []const u8) !testing.World {
        try tmp.dir.createDirPath(std.testing.io, sub);
        return .init(std.testing.io, a, try tmp.dir.realPathFileAlloc(std.testing.io, sub, a));
    }

    fn faultOptions(random: std.Random, max_faults: u16) platform.fault.Options {
        return .{
            .fault_per_mille = 80,
            .max_faults = max_faults,
            .kill_at = if (random.boolean()) random.uintLessThan(u32, 60) else null,
        };
    }

    fn attempt(w: testing.World, v: *platform.Virtual, the_plan: anytype) !void {
        var t = try transaction.Transaction.begin(w.io, w.arena, v.platform(), the_plan, .{});
        try t.runAll();
    }

    fn isFault(err: anyerror) bool {
        return switch (err) {
            error.PlatformKilled,
            error.JournalPoisoned,
            error.FsNoSpace,
            error.FsAccessDenied,
            error.FsSharingViolation,
            error.FsIo,
            => true,
            else => false,
        };
    }
};
