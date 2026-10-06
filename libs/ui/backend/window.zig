//! What every native window backend (AppKit, Win32, X11) reports and accepts. Coordinates and
//! sizes are device pixels; the backend converts from points or logical units. Backends queue
//! events from their callbacks into a bounded `Queue` and never propagate errors through an OS
//! callback (wndproc, ObjC method, X11 reply): a failure is stored and returned by `next`.

const std = @import("std");
const ui = @import("ui_core");
const tokens = @import("ui_tokens");

pub const Size = ui.geometry.Size;

pub const Event = union(enum) {
    input: ui.input.Event,
    /// New client size in device pixels.
    resize: Size,
    /// New device pixels per 100 logical pixels (moved to another display).
    scale: u16,
    /// System appearance changed: query `system()` again.
    appearance,
    /// The window's close box, Cmd+Q / Alt+F4, or the window manager's delete request.
    close,
    /// `Waker.wake` was called from another thread.
    wake,
    /// The window needs its pixels again (expose).
    redraw,
    /// `next` waited its full timeout.
    timeout,
};

/// System settings that pick the theme and motion.
pub const System = struct {
    dark: bool = false,
    high_contrast: bool = false,
    reduced_motion: bool = false,

    pub fn theme(s: System) tokens.ThemeName {
        return tokens.themeName(s.dark, s.high_contrast);
    }
};

pub const Options = struct {
    title: []const u8,
    /// Logical client size.
    width: i32,
    height: i32,
};

/// Wakes the UI thread's `next` from any thread. Must stay valid while the window is open.
pub const Waker = struct {
    context: *anyopaque,
    wake_fn: *const fn (context: *anyopaque) void,

    pub fn wake(w: Waker) void {
        w.wake_fn(w.context);
    }
};

/// Bounded FIFO filled by OS callbacks on the UI thread. When full, pointer moves are dropped
/// first (the next move supersedes them); other events overwrite nothing and are dropped
/// last, so a flood of moves never loses a click.
pub const Queue = struct {
    items: [capacity]Event = undefined, // SAFETY: only [head, head + len) is read.
    head: u8 = 0,
    len: u8 = 0,

    pub const capacity = 64;

    pub fn push(q: *Queue, event: Event) void {
        if (q.len == capacity) {
            if (isMove(event)) return;
            if (!q.dropMove()) return;
        }
        q.items[(@as(usize, q.head) + q.len) % capacity] = event;
        q.len += 1;
    }

    pub fn pop(q: *Queue) ?Event {
        if (q.len == 0) return null;
        const event = q.items[q.head];
        q.head = @intCast((@as(usize, q.head) + 1) % capacity);
        q.len -= 1;
        return event;
    }

    fn isMove(event: Event) bool {
        return event == .input and event.input == .pointer_move;
    }

    /// Removes the oldest pointer move; false when there is none.
    fn dropMove(q: *Queue) bool {
        var i: usize = 0;
        while (i < q.len) : (i += 1) {
            const at = (@as(usize, q.head) + i) % capacity;
            if (!isMove(q.items[at])) continue;
            var j = i;
            while (j + 1 < q.len) : (j += 1) {
                const dst = (@as(usize, q.head) + j) % capacity;
                q.items[dst] = q.items[(dst + 1) % capacity];
            }
            q.len -= 1;
            return true;
        }
        return false;
    }
};

/// Device pixels per 100 logical pixels for a DPI (96 = 100%), in 25% steps, 100..400.
pub fn scaleForDpi(dpi: u32) u16 {
    const percent = (dpi * 100 + 48) / 96;
    const stepped = (percent + 12) / 25 * 25;
    return @intCast(std.math.clamp(stepped, 100, 400));
}

test "queue keeps clicks when flooded with moves" {
    var q: Queue = .{};
    q.push(.{ .input = .{ .pointer_down = .{ .x = 1, .y = 1 } } });
    for (0..Queue.capacity * 2) |i| {
        q.push(.{ .input = .{ .pointer_move = .{ .x = @intCast(i), .y = 0 } } });
    }
    q.push(.{ .input = .{ .pointer_up = .{ .x = 1, .y = 1 } } });
    q.push(.close);
    try std.testing.expectEqual(@as(u8, Queue.capacity), q.len);
    try std.testing.expect(q.pop().?.input == .pointer_down);
    var last: ?Event = null;
    while (q.pop()) |e| last = e;
    try std.testing.expect(last.? == .close);
}

test "dpi maps to 25 percent scale steps" {
    try std.testing.expectEqual(@as(u16, 100), scaleForDpi(96));
    try std.testing.expectEqual(@as(u16, 125), scaleForDpi(120));
    try std.testing.expectEqual(@as(u16, 150), scaleForDpi(144));
    try std.testing.expectEqual(@as(u16, 200), scaleForDpi(192));
    try std.testing.expectEqual(@as(u16, 100), scaleForDpi(0));
}
