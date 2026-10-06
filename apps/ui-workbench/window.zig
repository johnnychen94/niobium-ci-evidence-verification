//! `ui-workbench window [--fail|--smoke]`: the sample product in this OS's native window,
//! driven by a simulated operation (no engine). For manual review of the backend: input,
//! focus, DPI, appearance changes, the folder dialog, cancel and failure flows. `--smoke`
//! opens, draws, wakes the UI thread from another thread and closes on that wake.

const std = @import("std");
const screens = @import("ui_screens");
const render = @import("ui_render");
const tokens = @import("ui_tokens");
const backend = @import("ui_backend");

const native = backend.native;
const Mailbox = backend.host.Mailbox;

const Demo = struct {
    io: std.Io,
    fail: bool,
    cancel: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn operation(d: *Demo) backend.host.Operation {
        return .{ .context = d, .start_fn = start, .cancel_fn = stop };
    }

    fn start(context: *anyopaque, _: screens.controller.Start, mailbox: *Mailbox) anyerror!void {
        // lint-allow(ptr-cast-allowlist): Operation context is the *Demo set in `operation`.
        const d: *Demo = @ptrCast(@alignCast(context));
        d.join();
        d.cancel.store(false, .release);
        d.thread = try std.Thread.spawn(.{}, work, .{ d, mailbox });
    }

    fn stop(context: *anyopaque) void {
        // lint-allow(ptr-cast-allowlist): Operation context is the *Demo set in `operation`.
        const d: *Demo = @ptrCast(@alignCast(context));
        d.cancel.store(true, .release);
    }

    fn join(d: *Demo) void {
        if (d.thread) |t| t.join();
        d.thread = null;
    }

    fn work(d: *Demo, mailbox: *Mailbox) void {
        mailbox.post(.{ .phase = .resolve });
        d.io.sleep(.fromMilliseconds(1200), .awake) catch return;
        for (0..41) |i| {
            if (d.cancel.load(.acquire)) return mailbox.finish(.canceled);
            const fraction = @as(f32, @floatFromInt(i)) / 40;
            mailbox.post(
                .{ .phase = .download, .progress = fraction, .message = "hello-1.0.0.tar.zst" },
            );
            d.io.sleep(.fromMilliseconds(60), .awake) catch return;
        }
        if (d.fail) return mailbox.finish(.{ .failed = .{
            .code = "TrustHashMismatch",
            .message = "A downloaded file did not match the signed release. Nothing was changed.",
            .retryable = true,
        } });
        mailbox.post(.{ .phase = .commit });
        d.io.sleep(.fromMilliseconds(400), .awake) catch return;
        mailbox.finish(.succeeded);
    }
};

pub const Mode = enum { demo, fail, smoke };

/// Closes the window on the first wake-up.
const Smoke = struct {
    closed: bool = false,
    woke: bool = false,

    pub fn command(s: *Smoke, c: screens.Command) !void {
        if (c == .close) s.closed = true;
    }

    pub fn wake(s: *Smoke) !void {
        s.woke = true;
        s.closed = true;
    }

    pub fn done(s: *const Smoke) bool {
        return s.closed;
    }

    fn poke(io: std.Io, waker: backend.window.Waker) void {
        io.sleep(.fromMilliseconds(500), .awake) catch return;
        waker.wake();
    }
};

/// The window's own pixels against the canvas: same size and orientation, and colors within
/// the display color conversion. The canvas is tagged sRGB and the window caches in its
/// screen's space (Display P3 on recent Macs), which moves saturated accents by up to ~35.
fn compare(
    io: std.Io,
    arena: std.mem.Allocator,
    win: *native.Window,
    c: *const render.Canvas,
) !u8 {
    if (!@hasDecl(native.Window, "snapshot")) return 0;
    const shot = try win.snapshot(arena) orelse return 1;
    if (shot.width != c.width or shot.height != c.height) {
        std.log.err(
            "snapshot {d}x{d} != canvas {d}x{d}",
            .{ shot.width, shot.height, c.width, c.height },
        );
        return 1;
    }
    var worst: u32 = 0;
    for (shot.pixels, c.pixels) |a, b| {
        inline for (.{ 0, 8, 16 }) |shift| {
            const da: i32 = @intCast((a >> shift) & 0xFF);
            const db: i32 = @intCast((b >> shift) & 0xFF);
            worst = @max(worst, @abs(da - db));
        }
    }
    const png = try render.png.encode(arena, shot);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "zig-out/window-smoke.png", .data = png });
    std.log.info(
        "window smoke: {d}x{d}, worst channel delta {d}",
        .{ shot.width, shot.height, worst },
    );
    return if (worst <= 40) 0 else 1;
}

pub fn run(init: std.process.Init, mode: Mode) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    var controller = try backend.offscreen.sampleController(arena, .welcome);
    const metrics = tokens.metrics(backend.platform);
    const system_font = backend.fonts.load(io, arena, backend.platform, init.environ_map);
    const fonts = try render.Fonts.createWith(gpa, system_font);
    defer fonts.destroy();
    var win: native.Window = undefined; // SAFETY: `open` initializes every field.
    try win.open(arena, init.environ_map, .{
        .title = "Hello Setup",
        .width = metrics.window_width,
        .height = metrics.window_height,
    });
    defer win.close();
    var session: backend.Session = undefined; // SAFETY: `init` initializes every field.
    try session.init(gpa, fonts, &controller, .{
        .platform = backend.platform,
        .capabilities = native.capabilities,
        .branding = backend.offscreen.sample_branding,
        .system = win.system(),
        .scale = win.scale(),
    });
    defer session.deinit();
    if (mode == .smoke) {
        var smoke: Smoke = .{};
        const thread = try std.Thread.spawn(.{}, Smoke.poke, .{ io, win.waker() });
        defer thread.join();
        try backend.driver.run(io, native.Window, &win, &session, &smoke);
        if (!smoke.woke) return 1;
        return compare(io, arena, &win, try session.draw(0));
    }
    var demo: Demo = .{ .io = io, .fail = mode == .fail };
    defer demo.join();
    var host: backend.host.Host(native.Window) = .{
        .win = &win,
        .session = &session,
        .operation = demo.operation(),
        .mailbox = .{ .io = io, .waker = win.waker() },
    };
    try backend.driver.run(io, native.Window, &win, &session, &host);
    return 0;
}
