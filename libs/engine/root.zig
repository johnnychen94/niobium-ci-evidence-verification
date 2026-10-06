//! Distribution engine (docs/architecture/overview.md): one state machine behind the CLI, the GUI
//! and the C ABI.
//!
//!   begin (lock, recover, discover) -> resolve (TUF, manifest) -> fetch (download, verify)
//!     -> stage (extract, validate) -> commit (plan, transaction, bootstrap, verify, finalize)
//!
//! Uninstall goes begin -> commit. `run` drives every step and reports failures as an `error`
//! event; frontends that need finer control (the C ABI) call the steps one by one.

const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts");
const core = @import("core");
const platform = @import("platform");
const manifest = @import("manifest");
const repository = @import("repository");
const resolver = @import("resolver");
const planner = @import("planner");
const transaction = @import("transaction");
const bootstrap = @import("bootstrap");
const portable = @import("portable");

pub const events = @import("events.zig");
pub const elevation = @import("elevation.zig");
pub const runtime = @import("runtime.zig");
const steps = @import("steps.zig");
const finishing = @import("commit.zig");

pub const Kind = contracts.journal.TxKind;
pub const Installation = contracts.installation.Installation;
pub const Sink = events.Sink;
pub const Elevator = elevation.Elevator;

pub const Error = portable.Error || planner.Error || planner.paths.Error || transaction.Error ||
    bootstrap.Error || elevation.Error || error{ UsageStepOrder, FsVerifyFailed, Canceled };

pub fn nativeOs() platform.Os {
    return switch (builtin.os.tag) {
        .windows => .windows,
        .macos => .macos,
        else => .linux,
    };
}

pub const Options = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// User-level mutations (user scope, and everything in the user cache).
    platform: platform.Platform,
    elevator: Elevator = .unavailable,
    repository: *const repository.Repository,
    /// Trusted root envelope shipped with setup; a rotated root under `<root>/trust/` wins.
    root_bytes: []const u8,
    product_id: []const u8,
    /// Null keeps the installed channel (stable on first install).
    channel: ?contracts.Channel = null,
    /// Null keeps the installed scope, or takes the manifest default.
    scope: ?contracts.Scope = null,
    /// Null keeps the installed selection, or takes the manifest defaults.
    components: ?[]const []const u8 = null,
    /// Install root override (`--install-dir`).
    install_dir: ?[]const u8 = null,
    /// Cache override (C ABI `work_dir`); otherwise the per-user product cache.
    work_dir: ?[]const u8 = null,
    env: platform.Env = .{},
    os: platform.Os = nativeOs(),
    /// Artifact platform; tests pin it so fixtures are host-independent.
    target_platform: contracts.Platform,
    installer_version: []const u8,
    /// The running setup, copied into `maintainer/`; null when embedded as a library.
    maintainer_source: ?[]const u8 = null,
    /// Environment the App Bootstrap child inherits its few variables from.
    bootstrap_env: ?*const std.process.Environ.Map = null,
    sink: Sink = .{},
    cancel: ?*const std.atomic.Value(bool) = null,
    /// Fixed clock for TUF expiry (tests); null reads the real clock.
    now: ?i64 = null,
    limits: contracts.Limits = .{},
};

pub const Step = enum { idle, begun, resolved, fetched, staged, done };

pub const Outcome = enum { installed, updated, repaired, up_to_date, uninstalled };

pub const Report = struct {
    outcome: Outcome,
    scope: contracts.Scope,
    root: []const u8,
    product_version: []const u8 = "",
    release_sequence: u64 = 0,
    bootstrap: contracts.installation.BootstrapState = .none,
    /// Why the App Bootstrap failed, when `bootstrap` is `pending`.
    bootstrap_error: ?[]const u8 = null,

    /// Committed with a pending bootstrap is exit code 8 (docs/spec/bootstrap-v1.md#semantics).
    pub fn exitCode(r: Report) core.ExitCode {
        return if (r.bootstrap == .pending) .bootstrap_pending else .ok;
    }
};

pub const Offer = struct {
    available: bool,
    release_sequence: u64,
    version: []const u8,
};

pub const Engine = struct {
    options: Options,
    arena_state: std.heap.ArenaAllocator,
    step: Step = .idle,
    kind: Kind = .install,
    lock: ?transaction.Lock = null,
    cache: []const u8 = "",
    scope: ?contracts.Scope = null,
    root: []const u8 = "",
    current: ?Installation = null,
    resolution: ?resolver.Resolution = null,
    tx_seq: u64 = 0,
    tx_id: []const u8 = "",
    staging: []const u8 = "",
    metas: []const manifest.ComponentMeta = &.{},
    report: ?Report = null,

    pub fn init(options: Options) Engine {
        return .{ .options = options, .arena_state = .init(options.gpa) };
    }

    pub fn deinit(e: *Engine) void {
        if (e.lock) |lock| lock.release(e.options.io);
        e.lock = null;
        e.arena_state.deinit();
    }

    pub fn arena(e: *Engine) std.mem.Allocator {
        return e.arena_state.allocator();
    }

    pub fn now(e: *const Engine) i64 {
        return e.options.now orelse std.Io.Clock.real.now(e.options.io).toSeconds();
    }

    pub fn checkCancel(e: *const Engine) Error!void {
        const flag = e.options.cancel orelse return;
        if (flag.load(.acquire)) return error.Canceled;
    }

    pub fn expect(e: *const Engine, step: Step) Error!void {
        if (e.step != step) return error.UsageStepOrder;
    }

    pub fn sink(e: *const Engine) Sink {
        return e.options.sink;
    }

    /// Every step in order; a failure becomes the terminal `error` event.
    pub fn run(e: *Engine, kind: Kind) Error!Report {
        return e.runSteps(kind) catch |err| {
            e.sink().failure(@errorName(err));
            return err;
        };
    }

    fn runSteps(e: *Engine, kind: Kind) Error!Report {
        try e.begin(kind);
        if (kind != .uninstall) {
            try e.resolve();
            if (e.report) |report| return report;
            try e.fetch();
            try e.stage();
        }
        return e.commit();
    }

    /// Lock, recover interrupted transactions, find the installed release. `install` over an
    /// existing installation proceeds as `update`.
    pub fn begin(e: *Engine, kind: Kind) Error!void {
        try e.expect(.idle);
        const o = e.options;
        e.kind = kind;
        e.sink().phase(.recover);
        e.cache = o.work_dir orelse try planner.paths.cacheRoot(
            e.arena(),
            o.os,
            o.product_id,
            o.env,
        );
        const lock_path = try std.fs.path.join(e.arena(), &.{ e.cache, "lock" });
        e.lock = try transaction.Lock.acquire(o.io, lock_path);
        e.sink().phase(.discover);
        try e.discover();
        switch (kind) {
            .install => if (e.current != null) {
                e.kind = .update;
            },
            .update, .repair, .uninstall => if (e.current == null) return error.NotInstalled,
        }
        e.step = .begun;
    }

    fn rootFor(e: *Engine, scope: contracts.Scope) Error![]const u8 {
        const o = e.options;
        if (o.install_dir) |dir| return dir;
        return planner.paths.installRoot(e.arena(), o.os, scope, o.product_id, o.env);
    }

    fn discover(e: *Engine) Error!void {
        const o = e.options;
        const both = [_]contracts.Scope{ .user, .machine };
        const candidates: []const contracts.Scope = if (o.scope) |*s|
            s[0..1]
        else if (o.install_dir != null) both[0..1] else &both;
        for (candidates) |candidate| {
            const root = try e.rootFor(candidate);
            const found = try e.readInstallation(root);
            const scope = if (found) |f| f.scope else o.scope orelse candidate;
            try e.recoverAt(scope, root);
            // Recovery may have rolled a transaction forward or back.
            const installed = try e.readInstallation(root) orelse continue;
            if (!std.mem.eql(u8, installed.product_id, o.product_id)) {
                return error.PlanProductMismatch;
            }
            e.scope = installed.scope;
            e.root = root;
            e.current = installed;
            return;
        }
        e.scope = o.scope;
        if (o.scope) |scope| e.root = try e.rootFor(scope);
    }

    pub fn readInstallation(e: *Engine, root: []const u8) Error!?Installation {
        const path = try std.fs.path.join(e.arena(), &.{ root, "installation.json" });
        const max: std.Io.Limit = .limited(contracts.installation.max_state_bytes);
        const cwd = std.Io.Dir.cwd();
        const bytes = cwd.readFileAlloc(e.options.io, path, e.arena(), max) catch |err|
            switch (err) {
                error.FileNotFound, error.NotDir => return null,
                else => return platform.api.mapFs(err),
            };
        return try contracts.installation.decodeInstallation(e.arena(), bytes);
    }

    /// Roll an interrupted transaction under `root` back or forward. Machine roots need the
    /// helper, so it is only started when a journal is actually there.
    fn recoverAt(e: *Engine, scope: contracts.Scope, root: []const u8) Error!void {
        const journal = try std.fs.path.join(e.arena(), &.{ root, "journal" });
        if (!e.hasEntries(journal)) return;
        const p = try e.mutator(scope, .{
            .tx_id = "tx-recover",
            .managed_roots = try e.arena().dupe([]const u8, &.{root}),
            .source_roots = &.{},
        });
        defer e.releaseMutator(scope);
        const recovered = try transaction.recover(
            e.options.io,
            e.arena(),
            p,
            root,
            e.options.limits,
        );
        std.log.info("recovery at {s}: {t}", .{ root, recovered.outcome });
    }

    fn hasEntries(e: *Engine, path: []const u8) bool {
        const io = e.options.io;
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return false;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch return true) |entry| {
            if (!std.mem.eql(u8, entry.name, "lock")) return true;
        }
        return false;
    }

    /// The platform for mutations under `scope`; machine scope opens the elevator.
    pub fn mutator(
        e: *Engine,
        scope: contracts.Scope,
        grant: elevation.Grant,
    ) Error!platform.Platform {
        return switch (scope) {
            .user => e.options.platform,
            .machine => e.options.elevator.open(e.arena(), grant),
        };
    }

    pub fn releaseMutator(e: *Engine, scope: contracts.Scope) void {
        if (scope == .machine) e.options.elevator.close();
    }

    /// TUF refresh and manifest validation. An update offering the installed release finishes
    /// here as `up_to_date` (after retrying a pending bootstrap).
    pub fn resolve(e: *Engine) Error!void {
        try e.expect(.begun);
        try e.checkCancel();
        const o = e.options;
        const installed = e.current;
        e.sink().phase(.resolve);
        const resolution = try resolver.resolve(e.arena(), o.repository, .{
            .product_id = o.product_id,
            .root_bytes = try e.trustRoot(),
            .channel = o.channel orelse if (installed) |c| c.channel else .stable,
            .platform = o.target_platform,
            .installer_version = o.installer_version,
            .now = e.now(),
            .trusted = try e.trustState(),
            .installed_sequence = if (installed) |c| c.release_sequence else null,
            .scope = o.scope orelse if (installed) |c| c.scope else null,
            .components = o.components orelse if (installed) |c| c.components else null,
            .limits = o.limits,
        });
        e.sink().phase(.validate);
        if (installed) |c| if (c.scope != resolution.scope) return error.PlanScopeChange;
        e.resolution = resolution;
        if (e.scope != resolution.scope or e.root.len == 0) e.root = try e.rootFor(
            resolution.scope,
        );
        e.scope = resolution.scope;
        if (e.kind == .update and resolution.relation == .same) {
            return finishing.upToDate(e);
        }
        const active = if (installed) |c| c.active_tx else 0;
        e.tx_seq = active + 1;
        var random: [4]u8 = undefined; // SAFETY: filled by random.
        o.io.random(&random);
        const hex = std.fmt.bytesToHex(random, .lower);
        e.tx_id = try e.arena().print("tx-{d}-{s}", .{ e.tx_seq, &hex });
        e.staging = try planner.paths.stagingDir(
            e.arena(),
            o.os,
            resolution.scope,
            e.root,
            e.cache,
            e.tx_seq,
        );
        e.step = .resolved;
    }

    /// What the channel offers relative to the installed release (after `resolve`).
    pub fn offer(e: *const Engine) ?Offer {
        const r = e.resolution orelse return null;
        return .{
            .available = r.relation != .same,
            .release_sequence = r.manifest.product.release_sequence,
            .version = r.manifest.product.version,
        };
    }

    fn trustFile(e: *Engine, name: []const u8) Error!?[]const u8 {
        if (e.root.len == 0) return null;
        const path = try std.fs.path.join(e.arena(), &.{ e.root, "trust", name });
        const cwd = std.Io.Dir.cwd();
        return cwd.readFileAlloc(e.options.io, path, e.arena(), .limited(4 << 20)) catch |err|
            switch (err) {
                error.FileNotFound, error.NotDir => null,
                else => platform.api.mapFs(err),
            };
    }

    fn trustRoot(e: *Engine) Error![]const u8 {
        return try e.trustFile("root.json") orelse e.options.root_bytes;
    }

    fn trustState(e: *Engine) Error!?contracts.installation.TrustState {
        const bytes = try e.trustFile("state.json") orelse return null;
        return try contracts.installation.decodeTrustState(e.arena(), bytes);
    }

    pub fn fetch(e: *Engine) Error!void {
        return steps.fetch(e);
    }

    pub fn stage(e: *Engine) Error!void {
        return steps.stage(e);
    }

    pub fn commit(e: *Engine) Error!Report {
        return finishing.commit(e);
    }

    /// The installed state without changing anything (`setup status`).
    pub fn status(e: *Engine) Error!?Installation {
        try e.begin(.install);
        return e.current;
    }
};

test {
    _ = events;
    _ = elevation;
    _ = runtime;
    _ = @import("engine_test.zig");
}
