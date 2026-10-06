//! Applies and rolls back single plan ops through the platform interface. Both directions are
//! idempotent: rolling back an op that never ran is a no-op, and re-applying a post-commit op
//! converges (docs/architecture/transaction-model.md#three-semantics-of-an-op). No process
//! spawning here.

const std = @import("std");
const contracts = @import("contracts");
const platform = @import("platform");

const plan = contracts.plan;

pub const Error = platform.Error || error{ ExecutorInvalidPlan, ExecutorStagingMissing };

pub const Executor = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    platform: platform.Platform,
    plan: plan.Plan,
    /// Locations returned by activate_integration, written into installation.json.
    locations: std.ArrayList(contracts.installation.Integration) = .empty,

    pub fn init(
        io: std.Io,
        arena: std.mem.Allocator,
        p: platform.Platform,
        the_plan: plan.Plan,
    ) Executor {
        return .{ .io = io, .arena = arena, .platform = p, .plan = the_plan };
    }

    fn path(e: *const Executor, parts: []const []const u8) Error![]const u8 {
        var all: std.ArrayList([]const u8) = .empty;
        try all.append(e.arena, e.plan.root);
        try all.appendSlice(e.arena, parts);
        return std.fs.path.join(e.arena, all.items);
    }

    fn release(e: *const Executor, tx: u64) Error![]const u8 {
        return e.path(&.{ "versions", try e.arena.print("{d}", .{tx}) });
    }

    fn maintainerTemp(e: *const Executor, tx: u64) Error![]const u8 {
        const name = try e.arena.print("setup-{d}{s}", .{ tx, exeSuffix() });
        return e.path(&.{ "maintainer", name });
    }

    fn integrationRequest(
        e: *const Executor,
        i: plan.Integration,
    ) Error!platform.api.IntegrationRequest {
        const state = e.plan.state orelse return error.ExecutorInvalidPlan;
        return .{
            .integration = i,
            .product_id = state.product_id,
            .product_name = state.product_name,
            .scope = e.plan.scope,
            .root = e.plan.root,
            .tx = e.plan.tx_seq,
        };
    }

    pub fn apply(e: *Executor, op: plan.Op) Error!void {
        switch (op) {
            .place_release => |r| try e.placeRelease(r.tx),
            .place_maintainer => |m| {
                try e.platform.createDirPath(try e.path(&.{"maintainer"}));
                try e.platform.copyFile(m.source, try e.maintainerTemp(m.tx), true);
            },
            .prepare_integration => |i| {
                const request = try e.integrationRequest(i);
                try e.platform.prepareIntegration(&request);
            },
            .swap_current => |s| try e.pointTo(s.tx),
            .remove_current => try e.platform.deletePointer(try e.path(&.{"current"})),
            .activate_integration => |i| {
                const request = try e.integrationRequest(i);
                const where = try e.platform.activateIntegration(e.arena, &request);
                try e.locations.append(e.arena, .{ .kind = i.kind, .id = i.id, .location = where });
            },
            .remove_integration => |installed| try e.platform.removeIntegration(installed),
            .activate_maintainer => |m| try e.activateMaintainer(m.tx),
            .write_state => try e.writeState(),
            .remove_release => |r| try e.platform.deleteTree(try e.release(r.tx)),
            .remove_root => try e.removeRoot(),
        }
    }

    /// Undo an execute- or commit-stage op. Post-commit and finalize ops only roll forward.
    pub fn rollback(e: *Executor, op: plan.Op) Error!void {
        switch (op) {
            .place_release => |r| try e.platform.deleteTree(try e.release(r.tx)),
            .place_maintainer => |m| try e.platform.deleteFile(try e.maintainerTemp(m.tx)),
            .prepare_integration => |i| {
                const request = try e.integrationRequest(i);
                try e.platform.discardIntegration(&request);
            },
            .swap_current => |s| if (s.previous) |previous| {
                try e.pointTo(previous);
            } else {
                try e.platform.deletePointer(try e.path(&.{"current"}));
            },
            .remove_current => |r| try e.pointTo(r.tx),
            .activate_integration,
            .remove_integration,
            .activate_maintainer,
            .write_state,
            .remove_release,
            .remove_root,
            => return error.ExecutorInvalidPlan,
        }
    }

    fn pointTo(e: *Executor, tx: u64) Error!void {
        const target = try std.fs.path.join(
            e.arena,
            &.{ "versions", try e.arena.print("{d}", .{tx}) },
        );
        try e.platform.setPointer(try e.path(&.{"current"}), target);
    }

    /// User scope stages inside the root and renames; machine scope copies file by file (the
    /// privilege helper has no rename across trust boundaries).
    fn placeRelease(e: *Executor, tx: u64) Error!void {
        const target = try e.release(tx);
        try e.platform.deleteTree(target);
        try e.platform.createDirPath(try e.path(&.{"versions"}));
        if (std.mem.startsWith(u8, e.plan.staging, e.plan.root)) {
            return e.platform.rename(e.plan.staging, target) catch |err| switch (err) {
                error.FsNotFound => error.ExecutorStagingMissing,
                else => err,
            };
        }
        try e.copyTree(e.plan.staging, target);
    }

    fn copyTree(e: *Executor, source: []const u8, target: []const u8) Error!void {
        var dir = std.Io.Dir.cwd().openDir(
            e.io,
            source,
            .{ .iterate = true },
        ) catch |err| switch (err) {
            error.FileNotFound => return error.ExecutorStagingMissing,
            else => return platform.api.mapFs(err),
        };
        defer dir.close(e.io);
        try e.platform.createDirPath(target);
        var walker = dir.walk(e.arena) catch |err| return platform.api.mapFs(err);
        defer walker.deinit();
        while (walker.next(e.io) catch |err| return platform.api.mapFs(err)) |entry| {
            const to = try std.fs.path.join(e.arena, &.{ target, entry.path });
            switch (entry.kind) {
                .directory => try e.platform.createDirPath(to),
                .file => {
                    const from = try std.fs.path.join(e.arena, &.{ source, entry.path });
                    const stat = dir.statFile(
                        e.io,
                        entry.path,
                        .{},
                    ) catch |err| return platform.api.mapFs(err);
                    try e.platform.copyFile(from, to, isExecutable(stat.permissions));
                },
                else => return error.ExecutorInvalidPlan,
            }
        }
    }

    fn activateMaintainer(e: *Executor, tx: u64) Error!void {
        const temp = try e.maintainerTemp(tx);
        std.Io.Dir.cwd().access(e.io, temp, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return platform.api.mapFs(err),
        };
        const final = try e.path(&.{ "maintainer", try e.arena.print("setup{s}", .{exeSuffix()}) });
        try e.platform.copyFile(temp, final, true);
        try e.platform.deleteFile(temp);
    }

    fn writeState(e: *Executor) Error!void {
        var state = e.plan.state orelse return error.ExecutorInvalidPlan;
        state.integrations = e.locations.items;
        const bytes = try contracts.installation.encode(e.arena, state);
        try e.platform.writeFile(try e.path(&.{"installation.json"}), bytes, false);
    }

    /// installation.json first (the product reads as uninstalled from here on), the journal last.
    fn removeRoot(e: *Executor) Error!void {
        try e.platform.deleteFile(try e.path(&.{"installation.json"}));
        try e.platform.deletePointer(try e.path(&.{"current"}));
        const trees = [_][]const u8{ "versions", "maintainer", "staging", "trust", "logs" };
        for (trees) |name| try e.platform.deleteTree(try e.path(&.{name}));
        try e.platform.deleteTree(try e.path(&.{"journal"}));
        try e.platform.deleteTree(e.plan.root);
    }
};

fn exeSuffix() []const u8 {
    return if (@import("builtin").os.tag == .windows) ".exe" else "";
}

fn isExecutable(permissions: std.Io.File.Permissions) bool {
    const Permissions = std.Io.File.Permissions;
    if (comptime !Permissions.has_executable_bit) return false;
    return permissions.toMode() & 0o111 != 0;
}

test {
    _ = @import("executor_test.zig");
}
