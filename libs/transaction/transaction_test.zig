const std = @import("std");
const contracts = @import("contracts");
const platform = @import("platform");
const planner = @import("planner");
const transaction = @import("root.zig");
const testing = @import("testing.zig");

const Scenario = testing.Scenario;
const prepareOld = testing.prepareOld;
const planFor = testing.planFor;
const runClean = testing.runClean;

const max_kill_points = 400; // upper bound on mutations per scenario

fn baseDir(tmp: *std.testing.TmpDir, arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, name);
    return tmp.dir.realPathFileAlloc(io, name, arena);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.find(u8, haystack, needle) == null) {
        std.log.err("missing '{s}' in:\n{s}", .{ needle, haystack });
        return error.TestUnexpectedResult;
    }
}

test "N1-AC-06 install, update and uninstall commit cleanly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w: testing.World = try .init(std.testing.io, a, try baseDir(&tmp, a, "w"));
    try prepareOld(w, .update);
    const installed = try w.snapshot();
    try expectContains(installed, "root/current -> versions/1");
    try expectContains(installed, "root/versions/1/runtime/bin/hello = hello 1.0.0");
    const maintainer = if (@import("builtin").os.tag == .windows)
        "root/maintainer/setup.exe = setup"
    else
        "root/maintainer/setup = setup";
    try expectContains(installed, maintainer);
    try expectContains(installed, "system/shortcut/Hello = com.example.hello");
    try runClean(w, try planFor(w, .update));
    const updated = try w.snapshot();
    try expectContains(updated, "root/current -> versions/2");
    try expectContains(updated, "root/versions/2/runtime/bin/hello = hello 2.0.0");
    try std.testing.expect(std.mem.find(u8, updated, "versions/1") == null);
    try std.testing.expect(std.mem.find(u8, updated, "root/journal/") == null);
    try std.testing.expectEqual(@as(u64, 2), (try w.current()).?.active_tx);
    try std.testing.expectEqual(@as(usize, 3), (try w.current()).?.integrations.len);
    try runClean(w, try planFor(w, .uninstall));
    try std.testing.expectEqualStrings("", try w.snapshot());
}

fn newSnapshot(tmp: *std.testing.TmpDir, a: std.mem.Allocator, scenario: Scenario) ![]const u8 {
    const w: testing.World = try .init(std.testing.io, a, try baseDir(tmp, a, @tagName(scenario)));
    try prepareOld(w, scenario);
    try runClean(w, try planFor(w, scenario));
    return w.snapshot();
}

const Landed = enum { completed, old, new };

/// Kill at mutation `k`, recover on a fresh platform, and report where Active landed.
fn killAt(
    tmp: *std.testing.TmpDir,
    scenario: Scenario,
    k: u32,
    new: []const u8,
) !Landed {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const name = try a.print("{t}-{d}", .{ scenario, k });
    const w: testing.World = try .init(std.testing.io, a, try baseDir(tmp, a, name));
    try prepareOld(w, scenario);
    const old = try w.snapshot();
    const the_plan = try planFor(w, scenario);
    var v: platform.Virtual = .init(w.io, w.system);
    v.faults = .init(k, .{ .fault_per_mille = 0, .kill_at = k });
    run: {
        var t = transaction.Transaction.begin(w.io, a, v.platform(), the_plan, .{}) catch |err| {
            if (err != error.PlatformKilled) return err;
            break :run;
        };
        t.runAll() catch |err| if (err != error.PlatformKilled) return err;
    }
    if (!v.dead) {
        try std.testing.expectEqualStrings(new, try w.snapshot());
        return .completed;
    }
    var fresh: platform.Virtual = .init(w.io, w.system);
    const first = try transaction.recover(w.io, a, fresh.platform(), w.root, .{});
    if (first.kind) |kind| try std.testing.expectEqual(the_plan.kind, kind);
    const after = try w.snapshot();
    if (!std.mem.eql(u8, after, old) and !std.mem.eql(u8, after, new)) {
        std.log.err("{t} kill at {d}: MIXED state\n{s}", .{ scenario, k, after });
        return error.TestMixedState;
    }
    const again = try transaction.recover(w.io, a, fresh.platform(), w.root, .{});
    try std.testing.expectEqual(transaction.Outcome.clean, again.outcome);
    return if (std.mem.eql(u8, after, old)) .old else .new;
}

test "N1-INV-01 kill after every mutation: Active is OLD or NEW, never MIXED" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for (std.enums.values(Scenario)) |scenario| {
        const new = try newSnapshot(&tmp, arena.allocator(), scenario);
        var landed: [3]u32 = @splat(0);
        var k: u32 = 0;
        while (k < max_kill_points) : (k += 1) {
            const where = try killAt(&tmp, scenario, k, new);
            landed[@backingInt(where)] += 1;
            if (where == .completed) break;
        }
        try std.testing.expect(k < max_kill_points);
        try std.testing.expect(landed[@backingInt(Landed.old)] > 0);
        try std.testing.expect(landed[@backingInt(Landed.new)] > 0);
    }
}

test "a failing op before commit rolls back to OLD with no journal left" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w: testing.World = try .init(std.testing.io, a, try baseDir(&tmp, a, "fail"));
    try prepareOld(w, .update);
    const old = try w.snapshot();
    var the_plan = try planFor(w, .update);
    var broken = try a.dupe(contracts.plan.Op, the_plan.ops);
    broken[0] = .{ .place_maintainer = .{ .source = "/nonexistent/setup", .tx = 2 } };
    the_plan.ops = broken;
    var v: platform.Virtual = .init(w.io, w.system);
    var t = try transaction.Transaction.begin(w.io, a, v.platform(), the_plan, .{});
    try std.testing.expectError(error.FsNotFound, t.runAll());
    try std.testing.expectEqualStrings(old, try w.snapshot());
}

test "the transaction lock is exclusive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fs.path.join(a, &.{ try baseDir(&tmp, a, "lock"), "journal", "lock" });
    const first = try transaction.Lock.acquire(std.testing.io, path);
    try std.testing.expectError(
        error.TransactionBusy,
        transaction.Lock.acquire(std.testing.io, path),
    );
    first.release(std.testing.io);
    const second = try transaction.Lock.acquire(std.testing.io, path);
    second.release(std.testing.io);
}
