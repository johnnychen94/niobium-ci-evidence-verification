//! Typed InstallationPlan wire form. Written to `journal/tx-<n>.plan.json` before the first op,
//! so RecoverIncompleteTransaction can roll back or roll forward after a crash.
//! Execute-stage ops write only under `versions/<tx>/`, `maintainer/` temp names and versioned
//! integration temp files; `swap_current` (or `remove_current`) is the single commit point.

const std = @import("std");
const json = @import("json.zig");
const ids = @import("ids.zig");
const journal = @import("journal.zig");
const installation = @import("installation.zig");
const manifest = @import("manifest.zig");

pub const schema_version = 1;

pub const Stage = enum { execute, commit, post_commit, finalize };

pub const Integration = struct {
    kind: installation.IntegrationKind,
    /// Stable id (shortcut name, extension, service id).
    id: []const u8,
    /// Display name or description.
    label: []const u8,
    /// Executable path relative to `current/` (`<component>/<entrypoint path>`); for
    /// `registration` it is the maintainer executable relative to the install root.
    /// Uses forward slashes on every OS; the platform backend renders native separators.
    target: []const u8,
    start: ?manifest.ServiceStart = null,
    /// Machine scope integrations go through the privilege helper.
    privileged: bool = false,
};

pub const Release = struct { tx: u64 };

pub const Swap = struct {
    tx: u64,
    /// Active `versions/<n>` before commit; null on first install.
    previous: ?u64 = null,
};

pub const Maintainer = struct {
    /// Absolute path of the running setup binary copied into `maintainer/`.
    source: []const u8,
    tx: u64,
};

pub const Empty = struct {};

pub const Op = union(enum) {
    place_release: Release,
    place_maintainer: Maintainer,
    prepare_integration: Integration,
    swap_current: Swap,
    activate_integration: Integration,
    remove_integration: installation.Integration,
    activate_maintainer: Release,
    write_state: Empty,
    remove_current: Release,
    remove_release: Release,
    remove_root: Empty,

    pub fn stage(op: Op) Stage {
        return switch (op) {
            .place_release, .place_maintainer, .prepare_integration => .execute,
            .swap_current, .remove_current => .commit,
            .activate_integration,
            .remove_integration,
            .activate_maintainer,
            .write_state,
            => .post_commit,
            .remove_release, .remove_root => .finalize,
        };
    }
};

pub const Plan = struct {
    schema: u32 = schema_version,
    tx_id: []const u8,
    tx_seq: u64,
    kind: journal.TxKind,
    scope: ids.Scope,
    /// Absolute install root.
    root: []const u8,
    /// Absolute directory holding the extracted release (`<staging>/<component>/…`). Inside the
    /// root for user scope; a user-writable directory for machine scope (the helper copies).
    staging: []const u8,
    ops: []const Op,
    /// State written by `write_state`; null for uninstall. Integration locations are filled in
    /// by the executor from the platform's activate results.
    state: ?installation.Installation = null,

    /// Index of the commit op; every plan has exactly one.
    pub fn commitIndex(plan: Plan) ?usize {
        for (plan.ops, 0..) |op, index| {
            if (op.stage() == .commit) return index;
        }
        return null;
    }
};

pub fn encode(arena: std.mem.Allocator, plan: Plan) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(arena, plan, .{ .emit_null_optional_fields = false });
}

pub fn decode(arena: std.mem.Allocator, bytes: []const u8) json.DecodeError!Plan {
    return json.decode(
        Plan,
        arena,
        bytes,
        .{ .max_bytes = 16 << 20, .max_schema = schema_version },
    );
}

test "plan round trips through JSON and has one commit point" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const shortcut: Integration = .{
        .kind = .shortcut,
        .id = "Hello",
        .label = "Hello",
        .target = "runtime/bin/hello",
    };
    const plan: Plan = .{
        .tx_id = "tx-2-00",
        .tx_seq = 2,
        .kind = .update,
        .scope = .user,
        .root = "/r",
        .staging = "/r/staging/tx-2",
        .ops = &.{
            .{ .place_release = .{ .tx = 2 } },
            .{ .prepare_integration = shortcut },
            .{ .swap_current = .{ .tx = 2, .previous = 1 } },
            .{ .activate_integration = shortcut },
            .{ .write_state = .{} },
            .{ .remove_release = .{ .tx = 1 } },
        },
    };
    const bytes = try encode(arena.allocator(), plan);
    const back = try decode(arena.allocator(), bytes);
    try std.testing.expectEqual(@as(usize, 6), back.ops.len);
    try std.testing.expectEqual(@as(?usize, 2), back.commitIndex());
    try std.testing.expectEqualStrings(
        "runtime/bin/hello",
        back.ops[3].activate_integration.target,
    );
}
