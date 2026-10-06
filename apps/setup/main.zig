//! `setup`: GUI by default, CLI subcommands (docs/spec/cli-v1.md), maintainer mode (the copy in
//! `<root>/maintainer/`) and the privilege helper (`--priv-helper-v1`). Process assembly only.

const std = @import("std");
const core = @import("core");
const product_config = @import("product_config");
const cli = @import("cli.zig");
const frontend = @import("frontend.zig");
const gui = @import("gui.zig");
const helper_mode = @import("helper_mode.zig");

pub const panic = std.debug.FullPanic(core.crash.panic);
pub const debug = struct {
    pub const handleSegfault = core.crash.handleSegfault;
};

comptime {
    _ = @import("ui_render");
}

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const internal = @backingInt(core.ExitCode.internal);
    const raw = init.minimal.args.toSlice(arena) catch return internal;
    const argv = arena.alloc([]const u8, raw.len -| 1) catch return internal;
    for (argv, raw[1..]) |*dst, src| dst.* = src;

    if (argv.len > 0 and std.mem.eql(u8, argv[0], "--priv-helper-v1")) {
        return helper_mode.serve(io, init.gpa, arena, argv, init.environ_map);
    }

    var out_buffer: [4096]u8 = undefined; // SAFETY: writer scratch.
    var err_buffer: [1024]u8 = undefined; // SAFETY: writer scratch.
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    var stderr = std.Io.File.stderr().writerStreaming(io, &err_buffer);
    const command = cli.parse(arena, argv) catch |err| {
        stderr.interface.print("setup: {t}\n\n{s}", .{ err, cli.usage }) catch return internal;
        stderr.interface.flush() catch return internal;
        return @backingInt(core.exit_code.fromError(err));
    };
    var process: frontend.Process = .{
        .io = io,
        .gpa = init.gpa,
        .arena = arena,
        .environ = init.environ_map,
        .self_exe = std.process.executablePathAlloc(io, arena) catch null,
        .stdout = &stdout.interface,
        .stderr = &stderr.interface,
        .embedded_config = product_config.bytes,
    };
    if (command.verb == .gui and gui.available(init.environ_map)) return gui.run(&process);
    return frontend.execute(&process, command);
}

test {
    _ = cli;
    _ = frontend;
    _ = gui;
    _ = helper_mode;
    _ = @import("frontend_test.zig");
    _ = @import("gui_test.zig");
}
