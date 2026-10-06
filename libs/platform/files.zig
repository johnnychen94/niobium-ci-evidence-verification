//! File-backed integrations (macOS links and plists, Linux .desktop/mime/unit files, Windows
//! .lnk files): prepare writes `<final>.nb-tx-<n>`, activate renames it over `<final>`,
//! remove deletes `<final>` only when it carries the framework's ownership marker. A file the
//! framework did not write is never replaced or deleted.

const std = @import("std");
const api = @import("api.zig");
const local = @import("local.zig");
const names = @import("names.zig");

const Dir = std.Io.Dir;
const Error = api.Error;

pub const marker = "niobium-managed";

pub const Body = union(enum) {
    /// File contents; must contain `Spec.owner`.
    content: []const u8,
    /// Absolute symlink target; a symlink is owned when its target contains `Spec.owner`.
    link: []const u8,
};

pub const Spec = struct {
    final: []const u8,
    body: Body,
    /// Ownership marker searched as ASCII and as UTF-16LE.
    owner: []const u8 = marker,
};

/// The marker must appear in the first 64 KiB.
const max_owned_read = 64 * 1024;

/// True when `path` is absent; false when it is ours; error when a foreign file is in the way.
fn free(io: std.Io, path: []const u8, owner: []const u8) Error!bool {
    switch (try probe(io, path, owner)) {
        .missing => return true,
        .owned => return false,
        .foreign => return error.PlatformIntegrationFailed,
    }
}

pub const Probe = enum { missing, owned, foreign };

pub fn probe(io: std.Io, path: []const u8, owner: []const u8) Error!Probe {
    var buffer: [std.fs.max_path_bytes]u8 = undefined; // SAFETY: filled by readLink.
    if (Dir.cwd().readLink(io, path, &buffer)) |len| {
        return if (std.mem.find(u8, buffer[0..len], owner) != null) .owned else .foreign;
    } else |err| switch (err) {
        error.FileNotFound => return .missing,
        error.NotLink => {},
        else => return api.mapFs(err),
    }
    var file_buffer: [max_owned_read]u8 = undefined; // SAFETY: only the read prefix is used.
    const bytes = Dir.cwd().readFile(io, path, &file_buffer) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        error.IsDir => return .foreign,
        else => return api.mapFs(err),
    };
    return if (contains(bytes, owner)) .owned else .foreign;
}

fn contains(bytes: []const u8, owner: []const u8) bool {
    if (std.mem.find(u8, bytes, owner) != null) return true;
    var wide: [256]u8 = undefined; // SAFETY: only wide[0 .. owner.len * 2] is read.
    if (owner.len * 2 > wide.len) return false;
    for (owner, 0..) |c, i| {
        wide[i * 2] = c;
        wide[i * 2 + 1] = 0;
    }
    return std.mem.find(u8, bytes, wide[0 .. owner.len * 2]) != null;
}

fn materialize(l: local.Local, path: []const u8, body: Body) Error!void {
    switch (body) {
        .content => |bytes| try l.writeFile(path, bytes, false),
        .link => |target| {
            try l.deleteFile(path);
            Dir.cwd().symLink(l.io, target, path, .{}) catch |err| return api.mapFs(err);
        },
    }
}

pub fn prepare(l: local.Local, spec: Spec, tx: u64) Error!void {
    const dir = std.fs.path.dirname(spec.final) orelse return error.PlatformIntegrationFailed;
    try l.createDirPath(dir);
    // lint-allow(no-discard-call): only the foreign-file error matters before activation.
    _ = try free(l.io, spec.final, spec.owner);
    var buffer: [std.fs.max_path_bytes]u8 = undefined; // SAFETY: written by tempName.
    try materialize(l, try names.tempName(&buffer, spec.final, tx), spec.body);
}

pub fn discard(l: local.Local, final: []const u8, tx: u64) Error!void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined; // SAFETY: written by tempName.
    return l.deleteFile(try names.tempName(&buffer, final, tx));
}

/// Idempotent: after a crash the temp may already be gone, so the final file is rewritten.
pub fn activate(l: local.Local, spec: Spec, tx: u64) Error!void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined; // SAFETY: written by tempName.
    const temp = try names.tempName(&buffer, spec.final, tx);
    const fresh = try free(l.io, spec.final, spec.owner);
    l.rename(temp, spec.final) catch |err| switch (err) {
        error.FsNotFound => {
            const dir = std.fs.path.dirname(
                spec.final,
            ) orelse return error.PlatformIntegrationFailed;
            try l.createDirPath(dir);
            if (!fresh and spec.body == .link) try l.deleteFile(spec.final);
            try materialize(l, spec.final, spec.body);
        },
        else => return err,
    };
}

/// Missing is fine (already removed); a foreign file at the location is left alone.
pub fn remove(l: local.Local, path: []const u8, owner: []const u8) Error!void {
    switch (try probe(l.io, path, owner)) {
        .missing => {},
        .owned => try l.deleteFile(path),
        .foreign => return error.PlatformIntegrationFailed,
    }
}

/// XML character data; control characters are refused.
pub fn xmlText(w: *std.Io.Writer, text: []const u8) Error!void {
    for (text) |c| {
        const escaped: []const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            else => {
                if (c < 0x20) return error.PlatformIntegrationFailed;
                w.writeByte(c) catch return error.OutOfMemory;
                continue;
            },
        };
        w.writeAll(escaped) catch return error.OutOfMemory;
    }
}

test "file integration lifecycle and ownership" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const l: local.Local = .{ .io = io };
    const final = try std.fs.path.join(a, &.{ base, "apps", "hello.desktop" });
    const spec: Spec = .{ .final = final, .body = .{ .content = "x " ++ marker ++ "\n" } };
    try prepare(l, spec, 7);
    try activate(l, spec, 7);
    try activate(l, spec, 7);
    try std.testing.expectEqual(Probe.owned, try probe(io, final, marker));
    try remove(l, final, marker);
    try remove(l, final, marker);
    try std.testing.expectEqual(Probe.missing, try probe(io, final, marker));

    try l.writeFile(final, "user file", false);
    try std.testing.expectError(error.PlatformIntegrationFailed, prepare(l, spec, 8));
    try std.testing.expectError(error.PlatformIntegrationFailed, remove(l, final, marker));

    const link = try std.fs.path.join(a, &.{ base, "apps", "Hello" });
    const link_spec: Spec = .{ .final = link, .body = .{ .link = base }, .owner = base };
    try prepare(l, link_spec, 9);
    try activate(l, link_spec, 9);
    try activate(l, link_spec, 9);
    try std.testing.expectEqual(Probe.owned, try probe(io, link, base));
    try std.testing.expectEqual(Probe.foreign, try probe(io, link, "/elsewhere/"));
    try remove(l, link, base);
}
