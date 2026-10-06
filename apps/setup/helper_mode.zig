//! `setup --priv-helper-v1` (ADR-0007, docs/spec/ipc-v1.md). The policy (machine install base,
//! integration directories, own executable) comes from this process and the framework's path
//! policy, never from the broker. stdout carries IPC frames, so nothing else may write to it.

const std = @import("std");
const engine = @import("engine");
const planner = @import("planner");
const platform = @import("platform");
const privilege = @import("privilege");
const core = @import("core");

const frame_buffer = 64 * 1024;

fn code(value: core.ExitCode) u8 {
    return @backingInt(value);
}

/// `argv` without the program name, starting at `--priv-helper-v1`.
pub fn serve(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    argv: []const []const u8,
    environ: *const std.process.Environ.Map,
) u8 {
    const args = privilege.parseHelperArgs(argv) catch return code(.usage);
    const env = engine.runtime.envFrom(environ);
    var host: platform.Host = .init(io, .{ .env = env });
    const base = planner.paths.machineInstallBase(engine.nativeOs(), env) catch
        return code(.permission);
    const dirs = host.machineIntegrationDirs(arena) catch return code(.permission);
    const self_exe = std.process.executablePathAlloc(io, arena) catch return code(.permission);
    const stream = privilege.elevate.helperStream(io, arena, args.pipe) catch
        return code(.permission);
    const in_buffer = arena.alloc(u8, frame_buffer) catch return code(.internal);
    const out_buffer = arena.alloc(u8, frame_buffer) catch return code(.internal);
    var reader = stream.input.readerStreaming(io, in_buffer);
    var writer = stream.output.writerStreaming(io, out_buffer);
    const outcome = privilege.helper.serve(
        io,
        gpa,
        &reader.interface,
        &writer.interface,
        .{ .tx = args.tx, .nonce = args.nonce },
        .{ .install_bases = &.{base}, .integration_dirs = dirs, .self_exe = self_exe },
        host.platform(),
    );
    std.log.debug("privilege helper: {t}", .{outcome});
    return if (outcome == .bye) 0 else code(.permission);
}
