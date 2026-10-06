//! App Bootstrap v1 client (docs/spec/bootstrap-v1.md): runs `<entrypoint>
//! --installer-bootstrap-v1` as the invoking user with a minimal environment, writes one request
//! to stdin, reads one bounded JSON line from stdout, and kills the child at the deadline.

const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts");

const wire = contracts.bootstrap;
const Environ = std.process.Environ;

pub const Error = error{
    BootstrapSpawnFailed,
    BootstrapTimeout,
    BootstrapFailed,
    BootstrapBadResponse,
    BootstrapRejected,
    OutOfMemory,
};

pub const Options = struct {
    timeout_ms: u32 = 120_000,
    max_output: u32 = wire.max_response_bytes,
    /// Source of the inherited variables; null gives the child an empty environment.
    parent_env: ?*const Environ.Map = null,
};

pub const Result = struct {
    message: ?[]const u8 = null,
};

/// Variables the child inherits (docs/spec/bootstrap-v1.md#invocation); everything else is dropped.
pub const inherited = [_][]const u8{
    "PATH", "HOME", "USERPROFILE", "LANG", "TMPDIR", "TEMP", "TMP", "SystemRoot",
};

pub fn minimalEnv(arena: std.mem.Allocator, parent: ?*const Environ.Map) Error!Environ.Map {
    var env: Environ.Map = .init(arena);
    const source = parent orelse return env;
    for (inherited) |name| {
        if (source.get(name)) |value| try env.put(name, value);
    }
    return env;
}

pub fn run(
    io: std.Io,
    arena: std.mem.Allocator,
    exe: []const u8,
    request: wire.Request,
    options: Options,
) Error!Result {
    const payload = try wire.encodeRequest(arena, request);
    var env = try minimalEnv(arena, options.parent_env);
    var child = std.process.spawn(io, .{
        .argv = &.{ exe, wire.flag },
        .environ_map = &env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch return error.BootstrapSpawnFailed;
    var watchdog: Watchdog = .{
        .io = io,
        .id = child.id.?,
        .deadline_ms = nowMs(io) + options.timeout_ms,
    };
    const thread = std.Thread.spawn(.{}, Watchdog.loop, .{&watchdog}) catch {
        child.kill(io);
        return error.BootstrapSpawnFailed;
    };
    const output = exchange(io, arena, &child, payload, options.max_output);
    // A child still writing past the limit would never exit on its own.
    if (output) |_| {} else |_| terminate(child.id.?);
    watchdog.done.store(true, .release);
    thread.join();
    const term = child.wait(io) catch return error.BootstrapFailed;
    if (watchdog.fired.load(.acquire)) return error.BootstrapTimeout;
    const bytes = try output;
    if (!term.success()) return error.BootstrapFailed;
    return decide(arena, bytes);
}

/// Request in, then stdout until EOF. The request is far below any pipe buffer, so writing it
/// before reading cannot deadlock.
fn exchange(
    io: std.Io,
    arena: std.mem.Allocator,
    child: *std.process.Child,
    payload: []const u8,
    max_output: u32,
) Error![]const u8 {
    if (child.stdin) |stdin| {
        var buffer: [512]u8 = undefined; // SAFETY: writer scratch.
        var writer = stdin.writerStreaming(io, &buffer);
        // The child may exit without reading; its verdict comes from stdout and the exit code.
        writer.interface.writeAll(payload) catch |err| logIgnored(err);
        writer.interface.writeByte('\n') catch |err| logIgnored(err);
        writer.interface.flush() catch |err| logIgnored(err);
        stdin.close(io);
        child.stdin = null;
    }
    const stdout = child.stdout orelse return error.BootstrapBadResponse;
    var buffer: [4096]u8 = undefined; // SAFETY: reader scratch.
    var limit_buffer: [4096]u8 = undefined; // SAFETY: limited reader scratch.
    var reader = stdout.readerStreaming(io, &buffer);
    var limited = reader.interface.limited(.limited64(@as(u64, max_output) + 1), &limit_buffer);
    var out: std.Io.Writer.Allocating = .init(arena);
    const count = limited.interface.streamRemaining(&out.writer) catch |err| switch (err) {
        error.ReadFailed => return error.BootstrapBadResponse,
        error.WriteFailed => return error.OutOfMemory,
    };
    if (count > max_output) return error.BootstrapBadResponse;
    return out.written();
}

fn logIgnored(err: std.Io.Writer.Error) void {
    std.log.debug("bootstrap stdin: {t}", .{err});
}

fn decide(arena: std.mem.Allocator, bytes: []const u8) Error!Result {
    const line = std.mem.trim(u8, bytes, " \t\r\n");
    if (line.len == 0 or std.mem.findScalar(u8, line, '\n') != null) {
        return error.BootstrapBadResponse;
    }
    const response = wire.decodeResponse(arena, line) catch return error.BootstrapBadResponse;
    if (response.protocol != wire.protocol) return error.BootstrapBadResponse;
    return switch (response.status) {
        .ok => .{ .message = response.message },
        .@"error" => error.BootstrapRejected,
    };
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toMilliseconds();
}

const Watchdog = struct {
    io: std.Io,
    id: std.process.Child.Id,
    deadline_ms: i64,
    done: std.atomic.Value(bool) = .init(false),
    fired: std.atomic.Value(bool) = .init(false),

    const tick: std.Io.Duration = .fromMilliseconds(10);

    fn loop(w: *Watchdog) void {
        // loop-bound: ends at the deadline, or earlier when the exchange finishes.
        while (!w.done.load(.acquire)) {
            if (nowMs(w.io) >= w.deadline_ms) {
                w.fired.store(true, .release);
                terminate(w.id);
                return;
            }
            w.io.sleep(tick, .awake) catch return;
        }
    }
};

/// Forcible termination without reaping: the exchange sees EOF, then `wait` reaps the child.
fn terminate(id: std.process.Child.Id) void {
    if (builtin.os.tag == .windows) {
        const status = std.os.windows.ntdll.NtTerminateProcess(id, .TIMEOUT);
        if (status != .SUCCESS) std.log.debug("bootstrap terminate: {t}", .{status});
    } else {
        std.posix.kill(id, .KILL) catch |err| std.log.debug("bootstrap kill: {t}", .{err});
    }
}

test {
    _ = @import("bootstrap_test.zig");
}
