//! Repository enumeration for build-time tools. Paths are '/'-separated and sorted.

const std = @import("std");

/// Directories never scanned by repository tools.
pub const skipped_dirs = [_][]const u8{
    ".git",         ".zig-cache", "zig-out", ".evidence", ".local", ".claude",
    "node_modules", ".cursor",
};

/// Build outputs of nested packages (examples/hello builds on its own), skipped at any depth.
pub const build_dirs = [_][]const u8{ ".zig-cache", "zig-out", "zig-pkg" };

/// External skills are pinned third-party content (skills-lock.json);
/// only repo-owned ones are checked.
pub const owned_skill_prefixes = [_][]const u8{ "niobium-", "review-niobium" };

pub const Files = struct {
    paths: []const []const u8,

    pub fn withSuffix(
        files: Files,
        arena: std.mem.Allocator,
        suffix: []const u8,
    ) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (files.paths) |path| {
            if (std.mem.endsWith(u8, path, suffix)) try out.append(arena, path);
        }
        return out.items;
    }
};

pub const max_files = 20_000;

/// Lists every regular file under the current directory (the repository root).
pub fn list(arena: std.mem.Allocator, io: std.Io) !Files {
    var root = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer root.close(io);
    var walker = try root.walkSelectively(arena);
    defer walker.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (out.items.len >= max_files) return error.TooManyFiles;
        switch (entry.kind) {
            .directory => if (!skipDir(entry.path)) try walker.enter(io, entry),
            .file => try out.append(arena, try normalize(arena, entry.path)),
            else => {},
        }
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return .{ .paths = out.items };
}

fn normalize(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const copy = try arena.dupe(u8, path);
    std.mem.replaceScalar(u8, copy, '\\', '/');
    return copy;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn skipDir(path_raw: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined; // SAFETY: path scratch.
    if (path_raw.len > buf.len) return true;
    const path = buf[0..path_raw.len];
    @memcpy(path, path_raw);
    std.mem.replaceScalar(u8, path, '\\', '/');
    for (skipped_dirs) |name| {
        if (std.mem.eql(u8, path, name)) return true;
    }
    for (build_dirs) |name| {
        if (std.mem.eql(u8, std.fs.path.basenamePosix(path), name)) return true;
    }
    if (std.mem.startsWith(u8, path, ".agents/skills/")) {
        const rest = path[".agents/skills/".len..];
        if (std.mem.findScalar(u8, rest, '/') != null) return false;
        for (owned_skill_prefixes) |prefix| {
            if (std.mem.startsWith(u8, rest, prefix)) return false;
        }
        return true;
    }
    return false;
}

/// Reads a repository file with a hard size bound.
pub fn read(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20));
}

pub fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Collects findings; tools print them and exit non-zero when any exist.
pub const Report = struct {
    arena: std.mem.Allocator,
    tool: []const u8,
    findings: std.ArrayList([]const u8) = .empty,

    pub fn add(report: *Report, comptime fmt: []const u8, args: anytype) !void {
        try report.findings.append(report.arena, try report.arena.print(fmt, args));
    }

    pub fn finish(report: *Report, io: std.Io) !void {
        var buffer: [4096]u8 = undefined; // SAFETY: writer scratch.
        var writer: std.Io.File.Writer = .init(.stderr(), io, &buffer);
        const w = &writer.interface;
        for (report.findings.items) |line| try w.print("{s}: {s}\n", .{ report.tool, line });
        if (report.findings.items.len > 0) {
            try w.print("{s}: {d} finding(s)\n", .{ report.tool, report.findings.items.len });
            try w.flush();
            return error.CheckFailed;
        }
        try w.flush();
    }
};

test "skipDir keeps owned skills and skips caches" {
    try std.testing.expect(skipDir(".zig-cache"));
    try std.testing.expect(skipDir("examples/hello/.zig-cache"));
    try std.testing.expect(skipDir("examples/hello/zig-pkg"));
    try std.testing.expect(!skipDir("examples/hello/app"));
    try std.testing.expect(skipDir(".agents/skills/apple-hig"));
    try std.testing.expect(!skipDir(".agents/skills/niobium-ui-kit"));
    try std.testing.expect(!skipDir(".agents/skills/review-niobium"));
    try std.testing.expect(!skipDir("libs/core"));
}
