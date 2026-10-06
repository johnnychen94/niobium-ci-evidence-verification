//! Progress events (docs/spec/cli-v1.md#events). The engine reports phases through a `Sink`; the
//! CLI writes them as JSON lines, the C ABI forwards the same bytes, the GUI maps them to its
//! view.

const std = @import("std");
const contracts = @import("contracts");
const core = @import("core");

pub const Event = contracts.events.Event;
pub const Phase = contracts.events.Phase;

pub const Sink = struct {
    context: ?*anyopaque = null,
    emit_fn: ?*const fn (context: ?*anyopaque, event: Event) void = null,

    /// A sink calling `f(ptr, event)`; the only place the context pointer is type-erased.
    pub fn bind(
        comptime T: type,
        ptr: *T,
        comptime f: fn (target: *T, event: Event) void,
    ) Sink {
        const Thunk = struct {
            fn call(context: ?*anyopaque, event: Event) void {
                const target: *T = @ptrCast(@alignCast(context.?));
                f(target, event);
            }
        };
        return .{ .context = ptr, .emit_fn = Thunk.call };
    }

    pub fn emit(s: Sink, event: Event) void {
        const f = s.emit_fn orelse return;
        f(s.context, event);
    }

    pub fn phase(s: Sink, p: Phase) void {
        s.emit(.{ .phase = p });
    }

    pub fn progress(s: Sink, p: Phase, done: u64, total: u64) void {
        const ratio: f32 = if (total == 0) 1 else @floatCast(
            @as(f64, @floatFromInt(done)) / @as(f64, @floatFromInt(total)),
        );
        s.emit(.{ .phase = p, .progress = ratio });
    }

    /// The terminal `error` event: stable code, exit code, and the error name as message.
    pub fn failure(s: Sink, err_name: []const u8) void {
        var buffer: [128]u8 = undefined; // SAFETY: fixed writer scratch.
        var writer: std.Io.Writer = .fixed(&buffer);
        const text = if (core.exit_code.eventCode(&writer, err_name)) |_|
            writer.buffered()
        else |_|
            "internal.unknown";
        const code = core.exit_code.fromName(err_name);
        s.emit(.{
            .phase = .@"error",
            .code = text,
            .message = err_name,
            .exit_code = @backingInt(code),
        });
    }
};
