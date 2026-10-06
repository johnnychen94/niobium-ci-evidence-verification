//! Starts `setup --priv-helper-v1` with elevated rights and connects the IPC stream
//! (ADR-0007): Linux `pkexec` (fallback `sudo`), macOS Authorization Services prompt,
//! Windows `ShellExecuteExW` "runas" plus a named pipe whose client pid is verified.
//! `.direct` spawns the helper unelevated over stdio; tests and e2e use it.

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform");
const broker_mod = @import("broker.zig");

const Allocator = std.mem.Allocator;
const File = std.Io.File;

pub const Method = enum { direct, pkexec, sudo, macos_authorization, windows_runas };

pub const Error = error{
    PrivilegeDenied,
    PrivilegeUnavailable,
    PrivilegeHelperLost,
    OutOfMemory,
};

pub fn defaultMethod() Method {
    return switch (builtin.os.tag) {
        .macos => .macos_authorization,
        .windows => .windows_runas,
        else => .pkexec,
    };
}

const buffer_bytes = 64 * 1024;

/// A running helper and the two ends of its stream.
pub const Helper = struct {
    io: std.Io,
    child: ?std.process.Child = null,
    input: File,
    output: File,
    /// Same handle for both directions (macOS socket, Windows pipe).
    duplex: bool = false,
    read_buffer: [buffer_bytes]u8 = undefined, // SAFETY: owned by `reader`.
    write_buffer: [buffer_bytes]u8 = undefined, // SAFETY: owned by `writer`.
    reader: File.Reader = undefined, // SAFETY: set by `connect` before use.
    writer: File.Writer = undefined, // SAFETY: set by `connect` before use.

    fn connect(h: *Helper) void {
        h.reader = h.input.readerStreaming(h.io, &h.read_buffer);
        h.writer = h.output.writerStreaming(h.io, &h.write_buffer);
    }

    pub fn broker(h: *Helper, gpa: Allocator, session: broker_mod.Session) broker_mod.Broker {
        return .init(gpa, h.io, &h.reader.interface, &h.writer.interface, session);
    }

    /// Close our ends (the helper sees EOF if it has not said bye) and reap it.
    pub fn finish(h: *Helper) void {
        h.output.close(h.io);
        if (!h.duplex) h.input.close(h.io);
        if (h.child) |*child| {
            // Failures were already reported over IPC or as PrivilegeHelperLost.
            const term = child.wait(h.io) catch |err| {
                std.log.debug("privilege helper wait failed: {t}", .{err});
                return;
            };
            std.log.debug("privilege helper exited: {any}", .{term});
        }
    }
};

fn helperArgs(
    arena: Allocator,
    self_exe: []const u8,
    session: broker_mod.Session,
    prefix: []const []const u8,
) Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, prefix);
    try argv.appendSlice(arena, &.{
        self_exe,
        "--priv-helper-v1",
        "--tx",
        session.tx,
        "--nonce",
        session.nonce,
    });
    return argv.items;
}

/// `helper` must stay at a stable address (its reader/writer point into it).
pub fn spawn(
    helper: *Helper,
    io: std.Io,
    arena: Allocator,
    method: Method,
    self_exe: []const u8,
    session: broker_mod.Session,
) Error!void {
    // SAFETY: every method below assigns input and output before returning without error.
    helper.* = .{ .io = io, .input = undefined, .output = undefined };
    switch (method) {
        .direct => try spawnStdio(helper, try helperArgs(arena, self_exe, session, &.{})),
        .pkexec => try spawnStdio(helper, try helperArgs(arena, self_exe, session, &.{"pkexec"})),
        .sudo => try spawnStdio(
            helper,
            try helperArgs(arena, self_exe, session, &.{ "sudo", "--" }),
        ),
        .macos_authorization => {
            if (comptime builtin.os.tag != .macos) return error.PrivilegeUnavailable;
            try macos.spawn(helper, arena, self_exe, session);
        },
        .windows_runas => {
            if (comptime builtin.os.tag != .windows) return error.PrivilegeUnavailable;
            try windows.spawn(helper, arena, self_exe, session);
        },
    }
    helper.connect();
}

fn spawnStdio(helper: *Helper, argv: []const []const u8) Error!void {
    var child = std.process.spawn(helper.io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => error.PrivilegeUnavailable,
        error.AccessDenied, error.PermissionDenied => error.PrivilegeDenied,
        else => error.PrivilegeHelperLost,
    };
    helper.input = child.stdout.?;
    helper.output = child.stdin.?;
    child.stdout = null;
    child.stdin = null;
    helper.child = child;
}

const macos = struct {
    const AuthorizationRef = *opaque {};
    const errAuthorizationSuccess: i32 = 0;
    const errAuthorizationCanceled: i32 = -60006;
    const kAuthorizationFlagDefaults: u32 = 0;

    extern fn AuthorizationCreate(
        rights: ?*const anyopaque,
        environment: ?*const anyopaque,
        flags: u32,
        authorization: *?AuthorizationRef,
    ) callconv(.c) i32;
    extern fn AuthorizationExecuteWithPrivileges(
        authorization: AuthorizationRef,
        path: [*:0]const u8,
        options: u32,
        arguments: [*:null]const ?[*:0]const u8,
        pipe: *?*anyopaque,
    ) callconv(.c) i32;
    extern fn AuthorizationFree(authorization: AuthorizationRef, flags: u32) callconv(.c) i32;
    extern "c" fn fileno(stream: *anyopaque) c_int;

    /// The prompt names the calling app; the returned stream is a socket wired to the tool's
    /// stdin and stdout.
    fn spawn(
        helper: *Helper,
        arena: Allocator,
        self_exe: []const u8,
        session: broker_mod.Session,
    ) Error!void {
        var auth: ?AuthorizationRef = null;
        if (AuthorizationCreate(null, null, kAuthorizationFlagDefaults, &auth) != 0) {
            return error.PrivilegeUnavailable;
        }
        // lint-allow(no-discard-call): freeing the authorization reference cannot fail usefully.
        defer _ = AuthorizationFree(auth.?, kAuthorizationFlagDefaults);
        const path = try arena.dupeSentinel(u8, self_exe, 0);
        const args = [_][]const u8{
            "--priv-helper-v1", "--tx", session.tx, "--nonce", session.nonce,
        };
        var argv: [args.len + 1:null]?[*:0]const u8 = @splat(null);
        for (args, 0..) |arg, i| argv[i] = try arena.dupeSentinel(u8, arg, 0);
        var pipe: ?*anyopaque = null;
        const status = AuthorizationExecuteWithPrivileges(auth.?, path, 0, &argv, &pipe);
        switch (status) {
            errAuthorizationSuccess => {},
            errAuthorizationCanceled => return error.PrivilegeDenied,
            else => return error.PrivilegeUnavailable,
        }
        const fd = fileno(pipe orelse return error.PrivilegeHelperLost);
        if (fd < 0) return error.PrivilegeHelperLost;
        helper.input = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        helper.output = helper.input;
        helper.duplex = true;
    }
};

const windows = struct {
    const w = std.os.windows;
    const HANDLE = w.HANDLE;

    const ShellExecuteInfo = extern struct {
        cbSize: u32,
        fMask: u32,
        hwnd: ?HANDLE = null,
        lpVerb: ?[*:0]const u16 = null,
        lpFile: ?[*:0]const u16 = null,
        lpParameters: ?[*:0]const u16 = null,
        lpDirectory: ?[*:0]const u16 = null,
        nShow: i32 = 0,
        hInstApp: ?HANDLE = null,
        lpIDList: ?*anyopaque = null,
        lpClass: ?[*:0]const u16 = null,
        hkeyClass: ?HANDLE = null,
        dwHotKey: u32 = 0,
        hIconOrMonitor: ?HANDLE = null,
        hProcess: ?HANDLE = null,
    };

    const SEE_MASK_NOCLOSEPROCESS: u32 = 0x40;
    const SEE_MASK_NOASYNC: u32 = 0x100;
    const PIPE_ACCESS_DUPLEX: u32 = 0x3;
    const FILE_FLAG_FIRST_PIPE_INSTANCE: u32 = 0x00080000;
    const PIPE_NOWAIT: u32 = 0x1;
    const PIPE_REJECT_REMOTE_CLIENTS: u32 = 0x8;
    const ERROR_PIPE_CONNECTED: u32 = 535;
    const ERROR_CANCELLED: u32 = 1223;
    const WAIT_TIMEOUT: u32 = 0x102;
    const connect_timeout_ms: u32 = 120_000;
    const poll_ms: u32 = 50;

    extern "shell32" fn ShellExecuteExW(info: *ShellExecuteInfo) callconv(.winapi) c_int;
    extern "kernel32" fn CreateNamedPipeW(
        name: [*:0]const u16,
        open_mode: u32,
        pipe_mode: u32,
        max_instances: u32,
        out_buffer: u32,
        in_buffer: u32,
        timeout: u32,
        security: ?*anyopaque,
    ) callconv(.winapi) HANDLE;
    extern "kernel32" fn ConnectNamedPipe(
        pipe: HANDLE,
        overlapped: ?*anyopaque,
    ) callconv(.winapi) c_int;
    extern "kernel32" fn SetNamedPipeHandleState(
        pipe: HANDLE,
        mode: ?*u32,
        max_collection: ?*u32,
        timeout: ?*u32,
    ) callconv(.winapi) c_int;
    extern "kernel32" fn GetNamedPipeClientProcessId(
        pipe: HANDLE,
        pid: *u32,
    ) callconv(.winapi) c_int;
    extern "kernel32" fn GetProcessId(process: HANDLE) callconv(.winapi) u32;
    extern "kernel32" fn WaitForSingleObject(handle: HANDLE, ms: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;

    fn wide(arena: Allocator, text: []const u8) Error![:0]const u16 {
        return std.unicode.wtf8ToWtf16LeAllocZ(arena, text) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.PrivilegeUnavailable,
        };
    }

    pub fn pipeName(arena: Allocator, session: broker_mod.Session) Error![]const u8 {
        const pipe = "\\\\.\\pipe\\niobium-{s}-{s}";
        return std.fmt.allocPrint(arena, pipe, .{ session.tx, session.nonce });
    }

    fn spawn(
        helper: *Helper,
        arena: Allocator,
        self_exe: []const u8,
        session: broker_mod.Session,
    ) Error!void {
        const name = try pipeName(arena, session);
        const pipe = CreateNamedPipeW(
            try wide(arena, name),
            PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
            PIPE_NOWAIT | PIPE_REJECT_REMOTE_CLIENTS,
            1,
            buffer_bytes,
            buffer_bytes,
            0,
            null,
        );
        if (pipe == w.INVALID_HANDLE_VALUE) return error.PrivilegeUnavailable;
        errdefer w.CloseHandle(pipe);
        const params = try std.fmt.allocPrint(
            arena,
            "--priv-helper-v1 --tx {s} --nonce {s} --pipe {s}",
            .{ session.tx, session.nonce, name },
        );
        var info: ShellExecuteInfo = .{
            .cbSize = @sizeOf(ShellExecuteInfo),
            .fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC,
            .lpVerb = try wide(arena, "runas"),
            .lpFile = try wide(arena, self_exe),
            .lpParameters = try wide(arena, params),
        };
        if (ShellExecuteExW(&info) == 0) {
            if (GetLastError() == ERROR_CANCELLED) return error.PrivilegeDenied;
            return error.PrivilegeUnavailable;
        }
        const process = info.hProcess orelse return error.PrivilegeHelperLost;
        defer w.CloseHandle(process);
        var waited: u32 = 0;
        while (ConnectNamedPipe(pipe, null) == 0 and GetLastError() != ERROR_PIPE_CONNECTED) {
            if (WaitForSingleObject(
                process,
                poll_ms,
            ) != WAIT_TIMEOUT) return error.PrivilegeHelperLost;
            waited += poll_ms;
            if (waited >= connect_timeout_ms) return error.PrivilegeHelperLost;
        }
        // Only the process we started may hold the other end.
        var client: u32 = 0;
        if (GetNamedPipeClientProcessId(pipe, &client) == 0 or client != GetProcessId(process)) {
            return error.PrivilegeHelperLost;
        }
        var mode: u32 = 0; // PIPE_WAIT | PIPE_READMODE_BYTE
        if (SetNamedPipeHandleState(pipe, &mode, null, null) == 0) return error.PrivilegeHelperLost;
        helper.input = .{ .handle = pipe, .flags = .{ .nonblocking = false } };
        helper.output = helper.input;
        helper.duplex = true;
    }

    extern "kernel32" fn CreateFileW(
        name: [*:0]const u16,
        access: u32,
        share: u32,
        security: ?*anyopaque,
        disposition: u32,
        flags: u32,
        template: ?*anyopaque,
    ) callconv(.winapi) HANDLE;

    /// Helper side: open the broker's pipe.
    pub fn open(arena: Allocator, name: []const u8) Error!File {
        const prefix = "\\\\.\\pipe\\niobium-";
        if (!std.mem.startsWith(u8, name, prefix)) return error.PrivilegeUnavailable;
        const generic_read_write: u32 = 0xC0000000;
        const open_existing: u32 = 3;
        const handle = CreateFileW(
            try wide(arena, name),
            generic_read_write,
            0,
            null,
            open_existing,
            0,
            null,
        );
        if (handle == w.INVALID_HANDLE_VALUE) return error.PrivilegeHelperLost;
        return .{ .handle = handle, .flags = .{ .nonblocking = false } };
    }
};

/// Helper-side stream: stdio, or the broker's named pipe on Windows.
pub fn helperStream(
    io: std.Io,
    arena: Allocator,
    pipe: ?[]const u8,
) Error!struct { input: File, output: File } {
    _ = io;
    if (pipe) |name| {
        if (comptime builtin.os.tag != .windows) return error.PrivilegeUnavailable;
        const file = try windows.open(arena, name);
        return .{ .input = file, .output = file };
    }
    return .{ .input = .stdin(), .output = .stdout() };
}

test "helper argv carries the session" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const argv = try helperArgs(
        arena.allocator(),
        "/x/setup",
        .{ .tx = "tx-1-ab", .nonce = "00" },
        &.{"pkexec"},
    );
    try std.testing.expectEqualStrings("pkexec", argv[0]);
    try std.testing.expectEqualStrings("--priv-helper-v1", argv[2]);
    try std.testing.expectEqualStrings("00", argv[6]);
}
