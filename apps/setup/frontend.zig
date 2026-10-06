//! The headless frontend (docs/spec/cli-v1.md): one parsed command against the engine. Events go
//! to stdout as JSON lines with `--json`, otherwise as short progress lines on stderr.

const std = @import("std");
const build_options = @import("build_options");
const contracts = @import("contracts");
const core = @import("core");
const engine = @import("engine");
const planner = @import("planner");
const portable = @import("portable");
const cli = @import("cli.zig");

const Allocator = std.mem.Allocator;
const Runtime = engine.runtime.Runtime;
const Event = contracts.events.Event;

pub const Error = engine.Error || engine.runtime.Error || std.Io.Writer.Error || error{
    UsageMissingProduct,
    UsageMissingRepository,
    UsageMissingTrustRoot,
    UsageProductMismatch,
    ConfigUnreadable,
    ConfigInvalid,
    FsTrustRootUnreadable,
};

/// Portable cache entries unused for this long are collected after a run.
const portable_max_age_s: i64 = 30 * 24 * 60 * 60;

pub const Process = struct {
    io: std.Io,
    gpa: Allocator,
    arena: Allocator,
    environ: *const std.process.Environ.Map,
    /// The running setup (maintainer source, helper executable).
    self_exe: ?[]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    /// Product config compiled into setup (`-Dproduct-config`).
    embedded_config: []const u8,
    /// Fixed TUF clock for tests; null reads the real clock.
    now: ?i64 = null,
};

const Printer = struct {
    json: bool,
    silent: bool,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    last: ?contracts.events.Phase = null,
    reported: bool = false,

    fn sink(p: *Printer) engine.Sink {
        return .bind(Printer, p, emit);
    }

    fn emit(p: *Printer, event: Event) void {
        if (event.phase == .@"error") p.reported = true;
        if (p.json) {
            contracts.events.write(p.out, event) catch return;
            p.out.flush() catch return;
            return;
        }
        if (event.phase == .@"error") {
            const message = event.message orelse "";
            p.err.print("error: {s} ({s})\n", .{ message, event.code orelse "" }) catch return;
        } else if (!p.silent and p.last != event.phase) {
            p.last = event.phase;
            p.err.print("{t}\n", .{event.phase}) catch return;
        } else return;
        p.err.flush() catch return;
    }
};

/// Runs `command` and returns the process exit code; every failure is reported once.
pub fn execute(p: *Process, command: cli.Command) u8 {
    var printer: Printer = .{
        .json = command.options.json,
        .silent = command.options.silent,
        .out = p.stdout,
        .err = p.stderr,
    };
    const code = dispatch(p, command, &printer) catch |err| {
        if (!printer.reported) printer.sink().failure(@errorName(err));
        return @backingInt(core.exit_code.fromError(err));
    };
    return code;
}

fn dispatch(p: *Process, command: cli.Command, printer: *Printer) Error!u8 {
    switch (command.verb) {
        .gui, .help => try p.stdout.writeAll(cli.usage),
        .version => try p.stdout.print("setup {s}\n", .{build_options.version}),
        .install, .update, .repair, .uninstall => return transact(p, command, printer),
        .status => return status(p, command, printer),
        .run => return runPortable(p, command, printer),
    }
    try p.stdout.flush();
    return 0;
}

pub const Settings = struct {
    config: contracts.installation.ProductConfig,
    product_id: []const u8,
    repository: ?[]const u8,
    root_bytes: ?[]const u8,
    channel: ?contracts.Channel,
    scope: ?contracts.Scope,
};

fn readSmall(p: *Process, path: []const u8) ?[]const u8 {
    const max = 1 << 20;
    const bytes = std.Io.Dir.cwd().readFileAlloc(p.io, path, p.arena, .limited(max + 1)) catch
        return null;
    return if (bytes.len > max) null else bytes;
}

/// `repository/` next to the running setup: an offline bundle (docs/runbooks/offline-bundle.md).
fn bundled(p: *Process) ?[]const u8 {
    const exe = p.self_exe orelse return null;
    const dir = std.fs.path.dirname(exe) orelse return null;
    const path = std.fs.path.join(p.arena, &.{ dir, "repository" }) catch return null;
    const marker = std.fs.path.join(p.arena, &.{ path, "metadata", "timestamp.json" }) catch
        return null;
    std.Io.Dir.cwd().access(p.io, marker, .{}) catch return null;
    return path;
}

/// Command-line options over the product config (`--config` file, else the embedded one).
pub fn settings(p: *Process, command: cli.Command) Error!Settings {
    const o = command.options;
    const bytes = if (o.config) |path| readSmall(
        p,
        path,
    ) orelse return error.ConfigUnreadable else p.embedded_config;
    const config = contracts.installation.decodeProductConfig(p.arena, bytes) catch
        return error.ConfigInvalid;
    const root_bytes = if (o.trust_root) |path|
        readSmall(p, path) orelse return error.FsTrustRootUnreadable
    else
        config.trust_root;
    return .{
        .config = config,
        .product_id = o.product orelse config.product_id orelse return error.UsageMissingProduct,
        .repository = o.repo orelse bundled(p) orelse config.repository,
        .root_bytes = root_bytes,
        .channel = o.channel orelse if (config.mode == .branded) config.channel else null,
        .scope = o.scope orelse if (command.verb == .install) config.default_scope else null,
    };
}

fn now(p: *const Process) i64 {
    return p.now orelse std.Io.Clock.real.now(p.io).toSeconds();
}

/// Crash records go to `<cache>/logs` (docs/development/testing-lanes.md#crash-records).
fn configureCrash(p: *Process, rt: *const Runtime, product_id: []const u8) void {
    const cache = planner.paths.cacheRoot(p.arena, engine.nativeOs(), product_id, rt.env) catch
        return;
    const dir = std.fs.path.join(p.arena, &.{ cache, "logs" }) catch return;
    std.Io.Dir.cwd().createDirPath(p.io, dir) catch |err| {
        std.log.debug("crash log directory {s}: {t}", .{ dir, err });
        return;
    };
    core.crash.configure(.{ .version = build_options.version, .product = product_id, .dir = dir });
}

fn runtime(p: *Process, repository: ?[]const u8, self_exe: ?[]const u8) Error!*Runtime {
    const rt = try p.arena.create(Runtime);
    try rt.init(p.io, p.gpa, p.environ, repository, self_exe);
    return rt;
}

fn kindOf(verb: cli.Verb) engine.Kind {
    return switch (verb) {
        .install => .install,
        .update => .update,
        .repair => .repair,
        .uninstall => .uninstall,
        else => unreachable,
    };
}

/// One transaction, as the CLI flags or the GUI's choices describe it (N1-INV-07: both
/// frontends build this from a `cli.Command` and run it through `runTransaction`).
pub const Request = struct {
    kind: engine.Kind,
    settings: Settings,
    components: ?[]const []const u8,
    install_dir: ?[]const u8,
};

pub fn prepare(p: *Process, command: cli.Command) Error!Request {
    const kind = kindOf(command.verb);
    const s = try settings(p, command);
    if (kind != .uninstall) {
        if (s.repository == null) return error.UsageMissingRepository;
        if (s.root_bytes == null) return error.UsageMissingTrustRoot;
    }
    return .{
        .kind = kind,
        .settings = s,
        .components = command.options.components,
        .install_dir = command.options.install_dir,
    };
}

/// Lets another thread cancel: `publish_fn` gets the running transaction's flag, then null.
pub const CancelHook = struct {
    context: *anyopaque,
    publish_fn: *const fn (context: *anyopaque, flag: ?*std.atomic.Value(bool)) void,
};

/// Runs `r`; the report's strings are copied into `p.arena`.
pub fn runTransaction(
    p: *Process,
    r: Request,
    sink: engine.Sink,
    hook: ?CancelHook,
) Error!engine.Report {
    const s = r.settings;
    const rt = try runtime(p, s.repository, p.self_exe);
    defer rt.deinit();
    if (hook) |h| h.publish_fn(h.context, &rt.cancel);
    defer if (hook) |h| h.publish_fn(h.context, null);
    configureCrash(p, rt, s.product_id);
    var e: engine.Engine = .init(try rt.options(.{
        .product_id = s.product_id,
        .root_bytes = s.root_bytes orelse "",
        .channel = s.channel,
        .scope = s.scope,
        .components = r.components,
        .install_dir = r.install_dir,
        .installer_version = build_options.version,
        .sink = sink,
        .now = p.now,
    }));
    defer e.deinit();
    var report = try e.run(r.kind);
    report.root = try p.arena.dupe(u8, report.root);
    report.product_version = try p.arena.dupe(u8, report.product_version);
    if (report.bootstrap_error) |text| report.bootstrap_error = try p.arena.dupe(u8, text);
    return report;
}

fn transact(p: *Process, command: cli.Command, printer: *Printer) Error!u8 {
    const request = try prepare(p, command);
    const report = try runTransaction(p, request, printer.sink(), null);
    if (report.bootstrap == .pending) printer.emit(.{
        .phase = .bootstrap,
        .code = "bootstrap.pending",
        .message = report.bootstrap_error,
        .exit_code = @backingInt(core.ExitCode.bootstrap_pending),
    });
    if (!command.options.json and !command.options.silent) {
        try p.stderr.print("{t} {s} {s} ({t}) in {s}\n", .{
            report.outcome, request.settings.product_id, report.product_version,
            report.scope,   report.root,
        });
        try p.stderr.flush();
    }
    return @backingInt(report.exitCode());
}

/// What the window shows before anything runs: the current installation, if any, and the
/// default location per scope.
pub const Survey = struct {
    installed_scope: ?contracts.Scope = null,
    installed_version: []const u8 = "",
    root: []const u8 = "",
    user_location: []const u8,
    machine_location: []const u8,
};

pub fn survey(p: *Process, s: Settings) Error!Survey {
    const rt = try runtime(p, null, p.self_exe);
    defer rt.deinit();
    var e: engine.Engine = .init(try rt.options(.{
        .product_id = s.product_id,
        .root_bytes = "",
        .scope = s.scope,
        .installer_version = build_options.version,
    }));
    defer e.deinit();
    const os = engine.nativeOs();
    var out: Survey = .{
        .user_location = try planner.paths.installRoot(p.arena, os, .user, s.product_id, rt.env),
        .machine_location = try planner.paths.installRoot(
            p.arena,
            os,
            .machine,
            s.product_id,
            rt.env,
        ),
    };
    if (try e.status()) |current| {
        out.installed_scope = current.scope;
        out.installed_version = try p.arena.dupe(u8, current.app_version);
        out.root = try p.arena.dupe(u8, e.root);
    }
    return out;
}

fn status(p: *Process, command: cli.Command, printer: *Printer) Error!u8 {
    const s = try settings(p, command);
    const rt = try runtime(p, null, p.self_exe);
    defer rt.deinit();
    var e: engine.Engine = .init(try rt.options(.{
        .product_id = s.product_id,
        .root_bytes = "",
        .scope = s.scope,
        .install_dir = command.options.install_dir,
        .installer_version = build_options.version,
    }));
    defer e.deinit();
    const current = try e.status() orelse {
        printer.sink().failure("NotInstalled");
        return @backingInt(core.ExitCode.not_installed);
    };
    if (command.options.json) {
        try std.json.Stringify.value(.{
            .schema = 1,
            .product_id = current.product_id,
            .version = current.app_version,
            .release_sequence = current.release_sequence,
            .scope = current.scope,
            .channel = current.channel,
            .root = e.root,
            .bootstrap = current.bootstrap,
        }, .{}, p.stdout);
        try p.stdout.writeByte('\n');
    } else {
        try p.stdout.print("{s} {s} ({t}, {t}) in {s}\n", .{
            current.product_id, current.app_version, current.scope, current.channel, e.root,
        });
    }
    try p.stdout.flush();
    return 0;
}

fn runPortable(p: *Process, command: cli.Command, printer: *Printer) Error!u8 {
    const target = try portable.parseTarget(command.target.?);
    var with_product = command;
    if (command.options.product) |id| {
        if (!std.mem.eql(u8, id, target.product_id)) return error.UsageProductMismatch;
    }
    with_product.options.product = target.product_id;
    const s = try settings(p, with_product);
    const repository = s.repository orelse return error.UsageMissingRepository;
    const rt = try runtime(p, repository, null);
    defer rt.deinit();
    const cache_root = try planner.paths.cacheRoot(
        p.arena,
        engine.nativeOs(),
        target.product_id,
        rt.env,
    );
    const cache: portable.Cache = .{
        .io = p.io,
        .path = try std.fs.path.join(p.arena, &.{ cache_root, "portable" }),
    };
    printer.emit(.{ .phase = .resolve });
    const prepared = try portable.prepare(p.gpa, p.arena, &rt.repo, cache, .{
        .target = target,
        .root_bytes = s.root_bytes orelse return error.UsageMissingTrustRoot,
        .channel = s.channel orelse .stable,
        .platform = contracts.Platform.current() orelse return error.PlatformUnsupported,
        .installer_version = build_options.version,
        .now = now(p),
        .cancel = &rt.cancel,
    });
    if (cache.gc(p.arena, now(p), portable_max_age_s, prepared.digests)) |removed| {
        std.log.debug("portable cache: {d} stale entries removed", .{removed});
    } else |err| std.log.warn("portable cache gc: {t}", .{err});
    printer.emit(.{ .phase = .complete });
    return portable.run(p.io, prepared, p.arena, command.args, p.environ);
}
