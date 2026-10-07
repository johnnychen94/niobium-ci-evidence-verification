//! Bounded capture shared by the suite runner and lifecycle subprocesses.
const std = @import("std");
const limits = @import("model.zig").limits;
pub const Result = struct {
    code: u8 = 255,
    reason: []const u8 = "",
    stdout: []const u8 = "",
    stderr: []const u8 = "",
};
pub const Options = struct {
    argv: []const []const u8,
    env: ?*const std.process.Environ.Map = null,
    timeout_ms: u32 = limits.test_timeout_ms,
    output_bytes: u32 = limits.test_output_bytes,
};

pub fn run(a: std.mem.Allocator, io: std.Io, options: Options) !Result {
    var child = try std.process.spawn(io, .{
        .argv = options.argv,
        .environ_map = options.env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    // SAFETY: MultiReader.init initializes both structures before they are read.
    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined; // SAFETY: init fills it below.
    reader.init(a, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer {
        child.kill(io);
        reader.deinit();
    }
    var context: Capture = .{ .io = io, .child = &child, .reader = &reader, .options = options };
    const Event = union(enum) { done: void, deadline: std.Io.Cancelable!void };
    var events: [2]Event = undefined; // SAFETY: Select owns and initializes queue entries.
    var select: std.Io.Select(Event) = .init(io, &events);
    try select.concurrent(.done, Capture.collect, .{&context});
    defer {
        const pending = select.cancel();
        _ = pending;
    }
    select.async(.deadline, std.Io.sleep, .{
        io, std.Io.Duration.fromMilliseconds(options.timeout_ms), .awake,
    });
    switch (try select.await()) {
        .done => {},
        .deadline => {
            const pending = select.cancel();
            _ = pending;
            context.result.reason = "Timeout";
        },
    }
    const stdout = try reader.toOwnedSlice(0);
    errdefer a.free(stdout);
    const stderr = try reader.toOwnedSlice(1);
    context.result.stdout = stdout;
    context.result.stderr = stderr;
    return context.result;
}

const Capture = struct {
    io: std.Io,
    child: *std.process.Child,
    reader: *std.Io.File.MultiReader,
    options: Options,
    result: Result = .{},

    fn collect(c: *Capture) void {
        // Windows read completions belong to this submitting thread. Join pending reads here
        // before it returns and the caller transfers the buffers.
        defer {
            c.child.kill(c.io);
            c.reader.batch.cancel(c.io);
        }
        c.capture() catch |err| {
            c.result.reason = @errorName(err);
        };
    }

    fn capture(c: *Capture) !void {
        const timeout: std.Io.Timeout = .{ .duration = .{
            .raw = .fromMilliseconds(c.options.timeout_ms),
            .clock = .awake,
        } };
        const deadline = timeout.toDeadline(c.io);
        // loop-bound: deadline and per-stream byte limits bound this read loop.
        while (c.reader.fill(4096, deadline)) |_| {
            for (0..2) |index| {
                if (c.reader.reader(index).buffered().len > c.options.output_bytes)
                    return error.StreamTooLong;
            }
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        }
        try c.reader.checkAnyError();
        const term = try c.child.wait(c.io);
        c.result.code = switch (term) {
            .exited => |code| code,
            else => 255,
        };
        if (c.result.code != 0) c.result.reason = "SubprocessFailed";
    }
};

test "N1-AC-20 capture preserves partial streams on deadline and output overflow" {
    const windows = @import("builtin").os.tag == .windows;
    const a = std.testing.allocator;
    const timed_argv: []const []const u8 = if (windows) &.{
        "powershell.exe",
        "-NoProfile",
        "-NonInteractive",
        "-Command",
        "[Console]::Out.Write('out'); [Console]::Error.Write('err'); Start-Sleep -Seconds 10",
    } else &.{ "/bin/sh", "-c", "printf out; printf err >&2; exec sleep 10" };
    const started = std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
    const timed = try run(a, std.testing.io, .{
        .argv = timed_argv,
        .timeout_ms = if (windows) 5000 else 100,
    });
    defer a.free(timed.stdout);
    defer a.free(timed.stderr);
    const elapsed = std.Io.Clock.awake.now(std.testing.io).toMilliseconds() - started;
    try std.testing.expect(elapsed < if (windows) @as(i64, 8000) else 3000);
    try std.testing.expectEqualStrings("Timeout", timed.reason);
    try std.testing.expectEqualStrings("out", timed.stdout);
    try std.testing.expectEqualStrings("err", timed.stderr);
    const large = try run(a, std.testing.io, .{
        .argv = if (windows) &.{
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            "[Console]::Out.Write('x' * 8192)",
        } else &.{"/usr/bin/yes"},
        .output_bytes = 100,
    });
    defer a.free(large.stdout);
    defer a.free(large.stderr);
    try std.testing.expectEqualStrings("StreamTooLong", large.reason);
}
