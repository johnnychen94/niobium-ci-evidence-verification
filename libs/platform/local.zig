//! Filesystem mutations on the local machine via std.Io, shared by VirtualPlatform and the host
//! backends. Atomic replace = temp file + fsync + rename; pointer swap = new link + rename.

const std = @import("std");
const builtin = @import("builtin");
const api = @import("api.zig");
const space = @import("space.zig");

const Dir = std.Io.Dir;
const Error = api.Error;

pub const Local = struct {
    io: std.Io,

    fn cwd() Dir {
        return Dir.cwd();
    }

    pub fn createDirPath(l: Local, path: []const u8) Error!void {
        cwd().createDirPath(l.io, path) catch |err| return api.mapFs(err);
    }

    fn permissions(executable: bool) std.Io.File.Permissions {
        return if (executable) .executable_file else .default_file;
    }

    pub fn writeFile(l: Local, path: []const u8, bytes: []const u8, executable: bool) Error!void {
        var atomic = cwd().createFileAtomic(l.io, path, .{
            .replace = true,
            .permissions = permissions(executable),
        }) catch |err| return api.mapFs(err);
        defer atomic.deinit(l.io);
        atomic.file.writeStreamingAll(l.io, bytes) catch |err| return api.mapFs(err);
        atomic.file.sync(l.io) catch |err| return api.mapFs(err);
        atomic.replace(l.io) catch |err| return api.mapFs(err);
    }

    pub fn appendFile(l: Local, path: []const u8, bytes: []const u8) Error!void {
        const file = cwd().createFile(
            l.io,
            path,
            .{ .truncate = false },
        ) catch |err| return api.mapFs(err);
        defer file.close(l.io);
        const end = file.length(l.io) catch |err| return api.mapFs(err);
        file.writePositionalAll(l.io, bytes, end) catch |err| return api.mapFs(err);
        file.sync(l.io) catch |err| return api.mapFs(err);
    }

    pub fn copyFile(l: Local, source: []const u8, target: []const u8, executable: bool) Error!void {
        cwd().copyFile(source, cwd(), target, l.io, .{
            .permissions = permissions(executable),
            .replace = true,
        }) catch |err| return api.mapFs(err);
    }

    pub fn rename(l: Local, from: []const u8, to: []const u8) Error!void {
        Dir.rename(cwd(), from, cwd(), to, l.io) catch |err| return api.mapFs(err);
    }

    pub fn deleteFile(l: Local, path: []const u8) Error!void {
        cwd().deleteFile(l.io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return api.mapFs(err),
        };
    }

    pub fn deleteTree(l: Local, path: []const u8) Error!void {
        cwd().deleteTree(l.io, path) catch |err| return api.mapFs(err);
    }

    /// `<link>.next` is created fresh and renamed over `link`, so readers see old or new.
    pub fn setPointer(l: Local, link: []const u8, target: []const u8) Error!void {
        var buffer: [std.fs.max_path_bytes]u8 = undefined; // SAFETY: written by bufPrint.
        const next = std.fmt.bufPrint(&buffer, "{s}.next", .{link}) catch return error.FsIo;
        try l.deletePointer(next);
        const flags: Dir.SymLinkFlags = .{ .is_directory = true };
        cwd().symLink(l.io, target, next, flags) catch |err| return api.mapFs(err);
        try l.rename(next, link);
    }

    pub fn freeSpace(l: Local, path: []const u8) Error!u64 {
        _ = l;
        return space.available(path);
    }

    pub fn deletePointer(l: Local, link: []const u8) Error!void {
        if (builtin.os.tag == .windows) {
            cwd().deleteDir(l.io, link) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return api.mapFs(err),
            };
            return;
        }
        return l.deleteFile(link);
    }
};

/// Target of the pointer at `link`, or null when there is none.
pub fn readPointer(io: std.Io, arena: std.mem.Allocator, link: []const u8) Error!?[]const u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined; // SAFETY: filled by readLink.
    const len = Dir.cwd().readLink(io, link, &buffer) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return api.mapFs(err),
    };
    return try arena.dupe(u8, buffer[0..len]);
}

test "local atomic write, append, pointer swap" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const l: Local = .{ .io = io };
    const file = try std.fs.path.join(a, &.{ base, "f.txt" });
    try l.writeFile(file, "one", false);
    try l.writeFile(file, "two", false);
    try l.appendFile(file, "+three");
    try std.testing.expectEqualStrings(
        "two+three",
        try tmp.dir.readFileAlloc(io, "f.txt", a, .limited(64)),
    );
    try l.createDirPath(try std.fs.path.join(a, &.{ base, "versions", "1" }));
    try l.createDirPath(try std.fs.path.join(a, &.{ base, "versions", "2" }));
    const link = try std.fs.path.join(a, &.{ base, "current" });
    try std.testing.expect(try readPointer(io, a, link) == null);
    try l.setPointer(link, "versions/1");
    try l.setPointer(link, "versions/2");
    try std.testing.expectEqualStrings(
        "versions" ++ std.fs.path.sep_str ++ "2",
        (try readPointer(io, a, link)).?,
    );
    try l.deletePointer(link);
    try l.deletePointer(link);
    try std.testing.expect(try readPointer(io, a, link) == null);
    try l.deleteTree(try std.fs.path.join(a, &.{ base, "versions" }));
    try l.deleteFile(try std.fs.path.join(a, &.{ base, "missing" }));
}
