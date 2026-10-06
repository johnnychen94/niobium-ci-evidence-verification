//! Free-space query for preflight (docs/spec/platform-contract-v1.md#capabilities,
//! FileSystem). Bytes available to the unprivileged caller on the volume holding `path`, or its
//! nearest existing ancestor (install roots usually do not exist yet).

const std = @import("std");
const builtin = @import("builtin");
const api = @import("api.zig");

const Error = api.Error;

pub fn available(path: []const u8) Error!u64 {
    if (!std.fs.path.isAbsolute(path)) return error.FsIo;
    var current = path;
    for (0..std.fs.max_path_bytes) |_| {
        if (try query(current)) |bytes| return bytes;
        current = std.fs.path.dirname(current) orelse return error.FsNotFound;
    }
    return error.FsNotFound;
}

/// Null when `path` does not exist.
fn query(path: []const u8) Error!?u64 {
    var buffer: [std.fs.max_path_bytes + 1]u8 = undefined; // SAFETY: NUL-terminated copy.
    if (path.len >= buffer.len) return error.FsIo;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    const z: [*:0]const u8 = buffer[0..path.len :0];
    return switch (builtin.os.tag) {
        .macos => darwin(z),
        .linux => linux(z),
        .windows => windowsQuery(path),
        else => error.CapabilityUnsupported,
    };
}

/// `struct statfs` with 64-bit inodes (the only layout on arm64).
const DarwinStatfs = extern struct {
    bsize: u32,
    iosize: i32,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    fsid: [2]i32,
    owner: u32,
    type: u32,
    flags: u32,
    fssubtype: u32,
    fstypename: [16]u8,
    mntonname: [1024]u8,
    mntfromname: [1024]u8,
    flags_ext: u32,
    reserved: [7]u32,
};

const darwin_statfs = @extern(
    *const fn ([*:0]const u8, *DarwinStatfs) callconv(.c) c_int,
    .{ .name = if (builtin.cpu.arch == .x86_64) "statfs$INODE64" else "statfs" },
);

fn darwin(path: [*:0]const u8) Error!?u64 {
    // SAFETY: filled by statfs on success.
    var info: DarwinStatfs = undefined;
    if (darwin_statfs(path, &info) != 0) {
        return switch (std.c.errno(-1)) {
            .NOENT, .NOTDIR => null,
            .ACCES, .PERM => error.FsAccessDenied,
            else => error.FsIo,
        };
    }
    return std.math.mul(u64, info.bavail, info.bsize) catch std.math.maxInt(u64);
}

/// Generic 64-bit `struct statfs` (x86_64 and aarch64 share it).
const LinuxStatfs = extern struct {
    type: i64,
    bsize: i64,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    fsid: [2]i32,
    namelen: i64,
    frsize: i64,
    flags: i64,
    spare: [4]i64,
};

fn linux(path: [*:0]const u8) Error!?u64 {
    const sys = std.os.linux;
    // SAFETY: filled by the kernel on success.
    var info: LinuxStatfs = undefined;
    const rc = sys.syscall2(.statfs, @intFromPtr(path), @intFromPtr(&info));
    switch (sys.errno(rc)) {
        .SUCCESS => {},
        .NOENT, .NOTDIR => return null,
        .ACCES, .PERM => return error.FsAccessDenied,
        else => return error.FsIo,
    }
    const block = std.math.cast(u64, info.bsize) orelse return error.FsIo;
    return std.math.mul(u64, info.bavail, block) catch std.math.maxInt(u64);
}

extern "kernel32" fn GetDiskFreeSpaceExW(
    directory: [*:0]const u16,
    available_to_caller: ?*u64,
    total: ?*u64,
    free: ?*u64,
) callconv(.winapi) c_int;

fn windowsQuery(path: []const u8) Error!?u64 {
    var wide: [32 * 1024]u16 = undefined; // SAFETY: NUL-terminated below.
    // WTF-16 never needs more code units than the WTF-8 input has bytes.
    if (path.len >= wide.len) return error.FsIo;
    const len = std.unicode.wtf8ToWtf16Le(&wide, path) catch return error.FsIo;
    wide[len] = 0;
    var bytes: u64 = 0;
    if (GetDiskFreeSpaceExW(wide[0..len :0], &bytes, null, null) == 0) {
        return switch (std.os.windows.GetLastError()) {
            .FILE_NOT_FOUND, .PATH_NOT_FOUND, .INVALID_NAME => null,
            .ACCESS_DENIED => error.FsAccessDenied,
            else => error.FsIo,
        };
    }
    return bytes;
}

test "free space of the temp volume" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    const missing = try std.fs.path.join(arena.allocator(), &.{ base, "not", "yet" });
    try std.testing.expect(try available(missing) > 0);
}
