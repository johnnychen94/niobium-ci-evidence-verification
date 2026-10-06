//! The event loop every native backend runs: window events through the session to screen
//! commands for the app, engine wake-ups back into the controller, and a redraw when anything
//! changed. Animation ticks at ~60 Hz only while the session animates.

const std = @import("std");
const screens = @import("ui_screens");
const session_mod = @import("session.zig");
const window = @import("window.zig");

const Session = session_mod.Session;

pub const frame_ms = 16;

/// `W` provides `next(?u32) !window.Event`, `present(*const Canvas) !void` and
/// `system() window.System`. `App` provides `command(screens.Command) !void` (may finish the
/// app), `wake() !void` (drains engine progress into the controller) and `done() bool`.
pub fn run(io: std.Io, comptime W: type, win: *W, s: *Session, app: anytype) !void {
    const start = std.Io.Clock.awake.now(io).toMilliseconds();
    var dirty = true;
    // loop-bound: one iteration per window event until the app finishes.
    while (!app.done()) {
        if (dirty) {
            const now = std.Io.Clock.awake.now(io).toMilliseconds() - start;
            try win.present(try s.draw(@intCast(@max(now, 0))));
            dirty = false;
        }
        const event = try win.next(if (s.animating()) frame_ms else null);
        dirty = try dispatch(W, win, s, app, event);
    }
}

/// Whether the window must be redrawn.
fn dispatch(comptime W: type, win: *W, s: *Session, app: anytype, event: window.Event) !bool {
    switch (event) {
        .input => |e| if (try s.input(e)) |command| try app.command(command),
        .close => if (s.closeRequested()) |command| try app.command(command),
        .wake => {
            try app.wake();
            s.invalidate();
        },
        .scale => |scale| s.setScale(scale),
        .appearance => try s.setSystem(win.system()),
        .resize => {},
        .redraw => return true,
        .timeout => return s.animating(),
    }
    return true;
}

test "driver drives a scripted window to the app's finish" {
    const testing = @import("testing.zig");
    var t: testing.Harness = undefined;
    try t.init(std.testing.allocator);
    defer t.deinit();
    var win: testing.ScriptedWindow = .{ .events = &.{
        .{ .input = .{ .key = .enter } },
        .{ .input = .{ .key = .enter } },
        .wake,
        .close,
    } };
    var app: testing.RecordingApp = .{ .controller = &t.controller };
    try run(std.testing.io, testing.ScriptedWindow, &win, &t.session, &app);
    try std.testing.expectEqual(@as(usize, 2), app.commands.len);
    try std.testing.expect(app.commands.get(0) == .start);
    try std.testing.expect(app.commands.get(1) == .close);
    try std.testing.expect(win.presented >= 3);
}
