//! The installer window (`setup` with no arguments). The window's choices become the same
//! `cli.Command` the command line parses and run through the same `frontend.prepare` and
//! `frontend.runTransaction` (N1-INV-07); only the event sink differs. The transaction runs on
//! a worker thread with its own arena and reports through the host's mailbox.

const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts");
const core = @import("core");
const engine = @import("engine");
const screens = @import("ui_screens");
const render = @import("ui_render");
const tokens = @import("ui_tokens");
const backend = @import("ui_backend");
const cli = @import("cli.zig");
const frontend = @import("frontend.zig");

const native = backend.native;
pub const Start = screens.controller.Start;
const Mailbox = backend.host.Mailbox;
const Atomic = std.atomic.Value;

/// Whether a window can open here. X11 needs `DISPLAY` (Wayland sessions provide XWayland).
pub fn available(environ: *const std.process.Environ.Map) bool {
    return switch (builtin.os.tag) {
        .linux => environ.get("DISPLAY") != null,
        else => true,
    };
}

/// The command a window start runs: `setup <verb> --scope <scope> [--install-dir <dir>]`.
pub fn commandFor(start: Start) cli.Command {
    const verb: cli.Verb = switch (start.operation) {
        .install => .install,
        .update => .update,
        .repair => .repair,
        .uninstall => .uninstall,
    };
    return .{
        .verb = verb,
        .options = .{ .scope = start.scope, .install_dir = start.install_dir },
    };
}

/// The first screen: update what is installed, otherwise install.
pub fn controllerFor(
    arena: std.mem.Allocator,
    s: *const frontend.Settings,
    survey: frontend.Survey,
) screens.model.Error!screens.Controller {
    const installed = survey.installed_scope != null;
    const vm = try screens.model.viewModel(arena, .{
        .config = &s.config,
        .operation = if (installed) .update else .install,
        .fallback_name = s.product_id,
        .version = survey.installed_version,
        .scope = survey.installed_scope orelse s.scope orelse s.config.default_scope orelse .user,
        .scope_editable = !installed,
        .location = survey.root,
        .location_editable = !installed,
    });
    var c: screens.Controller = .init(arena, vm, .{
        .user_location = survey.user_location,
        .machine_location = survey.machine_location,
    });
    if (installed) c.install_dir = survey.root;
    return c;
}

/// Runs window starts on a thread. `exit_code` is the last finished operation's, or
/// `cancelled` when the window closed before anything ran.
pub const Worker = struct {
    process: *frontend.Process,
    thread: ?std.Thread = null,
    /// The running transaction's cancel flag, published by `frontend.runTransaction`.
    flag: Atomic(?*Atomic(bool)) = .init(null),
    canceled: Atomic(bool) = .init(false),
    exit_code: Atomic(u8) = .init(@backingInt(core.ExitCode.cancelled)),

    pub fn operation(w: *Worker) backend.host.Operation {
        return .{ .context = w, .start_fn = start, .cancel_fn = cancel };
    }

    fn from(context: *anyopaque) *Worker {
        // lint-allow(ptr-cast-allowlist): the Operation context is the *Worker of `operation`.
        return @ptrCast(@alignCast(context));
    }

    fn start(context: *anyopaque, s: Start, mailbox: *Mailbox) anyerror!void {
        const w = from(context);
        w.join();
        w.canceled.store(false, .seq_cst);
        w.thread = try std.Thread.spawn(.{}, work, .{ w, commandFor(s), mailbox });
    }

    fn cancel(context: *anyopaque) void {
        const w = from(context);
        w.canceled.store(true, .seq_cst);
        if (w.flag.load(.seq_cst)) |flag| flag.store(true, .seq_cst);
    }

    fn publish(context: *anyopaque, flag: ?*Atomic(bool)) void {
        const w = from(context);
        w.flag.store(flag, .seq_cst);
        if (flag) |f| if (w.canceled.load(.seq_cst)) f.store(true, .seq_cst);
    }

    /// Cancels a running operation and waits for it.
    pub fn stop(w: *Worker) void {
        if (w.thread != null) cancel(w);
        w.join();
    }

    fn join(w: *Worker) void {
        if (w.thread) |t| t.join();
        w.thread = null;
    }

    fn work(w: *Worker, command: cli.Command, mailbox: *Mailbox) void {
        var arena_state: std.heap.ArenaAllocator = .init(w.process.gpa);
        defer arena_state.deinit();
        var p = w.process.*;
        p.arena = arena_state.allocator();
        w.exit_code.store(w.transact(&p, command, mailbox), .seq_cst);
    }

    /// Calls `mailbox.finish` exactly once and returns the exit code.
    pub fn transact(w: *Worker, p: *frontend.Process, command: cli.Command, mailbox: *Mailbox) u8 {
        const hook: frontend.CancelHook = .{ .context = w, .publish_fn = publish };
        const sink: engine.Sink = .bind(Mailbox, mailbox, Mailbox.post);
        const report = if (frontend.prepare(p, command)) |request|
            frontend.runTransaction(p, request, sink, hook)
        else |err|
            err;
        if (report) |r| {
            mailbox.finish(.succeeded);
            return @backingInt(r.exitCode());
        } else |err| {
            const code = core.exit_code.fromError(err);
            std.log.info("setup: {t} ({t})", .{ err, code });
            mailbox.finish(if (code == .cancelled) .canceled else .{ .failed = .{
                .code = @errorName(err),
                .message = screens.copy.failureMessage(code),
                .retryable = screens.copy.retryable(code),
            } });
            return @backingInt(code);
        }
    }
};

/// Opens the window, or prints usage when there is no product to install (a generic setup).
pub fn run(p: *frontend.Process) u8 {
    return runChecked(p) catch |err| {
        std.log.err("setup window: {t}", .{err});
        return @backingInt(core.exit_code.fromError(err));
    };
}

fn runChecked(p: *frontend.Process) !u8 {
    const s = frontend.settings(p, .{ .verb = .gui }) catch |err| switch (err) {
        error.UsageMissingProduct => return frontend.execute(p, .{ .verb = .gui }),
        else => return err,
    };
    var controller = try controllerFor(p.arena, &s, try frontend.survey(p, s));
    return show(p, &controller, s.config.branding);
}

fn show(
    p: *frontend.Process,
    controller: *screens.Controller,
    branding: contracts.installation.Branding,
) !u8 {
    const metrics = tokens.metrics(backend.platform);
    const system_font = backend.fonts.load(p.io, p.arena, backend.platform, p.environ);
    const fonts = try render.Fonts.createWith(p.gpa, system_font);
    defer fonts.destroy();
    var win: native.Window = undefined; // SAFETY: `open` initializes every field.
    try win.open(p.arena, p.environ, .{
        .title = try std.fmt.allocPrint(p.arena, "{s} Setup", .{controller.vm.product_name}),
        .width = metrics.window_width,
        .height = metrics.window_height,
    });
    defer win.close();
    var session: backend.Session = undefined; // SAFETY: `init` initializes every field.
    try session.init(p.gpa, fonts, controller, .{
        .platform = backend.platform,
        .capabilities = native.capabilities,
        .branding = branding,
        .system = win.system(),
        .scale = win.scale(),
    });
    defer session.deinit();
    var worker: Worker = .{ .process = p };
    defer worker.stop();
    var host: backend.host.Host(native.Window) = .{
        .win = &win,
        .session = &session,
        .operation = worker.operation(),
        .mailbox = .{ .io = p.io, .waker = win.waker() },
    };
    try backend.driver.run(p.io, native.Window, &win, &session, &host);
    worker.stop();
    return worker.exit_code.load(.seq_cst);
}
