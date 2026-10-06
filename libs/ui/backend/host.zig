//! The installer app around a window: screen commands to the operation and the system folder
//! dialog, and operation progress back to the controller. The operation runs on its own
//! thread and reports through a `Mailbox`; the UI thread only ever sees copies, coalesced to
//! the latest progress and the final outcome.

const std = @import("std");
const contracts = @import("contracts");
const screens = @import("ui_screens");
const session_mod = @import("session.zig");
const window = @import("window.zig");

const Start = screens.controller.Start;
const Outcome = screens.controller.Outcome;

/// Installs, updates, repairs or uninstalls on a worker thread.
pub const Operation = struct {
    context: *anyopaque,
    /// Starts the work and returns; the worker reports through `mailbox` and must call
    /// `mailbox.finish` exactly once.
    start_fn: *const fn (context: *anyopaque, start: Start, mailbox: *Mailbox) anyerror!void,
    /// Asks a running worker to stop at its next cancellation point.
    cancel_fn: *const fn (context: *anyopaque) void,
};

const max_text = 512;

const Text = struct {
    bytes: [max_text]u8 = undefined, // SAFETY: only [0..len] is read.
    len: usize = 0,

    fn set(t: *Text, value: []const u8) void {
        t.len = @min(value.len, max_text);
        @memcpy(t.bytes[0..t.len], value[0..t.len]);
    }

    fn slice(t: *const Text) []const u8 {
        return t.bytes[0..t.len];
    }
};

const Progress = struct {
    phase: contracts.events.Phase,
    progress: ?f32,
    message: Text = .{},
};

const Finished = struct {
    kind: std.meta.Tag(Outcome),
    code: Text = .{},
    message: Text = .{},
    retryable: bool = false,
};

/// Worker-to-UI channel; every method may be called from any thread.
pub const Mailbox = struct {
    io: std.Io,
    waker: window.Waker,
    mutex: std.Io.Mutex = .init,
    progress: ?Progress = null,
    finished: ?Finished = null,

    pub fn post(m: *Mailbox, event: contracts.events.Event) void {
        if (event.phase == .@"error") return;
        m.mutex.lockUncancelable(m.io);
        var p: Progress = .{ .phase = event.phase, .progress = event.progress };
        p.message.set(event.message orelse "");
        m.progress = p;
        m.mutex.unlock(m.io);
        m.waker.wake();
    }

    pub fn finish(m: *Mailbox, outcome: Outcome) void {
        m.mutex.lockUncancelable(m.io);
        var f: Finished = .{ .kind = outcome };
        if (outcome == .failed) {
            f.code.set(outcome.failed.code);
            f.message.set(outcome.failed.message);
            f.retryable = outcome.failed.retryable;
        }
        m.finished = f;
        m.mutex.unlock(m.io);
        m.waker.wake();
    }

    fn take(m: *Mailbox) struct { ?Progress, ?Finished } {
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const taken = .{ m.progress, m.finished };
        m.progress = null;
        m.finished = null;
        return taken;
    }
};

/// `W` additionally provides `chooseFolder(arena, initial) !?[]const u8`.
pub fn Host(comptime W: type) type {
    return struct {
        const Self = @This();

        win: *W,
        session: *session_mod.Session,
        operation: Operation,
        mailbox: Mailbox,
        /// Copies the controller's ViewModel points at, stable until the next wake.
        detail: Text = .{},
        failure: Finished = .{ .kind = .succeeded },
        running: bool = false,
        closed: bool = false,
        /// The last finished operation, for the process exit code.
        last: ?Outcome = null,

        pub fn command(h: *Self, c: screens.Command) !void {
            switch (c) {
                .start => |s| {
                    h.running = true;
                    h.last = null;
                    try h.operation.start_fn(h.operation.context, s, &h.mailbox);
                },
                .cancel => if (h.running) h.operation.cancel_fn(h.operation.context),
                .launch => {},
                .close => h.closed = true,
                .choose_folder => {
                    const controller = h.session.controller;
                    const arena = controller.arena;
                    const path = try h.win.chooseFolder(arena, controller.vm.location);
                    try controller.folderChosen(path);
                    h.session.invalidate();
                },
            }
        }

        pub fn wake(h: *Self) !void {
            const progress, const finished = h.mailbox.take();
            const controller = h.session.controller;
            if (progress) |p| {
                h.detail.set(p.message.slice());
                controller.onEvent(.{
                    .phase = p.phase,
                    .progress = p.progress,
                    .message = h.detail.slice(),
                });
            }
            if (finished) |f| {
                h.failure = f;
                h.running = false;
                const outcome: Outcome = switch (f.kind) {
                    .succeeded => .succeeded,
                    .canceled => .canceled,
                    .failed => .{ .failed = .{
                        .code = h.failure.code.slice(),
                        .message = h.failure.message.slice(),
                        .retryable = f.retryable,
                    } },
                };
                h.last = outcome;
                controller.finish(outcome);
            }
        }

        pub fn done(h: *const Self) bool {
            return h.closed;
        }
    };
}

test "mailbox coalesces progress and copies strings" {
    const testing = @import("testing.zig");
    var t: testing.Harness = undefined;
    try t.init(std.testing.allocator);
    defer t.deinit();
    const Fake = struct {
        started: ?Start = null,
        canceled: bool = false,
        fn start(context: *anyopaque, s: Start, _: *Mailbox) anyerror!void {
            const f: *@This() = @ptrCast(@alignCast(context));
            f.started = s;
        }
        fn cancel(context: *anyopaque) void {
            const f: *@This() = @ptrCast(@alignCast(context));
            f.canceled = true;
        }
        fn noWake(_: *anyopaque) void {}
    };
    var fake: Fake = .{};
    var win: testing.ScriptedWindow = .{ .events = &.{} };
    var h: Host(testing.ScriptedWindow) = .{
        .win = &win,
        .session = &t.session,
        .operation = .{ .context = &fake, .start_fn = Fake.start, .cancel_fn = Fake.cancel },
        .mailbox = .{
            .io = std.testing.io,
            .waker = .{ .context = &fake, .wake_fn = Fake.noWake },
        },
    };
    t.controller.screen = .options;
    try h.command((try t.session.input(.{ .key = .enter })).?);
    try std.testing.expectEqual(contracts.Scope.user, fake.started.?.scope);
    var message = "first".*;
    h.mailbox.post(.{ .phase = .download, .progress = 0.25, .message = &message });
    h.mailbox.post(.{ .phase = .prepare, .progress = 0.5, .message = "second" });
    message = "XXXXX".*;
    try h.wake();
    try std.testing.expectEqualStrings("second", t.controller.vm.status_detail);
    try std.testing.expectEqual(@as(f32, 0.5), t.controller.vm.progress);
    h.mailbox.finish(
        .{ .failed = .{ .code = "RepoUnavailable", .message = "m", .retryable = true } },
    );
    try h.wake();
    try std.testing.expectEqual(screens.Screen.failure, t.controller.screen);
    try std.testing.expectEqualStrings("RepoUnavailable", t.controller.vm.error_code);
    try std.testing.expect(!h.running);
}
