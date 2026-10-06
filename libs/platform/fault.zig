//! Seeded fault schedule for VirtualPlatform (VOPR-style). The same seed yields the same
//! sequence of faults for the same sequence of operations, so any failing seed replays exactly.

const std = @import("std");

pub const Op = enum(u8) {
    create_file,
    write,
    fsync,
    rename,
    remove,
    make_dir,
    symlink,
    read,
    http_get,
    spawn,
    clock,
};

pub const Fault = enum(u8) {
    none,
    no_space,
    access_denied,
    sharing_violation,
    partial_write,
    rename_failed,
    connection_reset,
    timeout,
    clock_skew,
    kill,
};

pub const Options = struct {
    /// Chance per operation (per mille) that a non-kill fault is injected.
    fault_per_mille: u16 = 30,
    /// Upper bound on injected faults per run, so every run can still finish.
    max_faults: u16 = 8,
    /// Kill the process before this operation index (null: never).
    kill_at: ?u32 = null,
};

pub const FaultPlan = struct {
    seed: u64,
    prng: std.Random.DefaultPrng,
    options: Options,
    op_index: u32 = 0,
    injected: u16 = 0,
    log: [log_capacity]Entry = @splat(.{}),
    log_len: u16 = 0,

    pub const log_capacity = 256;
    pub const Entry = struct { index: u32 = 0, op: Op = .read, fault: Fault = .none };

    pub fn init(seed: u64, options: Options) FaultPlan {
        return .{ .seed = seed, .prng = .init(seed), .options = options };
    }

    /// A plan that never injects anything (production-like VirtualPlatform runs).
    pub fn none() FaultPlan {
        return init(0, .{ .fault_per_mille = 0, .max_faults = 0 });
    }

    /// Decide the fault for the next operation. Deterministic for a given seed and op sequence.
    pub fn next(plan: *FaultPlan, op: Op) Fault {
        const index = plan.op_index;
        plan.op_index +|= 1;
        if (plan.options.kill_at) |kill_at| {
            if (index >= kill_at) return plan.record(index, op, .kill);
        }
        const roll = plan.prng.random().uintLessThan(u16, 1000);
        if (roll >= plan.options.fault_per_mille or plan.injected >= plan.options.max_faults) {
            return .none;
        }
        const candidates = faultsFor(op);
        if (candidates.len == 0) return .none;
        plan.injected += 1;
        const pick = candidates[plan.prng.random().uintLessThan(usize, candidates.len)];
        return plan.record(index, op, pick);
    }

    fn record(plan: *FaultPlan, index: u32, op: Op, fault: Fault) Fault {
        if (plan.log_len < log_capacity) {
            plan.log[plan.log_len] = .{ .index = index, .op = op, .fault = fault };
            plan.log_len += 1;
        }
        return fault;
    }

    pub fn injectedFaults(plan: *const FaultPlan) []const Entry {
        return plan.log[0..plan.log_len];
    }
};

fn faultsFor(op: Op) []const Fault {
    return switch (op) {
        .create_file, .make_dir, .symlink => &.{ .no_space, .access_denied },
        .write => &.{ .no_space, .partial_write, .access_denied },
        .fsync => &.{.no_space},
        .rename => &.{ .rename_failed, .sharing_violation, .access_denied },
        .remove => &.{ .sharing_violation, .access_denied },
        .read => &.{.access_denied},
        .http_get => &.{ .connection_reset, .timeout },
        .spawn => &.{ .timeout, .access_denied },
        .clock => &.{.clock_skew},
    };
}

test "same seed replays the same faults" {
    const ops = [_]Op{ .write, .rename, .http_get, .write, .fsync, .remove, .clock, .read };
    var first = FaultPlan.init(42, .{ .fault_per_mille = 400 });
    var second = FaultPlan.init(42, .{ .fault_per_mille = 400 });
    for (0..64) |round| {
        const op = ops[round % ops.len];
        try std.testing.expectEqual(first.next(op), second.next(op));
    }
    try std.testing.expect(first.injectedFaults().len > 0);
}

test "kill point fires at the configured op and stays fired" {
    var plan = FaultPlan.init(1, .{ .fault_per_mille = 0, .kill_at = 3 });
    try std.testing.expectEqual(Fault.none, plan.next(.write));
    try std.testing.expectEqual(Fault.none, plan.next(.write));
    try std.testing.expectEqual(Fault.none, plan.next(.write));
    try std.testing.expectEqual(Fault.kill, plan.next(.rename));
    try std.testing.expectEqual(Fault.kill, plan.next(.write));
}

test "fault budget is bounded" {
    var plan = FaultPlan.init(7, .{ .fault_per_mille = 1000, .max_faults = 3 });
    var count: u32 = 0;
    for (0..100) |_| {
        if (plan.next(.write) != .none) count += 1;
    }
    try std.testing.expectEqual(@as(u32, 3), count);
}
