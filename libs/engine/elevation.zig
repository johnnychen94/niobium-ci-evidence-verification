//! Where machine-scope mutations go. Only a plan for machine scope opens the elevator, and it is
//! closed when the transaction ends (docs/architecture/overview.md#process-model).

const std = @import("std");
const platform = @import("platform");
const privilege = @import("privilege");

pub const Error = privilege.elevate.Error || platform.Error;

/// What the helper may touch during one transaction.
pub const Grant = struct {
    tx_id: []const u8,
    managed_roots: []const []const u8,
    source_roots: []const []const u8,
};

pub const Elevator = union(enum) {
    /// Machine scope fails with PrivilegeUnavailable.
    unavailable,
    /// The caller is already privileged (or a test stands in for the helper): machine-scope
    /// mutations go to this platform without a helper process.
    direct: platform.Platform,
    /// `setup --priv-helper-v1` behind the OS elevation prompt.
    process: *Process,

    pub fn open(e: Elevator, arena: std.mem.Allocator, grant: Grant) Error!platform.Platform {
        return switch (e) {
            .unavailable => error.PrivilegeUnavailable,
            .direct => |p| p,
            .process => |p| p.open(arena, grant),
        };
    }

    pub fn close(e: Elevator) void {
        switch (e) {
            .unavailable, .direct => {},
            .process => |p| p.close(),
        }
    }
};

/// One helper process per transaction. Holds the stream buffers, so keep it off the stack of
/// short-lived frames (apps allocate it once).
pub const Process = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    self_exe: []const u8,
    method: privilege.elevate.Method = privilege.elevate.defaultMethod(),
    // SAFETY: written by elevate.spawn in `open` before any use.
    helper: privilege.elevate.Helper = undefined,
    broker: ?privilege.Broker = null,
    nonce: [privilege.Session.nonce_len]u8 = @splat('0'),
    tx: [64]u8 = @splat(0),

    fn open(p: *Process, arena: std.mem.Allocator, grant: Grant) Error!platform.Platform {
        std.debug.assert(p.broker == null);
        if (grant.tx_id.len > p.tx.len) return error.PrivilegeUnavailable;
        @memcpy(p.tx[0..grant.tx_id.len], grant.tx_id);
        const session: privilege.Session = .{
            .tx = p.tx[0..grant.tx_id.len],
            .nonce = privilege.Session.generate(p.io, &p.nonce),
        };
        try privilege.elevate.spawn(&p.helper, p.io, arena, p.method, p.self_exe, session);
        p.broker = p.helper.broker(p.gpa, session);
        p.broker.?.hello(grant.managed_roots, grant.source_roots) catch |err| {
            p.close();
            return err;
        };
        return p.broker.?.platform();
    }

    fn close(p: *Process) void {
        const b = if (p.broker) |*b| b else return;
        b.bye() catch |err| std.log.debug("privilege helper bye: {t}", .{err});
        p.helper.finish();
        b.deinit();
        p.broker = null;
    }
};
