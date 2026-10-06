//! Headless stand-ins for a native window and the setup app, for driver and session tests.

const std = @import("std");
const screens = @import("ui_screens");
const render = @import("ui_render");
const offscreen = @import("offscreen.zig");
const session_mod = @import("session.zig");
const window = @import("window.zig");

/// The sample product's controller and a session over the embedded font.
pub const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    fonts: *render.Fonts,
    controller: screens.Controller,
    session: session_mod.Session,

    /// `h` must stay at a fixed address (the session points at its controller).
    pub fn init(h: *Harness, gpa: std.mem.Allocator) !void {
        h.arena_state = .init(gpa);
        errdefer h.arena_state.deinit();
        h.fonts = try render.Fonts.create(gpa);
        errdefer h.fonts.destroy();
        h.controller = try offscreen.sampleController(h.arena_state.allocator(), .welcome);
        try h.session.init(gpa, h.fonts, &h.controller, .{
            .platform = .macos,
            .capabilities = .{ .native_folder_picker = true },
            .branding = offscreen.sample_branding,
            .system = .{ .reduced_motion = true },
        });
    }

    pub fn deinit(h: *Harness) void {
        h.session.deinit();
        h.fonts.destroy();
        h.arena_state.deinit();
    }
};

/// Replays `events`, then reports `close` forever.
pub const ScriptedWindow = struct {
    events: []const window.Event,
    next_index: usize = 0,
    presented: usize = 0,
    system_value: window.System = .{ .reduced_motion = true },

    pub fn next(w: *ScriptedWindow, timeout_ms: ?u32) !window.Event {
        _ = timeout_ms;
        if (w.next_index >= w.events.len) return .close;
        defer w.next_index += 1;
        return w.events[w.next_index];
    }

    pub fn present(w: *ScriptedWindow, c: *const render.Canvas) !void {
        std.debug.assert(c.width > 0);
        w.presented += 1;
    }

    pub fn system(w: *const ScriptedWindow) window.System {
        return w.system_value;
    }

    pub fn chooseFolder(
        w: *ScriptedWindow,
        arena: std.mem.Allocator,
        initial: []const u8,
    ) !?[]const u8 {
        _ = w;
        return try std.fmt.allocPrint(arena, "{s}-picked", .{initial});
    }
};

/// Records commands; a wake finishes the running operation successfully.
pub const RecordingApp = struct {
    controller: *screens.Controller,
    commands: Commands = .{},
    finished: bool = false,

    pub const Commands = struct {
        items: [16]screens.Command = undefined, // SAFETY: only [0..len] is read.
        len: usize = 0,

        pub fn get(c: *const Commands, i: usize) screens.Command {
            std.debug.assert(i < c.len);
            return c.items[i];
        }
    };

    pub fn command(app: *RecordingApp, c: screens.Command) !void {
        if (app.commands.len == app.commands.items.len) return error.TestTooManyCommands;
        app.commands.items[app.commands.len] = c;
        app.commands.len += 1;
        if (c == .close) app.finished = true;
    }

    pub fn wake(app: *RecordingApp) !void {
        app.controller.finish(.succeeded);
    }

    pub fn done(app: *const RecordingApp) bool {
        return app.finished;
    }
};
