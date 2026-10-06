//! Desired-state planner: current state + desired release -> typed InstallationPlan
//! (contracts.plan). Pure and deterministic; the transaction module executes the plan.
//! Every plan has stages in order execute -> commit -> post_commit -> finalize and exactly one
//! commit op (docs/architecture/transaction-model.md).

const std = @import("std");
const contracts = @import("contracts");
const manifest = @import("manifest");

pub const paths = @import("paths.zig");

const plan = contracts.plan;
const Installation = contracts.installation.Installation;

pub const Error = manifest.Error || error{
    NotInstalled,
    PlanAlreadyInstalled,
    PlanProductMismatch,
    PlanScopeChange,
    PlanMissingComponent,
    PlanDuplicateIntegration,
    PlanTooLarge,
    PlanInvalid,
};

pub const Desired = struct {
    manifest: manifest.Manifest,
    manifest_sha256: []const u8,
    /// Metadata of every selected component (from the staged artifacts).
    metas: []const manifest.ComponentMeta,
    channel: contracts.Channel,
    scope: contracts.Scope,
    installer_version: []const u8,
};

pub const Context = struct {
    tx_seq: u64,
    tx_id: []const u8,
    root: []const u8,
    staging: []const u8,
    os: paths.Os,
    support: paths.Support,
    current: ?Installation = null,
    /// Absolute path of the running setup; null skips the maintainer copy (library embedding).
    maintainer_source: ?[]const u8 = null,
    limits: contracts.Limits = .{},
};

pub fn install(arena: std.mem.Allocator, ctx: Context, desired: Desired) Error!plan.Plan {
    if (ctx.current != null) return error.PlanAlreadyInstalled;
    return replace(arena, .install, ctx, desired);
}

/// Update and repair have the same shape: a new `versions/<tx>` replaces the active one.
pub fn update(
    arena: std.mem.Allocator,
    kind: contracts.journal.TxKind,
    ctx: Context,
    desired: Desired,
) Error!plan.Plan {
    std.debug.assert(kind == .update or kind == .repair);
    const current = ctx.current orelse return error.NotInstalled;
    if (!std.mem.eql(u8, current.product_id, desired.manifest.product.id)) {
        return error.PlanProductMismatch;
    }
    if (current.scope != desired.scope) return error.PlanScopeChange;
    return replace(arena, kind, ctx, desired);
}

pub fn uninstall(arena: std.mem.Allocator, ctx: Context) Error!plan.Plan {
    const current = ctx.current orelse return error.NotInstalled;
    var ops: std.ArrayList(plan.Op) = .empty;
    try ops.append(arena, .{ .remove_current = .{ .tx = current.active_tx } });
    for (current.integrations) |integration| {
        try ops.append(arena, .{ .remove_integration = integration });
    }
    try ops.append(arena, .{ .remove_release = .{ .tx = current.active_tx } });
    try ops.append(arena, .{ .remove_root = .{} });
    return finish(ctx, .uninstall, current.scope, ops.items, null);
}

fn replace(
    arena: std.mem.Allocator,
    kind: contracts.journal.TxKind,
    ctx: Context,
    desired: Desired,
) Error!plan.Plan {
    try manifest.validate.entrypoints(desired.manifest, desired.metas);
    const integrations = try desiredIntegrations(arena, ctx, desired);
    const previous: ?u64 = if (ctx.current) |current| current.active_tx else null;
    var ops: std.ArrayList(plan.Op) = .empty;
    try ops.append(arena, .{ .place_release = .{ .tx = ctx.tx_seq } });
    if (ctx.maintainer_source) |source| {
        try ops.append(arena, .{ .place_maintainer = .{ .source = source, .tx = ctx.tx_seq } });
    }
    for (integrations) |integration| try ops.append(arena, .{ .prepare_integration = integration });
    try ops.append(arena, .{ .swap_current = .{ .tx = ctx.tx_seq, .previous = previous } });
    if (ctx.current) |current| {
        for (current.integrations) |installed| {
            if (!contains(integrations, installed)) {
                try ops.append(arena, .{ .remove_integration = installed });
            }
        }
    }
    for (integrations) |integration| try ops.append(
        arena,
        .{ .activate_integration = integration },
    );
    if (ctx.maintainer_source != null) {
        try ops.append(arena, .{ .activate_maintainer = .{ .tx = ctx.tx_seq } });
    }
    try ops.append(arena, .{ .write_state = .{} });
    if (previous) |tx| try ops.append(arena, .{ .remove_release = .{ .tx = tx } });
    const state = try desiredState(arena, ctx, desired);
    return finish(ctx, kind, desired.scope, ops.items, state);
}

fn finish(
    ctx: Context,
    kind: contracts.journal.TxKind,
    scope: contracts.Scope,
    ops: []const plan.Op,
    state: ?Installation,
) Error!plan.Plan {
    if (ops.len > ctx.limits.plan_ops) return error.PlanTooLarge;
    const result: plan.Plan = .{
        .tx_id = ctx.tx_id,
        .tx_seq = ctx.tx_seq,
        .kind = kind,
        .scope = scope,
        .root = ctx.root,
        .staging = ctx.staging,
        .ops = ops,
        .state = state,
    };
    try check(result);
    return result;
}

fn contains(list: []const plan.Integration, installed: contracts.installation.Integration) bool {
    for (list) |item| {
        if (item.kind == installed.kind and std.mem.eql(u8, item.id, installed.id)) return true;
    }
    return false;
}

fn entryTarget(
    arena: std.mem.Allocator,
    metas: []const manifest.ComponentMeta,
    ref: []const u8,
) Error![]const u8 {
    const parsed = contracts.ids.parseEntrypointRef(
        ref,
    ) orelse return error.ManifestInvalidEntrypoint;
    const entry = try manifest.validate.resolveEntrypoint(metas, ref);
    return arena.print("{s}/{s}", .{ parsed.component, entry.path });
}

fn desiredIntegrations(
    arena: std.mem.Allocator,
    ctx: Context,
    desired: Desired,
) Error![]const plan.Integration {
    const machine = desired.scope == .machine;
    const declared = desired.manifest.integrations;
    var out: std.ArrayList(plan.Integration) = .empty;
    if (ctx.support.shortcuts) for (declared.shortcuts) |s| {
        try out.append(arena, .{
            .kind = .shortcut,
            .id = s.name,
            .label = s.name,
            .target = try entryTarget(arena, desired.metas, s.entrypoint),
            .privileged = machine,
        });
    };
    if (ctx.support.file_associations) for (declared.file_associations) |assoc| {
        try out.append(arena, .{
            .kind = .file_association,
            .id = assoc.extension,
            .label = assoc.description,
            .target = try entryTarget(arena, desired.metas, assoc.entrypoint),
            .privileged = machine,
        });
    };
    if (ctx.support.services) for (declared.services) |service| {
        try out.append(arena, .{
            .kind = .service,
            .id = service.id,
            .label = service.id,
            .target = try entryTarget(arena, desired.metas, service.entrypoint),
            .start = service.start,
            .privileged = machine,
        });
    };
    if (ctx.support.registration and ctx.maintainer_source != null) {
        try out.append(arena, .{
            .kind = .registration,
            .id = desired.manifest.product.id,
            .label = desired.manifest.product.name,
            .target = paths.maintainerPath(ctx.os),
            .privileged = machine,
        });
    }
    try unique(out.items);
    return out.items;
}

fn unique(list: []const plan.Integration) Error!void {
    for (list, 0..) |a, i| {
        for (list[i + 1 ..]) |b| {
            if (a.kind == b.kind and std.ascii.eqlIgnoreCase(a.id, b.id)) {
                return error.PlanDuplicateIntegration;
            }
        }
    }
}

fn desiredState(arena: std.mem.Allocator, ctx: Context, desired: Desired) Error!Installation {
    const m = desired.manifest;
    const components = try arena.alloc([]const u8, desired.metas.len);
    for (components, desired.metas) |*id, meta| id.* = meta.id;
    for (m.components) |component| {
        if (component.required and !has(
            components,
            component.id,
        )) return error.PlanMissingComponent;
    }
    return .{
        .product_id = m.product.id,
        .product_name = m.product.name,
        .scope = desired.scope,
        .channel = desired.channel,
        .release_sequence = m.product.release_sequence,
        .app_version = m.product.version,
        .active_tx = ctx.tx_seq,
        .installer_version = desired.installer_version,
        .components = components,
        .manifest_sha256 = desired.manifest_sha256,
        .bootstrap = if (m.bootstrap != null) .pending else .none,
        .bootstrap_target = if (m.bootstrap) |b|
            try entryTarget(arena, desired.metas, b.entrypoint)
        else
            null,
    };
}

fn has(list: []const []const u8, id: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, id)) return true;
    }
    return false;
}

/// Structural invariants every plan satisfies; the transaction module re-checks after decode.
pub fn check(p: plan.Plan) error{PlanInvalid}!void {
    var commits: usize = 0;
    var stage: plan.Stage = .execute;
    for (p.ops) |op| {
        const next = op.stage();
        if (@backingInt(next) < @backingInt(stage)) return error.PlanInvalid;
        stage = next;
        if (next == .commit) commits += 1;
    }
    if (commits != 1) return error.PlanInvalid;
    if ((p.kind == .uninstall) != (p.state == null)) return error.PlanInvalid;
}

test {
    _ = paths;
    _ = @import("planner_test.zig");
}
