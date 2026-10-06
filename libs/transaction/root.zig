//! Journaled transactions over a typed plan (docs/architecture/transaction-model.md):
//! begin -> execute ops -> ready_to_commit -> commit op -> commit -> post-commit ops ->
//! [bootstrap] -> finalize. `recover` runs first on every start: before `commit` it rolls back,
//! after `commit` it rolls forward. Active is OLD or NEW at every kill point (N1-INV-01).

const std = @import("std");
const contracts = @import("contracts");
const platform = @import("platform");
const executor = @import("executor");
const planner = @import("planner");

pub const recovery = @import("recovery.zig");
pub const recover = recovery.recover;
pub const testing = @import("testing.zig");
pub const Outcome = recovery.Outcome;

const plan = contracts.plan;
const journal = contracts.journal;

pub const Error = executor.Error || journal.ParseError || error{
    TransactionBusy,
    JournalPoisoned,
    JournalPlanMismatch,
    PlanInvalid,
};

/// Single-transaction lock: an advisory exclusive file lock, released when the process exits.
pub const Lock = struct {
    file: std.Io.File,

    pub fn acquire(io: std.Io, path: []const u8) Error!Lock {
        if (std.fs.path.dirname(path)) |dir| {
            std.Io.Dir.cwd().createDirPath(io, dir) catch |err| return platform.api.mapFs(err);
        }
        const file = std.Io.Dir.cwd().createFile(io, path, .{
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch |err| return switch (err) {
            error.WouldBlock => error.TransactionBusy,
            else => platform.api.mapFs(err),
        };
        return .{ .file = file };
    }

    pub fn release(lock: Lock, io: std.Io) void {
        lock.file.close(io);
    }
};

pub const Files = struct {
    journal: []const u8,
    plan: []const u8,

    pub fn of(arena: std.mem.Allocator, root: []const u8, seq: u64) error{OutOfMemory}!Files {
        return .{
            .journal = try std.fs.path.join(
                arena,
                &.{ root, "journal", try arena.print("tx-{d}.jsonl", .{seq}) },
            ),
            .plan = try std.fs.path.join(
                arena,
                &.{ root, "journal", try arena.print("tx-{d}.plan.json", .{seq}) },
            ),
        };
    }
};

pub const Transaction = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    platform: platform.Platform,
    exec: executor.Executor,
    files: Files,
    limits: contracts.Limits,
    /// Set after a failed append; nothing more is appended in this process.
    poisoned: bool = false,
    committed: bool = false,

    pub fn begin(
        io: std.Io,
        arena: std.mem.Allocator,
        p: platform.Platform,
        the_plan: plan.Plan,
        limits: contracts.Limits,
    ) Error!Transaction {
        try planner.check(the_plan);
        var t: Transaction = .{
            .io = io,
            .arena = arena,
            .platform = p,
            .exec = .init(io, arena, p, the_plan),
            .files = try .of(arena, the_plan.root, the_plan.tx_seq),
            .limits = limits,
        };
        try p.createDirPath(try std.fs.path.join(arena, &.{ the_plan.root, "journal" }));
        try p.writeFile(t.files.plan, try plan.encode(arena, the_plan), false);
        try t.record(.{ .begin = .{
            .tx = the_plan.tx_id,
            .seq = the_plan.tx_seq,
            .kind = the_plan.kind,
            .from = previousOf(the_plan),
        } });
        return t;
    }

    fn ops(t: *const Transaction) []const plan.Op {
        return t.exec.plan.ops;
    }

    pub fn record(t: *Transaction, rec: journal.Record) Error!void {
        if (t.poisoned) return error.JournalPoisoned;
        var buffer: [1024]u8 = undefined; // SAFETY: fixed writer scratch.
        var writer: std.Io.Writer = .fixed(&buffer);
        journal.write(&writer, rec) catch return error.JournalBadRecord;
        t.platform.appendFile(t.files.journal, writer.buffered()) catch |err| {
            t.poisoned = true;
            return err;
        };
    }

    /// Execute ops, then the commit op. Any failure rolls everything back before returning it.
    pub fn commit(t: *Transaction) Error!void {
        const commit_index = t.exec.plan.commitIndex() orelse return error.PlanInvalid;
        for (t.ops()[0..commit_index], 0..) |op, index| {
            t.exec.apply(op) catch |err| return t.abort(index + 1, err);
            t.record(.{ .op_done = try opIndex(index) }) catch |err| return t.abort(index + 1, err);
        }
        t.record(.ready_to_commit) catch |err| return t.abort(commit_index, err);
        t.exec.apply(t.ops()[commit_index]) catch |err| return t.abort(commit_index + 1, err);
        t.record(.commit) catch |err| return t.abort(commit_index + 1, err);
        t.committed = true;
    }

    /// Roll back the first `count` ops in reverse. Rollback is idempotent, so the op that failed
    /// half-way is included.
    fn abort(t: *Transaction, count: usize, cause: Error) Error {
        if (fatal(cause)) return cause;
        var clean = true;
        var index = count;
        while (index > 0) {
            index -= 1;
            t.exec.rollback(t.ops()[index]) catch |err| {
                if (fatal(err)) return err;
                clean = false;
                continue;
            };
            const undone: journal.Record = .{ .op_undone = opIndex(index) catch 0 };
            t.record(undone) catch |err| if (fatal(err)) return err;
        }
        if (clean) {
            t.record(.rolled_back) catch |err| if (fatal(err)) return err;
            t.cleanup() catch |err| if (fatal(err)) return err;
        }
        return cause;
    }

    pub fn postCommit(t: *Transaction) Error!void {
        std.debug.assert(t.committed);
        try runStage(t, .post_commit);
    }

    pub fn bootstrapStarted(t: *Transaction) Error!void {
        try t.record(.bootstrap_started);
    }

    pub fn bootstrapDone(t: *Transaction, ok: bool) Error!void {
        try t.record(.{ .bootstrap_done = ok });
    }

    /// Finalize ops, the `finalized` record, then the journal files are removed. Uninstall's
    /// `remove_root` deletes the journal itself, so nothing is recorded after it.
    pub fn finalize(t: *Transaction) Error!void {
        try runStage(t, .finalize);
        if (t.exec.plan.kind == .uninstall) return;
        try t.record(.finalized);
        try t.cleanup();
    }

    fn cleanup(t: *Transaction) Error!void {
        if (std.mem.startsWith(u8, t.exec.plan.staging, t.exec.plan.root)) {
            try t.platform.deleteTree(t.exec.plan.staging);
        }
        try t.platform.deleteFile(t.files.journal);
        try t.platform.deleteFile(t.files.plan);
    }

    /// Install, update, repair or uninstall without bootstrap.
    pub fn runAll(t: *Transaction) Error!void {
        try t.commit();
        try t.postCommit();
        try t.finalize();
    }
};

/// Apply every op of `stage` with bounded retries; these ops only roll forward.
/// The process (or the privileged helper doing its mutations) is gone: stop touching the
/// install root and leave the journal for recovery, which runs with a fresh platform.
pub fn fatal(err: Error) bool {
    return err == error.PlatformKilled or err == error.PrivilegeHelperLost;
}

pub fn runStage(t: *Transaction, stage: plan.Stage) Error!void {
    for (t.ops(), 0..) |op, index| {
        if (op.stage() != stage) continue;
        try applyWithRetry(&t.exec, op, t.limits.retry_attempts);
        if (stage == .finalize and op == .remove_root) return;
        try t.record(.{ .op_done = try opIndex(index) });
    }
}

pub fn applyWithRetry(exec: *executor.Executor, op: plan.Op, attempts: u8) Error!void {
    var left = @max(attempts, 1);
    // loop-bound: `left` strictly decreases on every retry.
    while (true) {
        exec.apply(op) catch |err| {
            left -= 1;
            switch (err) {
                error.FsSharingViolation, error.FsIo, error.FsAccessDenied, error.FsNoSpace => {
                    if (left > 0) continue;
                },
                else => {},
            }
            return err;
        };
        return;
    }
}

pub fn opIndex(index: usize) error{PlanInvalid}!u32 {
    return std.math.cast(u32, index) orelse error.PlanInvalid;
}

fn previousOf(p: plan.Plan) ?u64 {
    for (p.ops) |op| switch (op) {
        .swap_current => |s| return s.previous,
        .remove_current => |r| return r.tx,
        else => {},
    };
    return null;
}

test {
    _ = recovery;
    _ = @import("transaction_test.zig");
}
