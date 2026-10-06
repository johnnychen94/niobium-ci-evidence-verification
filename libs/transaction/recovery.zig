//! RecoverIncompleteTransaction: runs first on every start, under the transaction lock.
//!
//! | last record                | action                                         |
//! |----------------------------|------------------------------------------------|
//! | none / begin / op_done     | roll back every pre-commit op (idempotent)      |
//! | ready_to_commit            | same, including the commit op                  |
//! | commit / bootstrap_*       | re-run every post-commit op, then finalize      |
//! | finalized / rolled_back    | delete the journal files                       |

const std = @import("std");
const contracts = @import("contracts");
const platform = @import("platform");
const executor = @import("executor");
const planner = @import("planner");
const root = @import("root.zig");

const journal = contracts.journal;

pub const Outcome = enum {
    clean,
    rolled_back,
    rolled_forward,
    /// Rolled forward, but the app bootstrap never reported success; installation.json says
    /// `bootstrap: pending` and the engine retries it.
    bootstrap_pending,
};

pub const Recovered = struct {
    outcome: Outcome = .clean,
    tx_seq: ?u64 = null,
    kind: ?journal.TxKind = null,
};

pub fn recover(
    io: std.Io,
    arena: std.mem.Allocator,
    p: platform.Platform,
    install_root: []const u8,
    limits: contracts.Limits,
) root.Error!Recovered {
    const dir_path = try std.fs.path.join(arena, &.{ install_root, "journal" });
    var dir = std.Io.Dir.cwd().openDir(
        io,
        dir_path,
        .{ .iterate = true },
    ) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return platform.api.mapFs(err),
    };
    defer dir.close(io);
    var seqs: std.ArrayList(u64) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch |err| return platform.api.mapFs(err)) |entry| {
        if (seqs.items.len >= max_journals) return error.JournalBadRecord;
        const seq = parseName(entry.name) orelse continue;
        if (std.mem.findScalar(u64, seqs.items, seq) == null) try seqs.append(arena, seq);
    }
    std.mem.sortUnstable(u64, seqs.items, {}, std.sort.asc(u64));
    var result: Recovered = .{};
    for (seqs.items) |seq| {
        const one = try recoverOne(io, arena, p, install_root, seq, limits);
        if (one.outcome != .clean) result = one;
    }
    return result;
}

/// Normally there is at most one; more means something outside the installer wrote here.
const max_journals = 64;

/// `tx-<n>.jsonl` or an orphaned `tx-<n>.plan.json` (crash before `begin`).
fn parseName(name: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, name, "tx-")) return null;
    const rest = name[3..];
    const end = std.mem.findScalar(u8, rest, '.') orelse return null;
    const suffix = rest[end..];
    if (!std.mem.eql(u8, suffix, ".jsonl") and !std.mem.eql(u8, suffix, ".plan.json")) return null;
    return std.fmt.parseInt(u64, rest[0..end], 10) catch null;
}

const State = struct {
    records: []const journal.Record,
    begun: bool = false,
    committed: bool = false,
    terminal: bool = false,
    bootstrap_done: bool = false,
};

fn readJournal(
    io: std.Io,
    arena: std.mem.Allocator,
    p: platform.Platform,
    path: []const u8,
    limits: contracts.Limits,
) root.Error!State {
    const max = @as(u64, limits.journal_records) * limits.journal_record_bytes;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        arena,
        .limited64(max),
    ) catch |err| switch (err) {
        error.FileNotFound => return .{ .records = &.{} },
        else => return platform.api.mapFs(err),
    };
    const valid = if (std.mem.findScalarLast(u8, bytes, '\n')) |end| end + 1 else 0;
    // A torn tail would merge with the next appended record; cut it before appending again.
    if (valid < bytes.len) try p.writeFile(path, bytes[0..valid], false);
    var state: State = .{
        .records = try journal.parseAll(arena, bytes[0..valid], limits.journal_records),
    };
    for (state.records) |rec| switch (rec) {
        .begin => state.begun = true,
        .commit => state.committed = true,
        .finalized, .rolled_back => state.terminal = true,
        .bootstrap_done => state.bootstrap_done = true,
        else => {},
    };
    return state;
}

fn recoverOne(
    io: std.Io,
    arena: std.mem.Allocator,
    p: platform.Platform,
    install_root: []const u8,
    seq: u64,
    limits: contracts.Limits,
) root.Error!Recovered {
    const files = try root.Files.of(arena, install_root, seq);
    const state = try readJournal(io, arena, p, files.journal, limits);
    if (!state.begun or state.terminal) {
        try deleteFiles(p, files);
        return .{};
    }
    const plan_bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        files.plan,
        arena,
        .limited(16 << 20),
    ) catch |err|
        return platform.api.mapFs(err);
    const the_plan = contracts.plan.decode(
        arena,
        plan_bytes,
    ) catch return error.JournalPlanMismatch;
    try planner.check(the_plan);
    const begin = state.records[0];
    if (begin != .begin or begin.begin.seq != seq or the_plan.tx_seq != seq or
        !std.mem.eql(u8, the_plan.root, install_root)) return error.JournalPlanMismatch;
    var t: root.Transaction = .{
        .io = io,
        .arena = arena,
        .platform = p,
        .exec = .init(io, arena, p, the_plan),
        .files = files,
        .limits = limits,
    };
    if (!state.committed) return rollBack(&t, seq);
    t.committed = true;
    try root.runStage(&t, .post_commit);
    try t.finalize();
    const wants_bootstrap = if (the_plan.state) |s| s.bootstrap == .pending else false;
    const pending = wants_bootstrap and !state.bootstrap_done;
    return .{
        .outcome = if (pending) .bootstrap_pending else .rolled_forward,
        .tx_seq = seq,
        .kind = the_plan.kind,
    };
}

fn rollBack(t: *root.Transaction, seq: u64) root.Error!Recovered {
    const commit_index = t.exec.plan.commitIndex() orelse return error.PlanInvalid;
    var index = commit_index + 1;
    while (index > 0) {
        index -= 1;
        try t.exec.rollback(t.exec.plan.ops[index]);
        try t.record(.{ .op_undone = try root.opIndex(index) });
    }
    try t.record(.rolled_back);
    if (std.mem.startsWith(u8, t.exec.plan.staging, t.exec.plan.root)) {
        try t.platform.deleteTree(t.exec.plan.staging);
    }
    try deleteFiles(t.platform, t.files);
    return .{ .outcome = .rolled_back, .tx_seq = seq, .kind = t.exec.plan.kind };
}

/// Journal first: an orphaned plan is harmless (treated as "never began"), an orphaned journal
/// is not.
fn deleteFiles(p: platform.Platform, files: root.Files) root.Error!void {
    try p.deleteFile(files.journal);
    try p.deleteFile(files.plan);
}

test "journal file names" {
    try std.testing.expectEqual(@as(?u64, 12), parseName("tx-12.jsonl"));
    try std.testing.expectEqual(@as(?u64, 3), parseName("tx-3.plan.json"));
    try std.testing.expectEqual(@as(?u64, null), parseName("tx-3.json"));
    try std.testing.expectEqual(@as(?u64, null), parseName("lock"));
    try std.testing.expectEqual(@as(?u64, null), parseName("tx-x.jsonl"));
}
