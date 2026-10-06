//! Commit-stage steps: plan, journaled transaction, App Bootstrap, verification, trust state.
//! Every mutation of the install root goes through the scope's platform (the privilege broker for
//! machine scope); reads use the filesystem directly.

const std = @import("std");
const contracts = @import("contracts");
const platform = @import("platform");
const planner = @import("planner");
const transaction = @import("transaction");
const bootstrap = @import("bootstrap");
const root = @import("root.zig");
const steps = @import("steps.zig");

const Engine = root.Engine;
const Error = root.Error;
const Report = root.Report;
const BootstrapState = contracts.installation.BootstrapState;

fn outcomeOf(kind: root.Kind) root.Outcome {
    return switch (kind) {
        .install => .installed,
        .update => .updated,
        .repair => .repaired,
        .uninstall => .uninstalled,
    };
}

fn plan(e: *Engine) Error!contracts.plan.Plan {
    const o = e.options;
    const resolution = e.resolution.?;
    const scope = e.scope.?;
    const desired: planner.Desired = .{
        .manifest = resolution.manifest,
        .manifest_sha256 = try e.arena().dupe(u8, &resolution.manifest_sha256),
        .metas = e.metas,
        .channel = o.channel orelse if (e.current) |c| c.channel else .stable,
        .scope = scope,
        .installer_version = o.installer_version,
    };
    const ctx: planner.Context = .{
        .tx_seq = e.tx_seq,
        .tx_id = e.tx_id,
        .root = e.root,
        .staging = e.staging,
        .os = o.os,
        .support = .default(o.os, scope),
        .current = e.current,
        .maintainer_source = o.maintainer_source,
        .limits = o.limits,
    };
    return switch (e.kind) {
        .install => planner.install(e.arena(), ctx, desired),
        .update, .repair => planner.update(e.arena(), e.kind, ctx, desired),
        .uninstall => unreachable,
    };
}

pub fn commit(e: *Engine) Error!Report {
    if (e.kind == .uninstall) return uninstall(e);
    try e.expect(.staged);
    defer steps.discardStaging(e);
    e.sink().phase(.plan);
    const the_plan = try plan(e);
    const scope = e.scope.?;
    const roots = try e.arena().dupe([]const u8, &.{e.root});
    const sources = try e.arena().dupe([]const u8, &.{e.staging});
    const p = try e.mutator(scope, .{
        .tx_id = e.tx_id,
        .managed_roots = roots,
        .source_roots = sources,
    });
    defer e.releaseMutator(scope);
    e.sink().phase(.execute);
    var t = try transaction.Transaction.begin(
        e.options.io,
        e.arena(),
        p,
        the_plan,
        e.options.limits,
    );
    try t.commit();
    e.sink().phase(.commit);
    try t.postCommit();
    var report: Report = .{
        .outcome = outcomeOf(e.kind),
        .scope = scope,
        .root = e.root,
        .product_version = the_plan.state.?.app_version,
        .release_sequence = the_plan.state.?.release_sequence,
    };
    try activate(e, &t, p, the_plan.state.?, &report);
    e.sink().phase(.verify_install);
    try verifyInstall(e);
    try saveTrust(e, p);
    e.sink().phase(.finalize);
    try t.finalize();
    e.sink().phase(.complete);
    e.step = .done;
    e.report = report;
    return report;
}

/// Activate the App Bootstrap of the new release. Failure keeps the new release Active and leaves
/// `bootstrap: pending` for the next run (docs/spec/bootstrap-v1.md#semantics).
fn activate(
    e: *Engine,
    t: *transaction.Transaction,
    p: platform.Platform,
    state: contracts.installation.Installation,
    report: *Report,
) Error!void {
    const target = state.bootstrap_target orelse return;
    e.sink().phase(.bootstrap);
    try t.bootstrapStarted();
    const outcome = callBootstrap(e, target, .activate, state.app_version);
    if (outcome) |_| {
        try writeBootstrapState(e, p, .done);
        report.bootstrap = .done;
    } else |err| {
        report.bootstrap = .pending;
        report.bootstrap_error = @errorName(err);
    }
    try t.bootstrapDone(report.bootstrap == .done);
}

fn callBootstrap(
    e: *Engine,
    target: []const u8,
    operation: contracts.bootstrap.Operation,
    to_version: []const u8,
) bootstrap.Error!bootstrap.Result {
    const o = e.options;
    const exe = try std.fs.path.join(e.arena(), &.{ e.root, "current", target });
    return bootstrap.run(o.io, e.arena(), exe, .{
        .operation = operation,
        .transaction_id = e.tx_id,
        .from_version = if (e.current) |c| c.app_version else null,
        .to_version = to_version,
        .scope = e.scope.?,
        .install_root = e.root,
    }, .{
        .timeout_ms = o.limits.bootstrap_timeout_ms,
        .max_output = o.limits.bootstrap_output_bytes,
        .parent_env = o.bootstrap_env,
    });
}

/// Rewrite `installation.json` (as left by `write_state`, with integration locations) with a new
/// bootstrap state.
fn writeBootstrapState(e: *Engine, p: platform.Platform, value: BootstrapState) Error!void {
    var state = try e.readInstallation(e.root) orelse return error.NotInstalled;
    state.bootstrap = value;
    const path = try std.fs.path.join(e.arena(), &.{ e.root, "installation.json" });
    try p.writeFile(path, try contracts.installation.encode(e.arena(), state), false);
}

/// Every entrypoint of the new release resolves through `current`.
fn verifyInstall(e: *Engine) Error!void {
    const io = e.options.io;
    for (e.metas) |meta| {
        for (meta.entrypoints.map.values()) |entry| {
            const path = try std.fs.path.join(
                e.arena(),
                &.{ e.root, "current", meta.id, entry.path },
            );
            std.Io.Dir.cwd().access(io, path, .{}) catch return error.FsVerifyFailed;
        }
    }
}

/// Persist the verified root and versions so the next refresh rejects rollbacks.
fn saveTrust(e: *Engine, p: platform.Platform) Error!void {
    const resolution = e.resolution.?;
    const dir = try std.fs.path.join(e.arena(), &.{ e.root, "trust" });
    try p.createDirPath(dir);
    const root_path = try std.fs.path.join(e.arena(), &.{ dir, "root.json" });
    try p.writeFile(root_path, resolution.verified.root_bytes, false);
    const state_path = try std.fs.path.join(e.arena(), &.{ dir, "state.json" });
    const state = try contracts.installation.encode(e.arena(), resolution.trust_state);
    try p.writeFile(state_path, state, false);
}

/// The channel offers the installed release: nothing to deploy, but a pending bootstrap from an
/// earlier run is retried.
pub fn upToDate(e: *Engine) Error!void {
    const current = e.current.?;
    var report: Report = .{
        .outcome = .up_to_date,
        .scope = current.scope,
        .root = e.root,
        .product_version = current.app_version,
        .release_sequence = current.release_sequence,
        .bootstrap = current.bootstrap,
    };
    if (current.bootstrap == .pending) if (current.bootstrap_target) |target| {
        e.sink().phase(.bootstrap);
        e.tx_id = try e.arena().print("tx-{d}-retry", .{current.active_tx});
        if (callBootstrap(e, target, .activate, current.app_version)) |_| {
            const p = try e.mutator(current.scope, .{
                .tx_id = e.tx_id,
                .managed_roots = try e.arena().dupe([]const u8, &.{e.root}),
                .source_roots = &.{},
            });
            defer e.releaseMutator(current.scope);
            try writeBootstrapState(e, p, .done);
            report.bootstrap = .done;
        } else |err| report.bootstrap_error = @errorName(err);
    };
    e.sink().phase(.complete);
    e.report = report;
    e.step = .done;
}

/// Deactivate the App Bootstrap (best effort), then remove the release, its integrations and the
/// install root in one transaction.
fn uninstall(e: *Engine) Error!Report {
    try e.expect(.begun);
    const o = e.options;
    const current = e.current.?;
    e.tx_seq = current.active_tx + 1;
    e.tx_id = try e.arena().print("tx-{d}-uninstall", .{e.tx_seq});
    if (current.bootstrap_target) |target| {
        e.sink().phase(.bootstrap);
        if (callBootstrap(e, target, .deactivate, current.app_version)) |_| {} else |err| {
            std.log.warn("bootstrap deactivate failed: {t}", .{err});
        }
    }
    e.sink().phase(.plan);
    const staging = try std.fs.path.join(e.arena(), &.{ e.root, "staging", "uninstall" });
    const the_plan = try planner.uninstall(e.arena(), .{
        .tx_seq = e.tx_seq,
        .tx_id = e.tx_id,
        .root = e.root,
        .staging = staging,
        .os = o.os,
        .support = .default(o.os, current.scope),
        .current = current,
        .limits = o.limits,
    });
    const p = try e.mutator(current.scope, .{
        .tx_id = e.tx_id,
        .managed_roots = try e.arena().dupe([]const u8, &.{e.root}),
        .source_roots = &.{},
    });
    defer e.releaseMutator(current.scope);
    e.sink().phase(.execute);
    var t = try transaction.Transaction.begin(o.io, e.arena(), p, the_plan, o.limits);
    try t.commit();
    e.sink().phase(.commit);
    try t.postCommit();
    e.sink().phase(.finalize);
    try t.finalize();
    e.sink().phase(.complete);
    const report: Report = .{
        .outcome = .uninstalled,
        .scope = current.scope,
        .root = e.root,
        .product_version = current.app_version,
        .release_sequence = current.release_sequence,
    };
    e.step = .done;
    e.report = report;
    return report;
}
