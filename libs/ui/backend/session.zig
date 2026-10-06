//! One installer window's state between the native backend and the screens: the current frame,
//! interaction, theme and canvas. Backend-independent, so the whole GUI flow (pointer and
//! keyboard input to engine commands, engine events to pixels) runs headless in tests.

const std = @import("std");
const contracts = @import("contracts");
const ui = @import("ui_core");
const screens = @import("ui_screens");
const render = @import("ui_render");
const tokens = @import("ui_tokens");
const window = @import("window.zig");

pub const Error = render.Error || screens.model.Error || ui.bind_mod.Error ||
    render.Canvas.Error;

pub const Options = struct {
    platform: tokens.Platform,
    capabilities: ui.env.Capabilities,
    branding: contracts.installation.Branding = .{},
    system: window.System = .{},
    /// Device pixels per 100 logical pixels.
    scale: u16 = 100,
    logo: ?render.Image = null,
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    fonts: *render.Fonts,
    controller: *screens.Controller,
    o: Options,
    theme: tokens.Theme,
    env: ui.Env,
    interaction: ui.Interaction = .{},
    arena_state: std.heap.ArenaAllocator,
    frame: ?ui.Frame = null,
    canvas: ?render.Canvas = null,
    /// Rebind before the next draw (state or size changed).
    stale: bool = true,

    /// `s` must stay at a fixed address while frames reference its env.
    pub fn init(
        s: *Session,
        gpa: std.mem.Allocator,
        fonts: *render.Fonts,
        controller: *screens.Controller,
        o: Options,
    ) Error!void {
        s.* = .{
            .gpa = gpa,
            .fonts = fonts,
            .controller = controller,
            .o = o,
            .theme = try screens.model.theme(o.branding, o.system.theme()),
            .env = undefined, // SAFETY: set by applyEnv below.
            .arena_state = .init(gpa),
        };
        s.applyEnv();
    }

    pub fn deinit(s: *Session) void {
        if (s.canvas) |*c| c.deinit(s.gpa);
        s.arena_state.deinit();
        s.* = undefined; // SAFETY: the session is dead after deinit.
    }

    fn applyEnv(s: *Session) void {
        s.env = .{
            .theme = &s.theme,
            .metrics = tokens.metrics(s.o.platform),
            .scale = s.o.scale,
            .capabilities = s.o.capabilities,
            .reduced_motion = s.o.system.reduced_motion,
            .text = s.fonts.measurer(),
        };
        s.stale = true;
    }

    /// Client size in device pixels for the platform's window at the current scale.
    pub fn size(s: *const Session) window.Size {
        return .{
            .w = s.env.px(s.env.metrics.window_width),
            .h = s.env.px(s.env.metrics.window_height),
        };
    }

    pub fn setSystem(s: *Session, system: window.System) Error!void {
        s.theme = try screens.model.theme(s.o.branding, system.theme());
        s.o.system = system;
        s.applyEnv();
    }

    pub fn setScale(s: *Session, scale: u16) void {
        s.o.scale = scale;
        s.applyEnv();
    }

    /// The controller changed outside input (engine event, folder answer).
    pub fn invalidate(s: *Session) void {
        s.stale = true;
    }

    fn current(s: *Session) Error!ui.Frame {
        if (!s.stale) if (s.frame) |f| return f;
        // lint-allow(no-discard-call): a failed retain only frees instead of reusing.
        _ = s.arena_state.reset(.retain_capacity);
        const arena = s.arena_state.allocator();
        // Reconcile only forgets nodes that are gone, so the frame needs no second build.
        const f = try screens.frame(arena, &s.env, s.controller, s.size(), &s.interaction);
        s.interaction.reconcile(f.tree);
        s.frame = f;
        s.stale = false;
        return f;
    }

    /// Pointer or key input in device pixels; the engine command it asks for, if any.
    pub fn input(s: *Session, event: ui.input.Event) Error!?screens.Command {
        const f = try s.current();
        const intent = ui.input.handle(f.tree, f.layout, s.env.direction, &s.interaction, event);
        s.stale = true;
        const i = intent orelse return null;
        return s.controller.handle(i);
    }

    /// The window close box behaves like the screen's close action.
    pub fn closeRequested(s: *Session) ?screens.Command {
        s.stale = true;
        return s.controller.handle(.{ .action = .close });
    }

    /// An indeterminate progress bar animates unless the system asks for reduced motion.
    pub fn animating(s: *const Session) bool {
        if (s.o.system.reduced_motion) return false;
        return s.controller.screen == .progress and s.controller.vm.progress_unknown;
    }

    pub fn draw(s: *Session, time_ms: u64) Error!*const render.Canvas {
        if (s.animating() and s.env.time_ms != time_ms) {
            s.env.time_ms = time_ms;
            s.stale = true;
        }
        const f = try s.current();
        const want = s.size();
        if (s.canvas) |c| if (c.width != want.w or c.height != want.h) {
            s.canvas.?.deinit(s.gpa);
            s.canvas = null;
        };
        if (s.canvas == null) s.canvas = try .init(s.gpa, want.w, want.h);
        const c = &s.canvas.?;
        try render.render(c, s.fonts, f.display.items(), .{
            .images = .{ .logo = s.o.logo },
            .placeholder = s.theme.border,
        });
        return c;
    }
};

/// The branding logo as pixels, or null when absent. Invalid bytes were rejected before the
/// window opened (`screens.model.validate` bounds the size; decoding checks the PNG).
pub fn decodeLogo(
    arena: std.mem.Allocator,
    branding: contracts.installation.Branding,
) error{ OutOfMemory, UiBrandingInvalid }!?render.Image {
    const text = branding.logo_png orelse return null;
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(text) catch return error.UiBrandingInvalid;
    if (len > contracts.installation.max_logo_bytes) return error.UiBrandingInvalid;
    const bytes = try arena.alloc(u8, len);
    decoder.decode(bytes, text) catch return error.UiBrandingInvalid;
    return render.png.decode(arena, bytes) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.UiBrandingInvalid,
    };
}

fn center(s: *Session, id: []const u8) !ui.geometry.Point {
    const f = try s.current();
    const r = f.layout.rects[f.tree.find(id) orelse return error.TestNodeMissing];
    return .{ .x = r.x + @divFloor(r.w, 2), .y = r.y + @divFloor(r.h, 2) };
}

test "a click on the laid-out Next button moves to options" {
    const testing = @import("testing.zig");
    var t: testing.Harness = undefined;
    try t.init(std.testing.allocator);
    defer t.deinit();
    const s = &t.session;
    const at = try center(s, "next");
    try std.testing.expectEqual(null, try s.input(.{ .pointer_move = at }));
    try std.testing.expectEqual(null, try s.input(.{ .pointer_down = at }));
    try std.testing.expectEqual(null, try s.input(.{ .pointer_up = at }));
    try std.testing.expectEqual(screens.Screen.options, t.controller.screen);
    const picker = try center(s, "location");
    try std.testing.expectEqual(null, try s.input(.{ .pointer_down = picker }));
    const command = try s.input(.{ .pointer_up = picker });
    try std.testing.expect(command.? == .choose_folder);
}

test "system appearance re-themes and the canvas follows the scale" {
    const testing = @import("testing.zig");
    var t: testing.Harness = undefined;
    try t.init(std.testing.allocator);
    defer t.deinit();
    const s = &t.session;
    const light = (try s.draw(0)).pixels[0];
    try s.setSystem(.{ .dark = true, .high_contrast = true });
    const c = try s.draw(0);
    try std.testing.expect(c.pixels[0] != light);
    try std.testing.expectEqual(render.canvas.pack(tokens.contrast_dark.bg), c.pixels[0]);
    s.setScale(200);
    try std.testing.expectEqual(@as(i32, 2 * tokens.macos.window_width), (try s.draw(0)).width);
}

test "indeterminate progress animates unless motion is reduced" {
    const testing = @import("testing.zig");
    var t: testing.Harness = undefined;
    try t.init(std.testing.allocator);
    defer t.deinit();
    const s = &t.session;
    try std.testing.expect(try s.input(.{ .key = .enter }) == null);
    const start = try s.input(.{ .key = .enter });
    try std.testing.expect(start.? == .start);
    try std.testing.expect(!s.animating());
    try s.setSystem(.{});
    try std.testing.expect(s.animating());
    const a = (try s.draw(0)).pixels;
    const first = try std.testing.allocator.dupe(u32, a);
    defer std.testing.allocator.free(first);
    const b = (try s.draw(700)).pixels;
    try std.testing.expect(!std.mem.eql(u32, first, b));
}
