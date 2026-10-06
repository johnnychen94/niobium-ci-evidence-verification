//! Source rules: 600-line files, no relative cross-module imports, owner-less directories, no
//! committed generated files.

const std = @import("std");
const repo = @import("repo");
const specs = @import("module_specs");

pub const max_file_lines = 600;

const forbidden_dir_names = [_][]const u8{ "shared", "common", "utils", "helpers" };

const generated_outputs = [_][]const u8{"libs/ui/tokens/tokens.zig"};

pub fn check(report: *repo.Report, io: std.Io, files: repo.Files) !void {
    for (files.paths) |path| {
        if (exempt(path)) continue;
        try checkDirNames(report, path);
        if (!std.mem.endsWith(u8, path, ".zig")) continue;
        const bytes = try repo.read(report.arena, io, path);
        const lines = std.mem.count(u8, bytes, "\n");
        if (lines > max_file_lines) {
            try report.add("{s}: {d} lines > {d}", .{ path, lines, max_file_lines });
        }
        try checkImports(report, path, bytes);
    }
    for (generated_outputs) |path| {
        if (repo.exists(io, path)) try report.add(
            "{s}: generated file must not be committed",
            .{path},
        );
    }
}

fn exempt(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, "third_party/")) {
        return !std.mem.endsWith(u8, path, "/bindings.zig");
    }
    return std.mem.startsWith(
        u8,
        path,
        "tests/fixtures/",
    ) or std.mem.startsWith(u8, path, ".agents/");
}

fn checkDirNames(report: *repo.Report, path: []const u8) !void {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (it.peek() == null) break;
        for (forbidden_dir_names) |name| {
            if (std.mem.eql(u8, component, name)) {
                try report.add("{s}: directory '{s}' has no semantic owner", .{ path, name });
            }
        }
    }
}

/// Owner directory of a source file: the declared module root dir, or the first two components.
pub fn ownerDir(path: []const u8) []const u8 {
    var best: []const u8 = "";
    for (specs.specs) |spec| {
        if (spec.generated) continue;
        const dir = std.fs.path.dirnamePosix(spec.root) orelse continue;
        if (std.mem.startsWith(
            u8,
            path,
            dir,
        ) and path.len > dir.len and path[dir.len] == '/' and dir.len > best.len) {
            best = dir;
        }
    }
    if (best.len > 0) return best;
    if (std.mem.startsWith(u8, path, "build/")) return "build";
    var slashes: usize = 0;
    for (path, 0..) |c, index| {
        if (c != '/') continue;
        slashes += 1;
        if (slashes == 2) return path[0..index];
    }
    return std.fs.path.dirnamePosix(path) orelse "";
}

fn checkImports(report: *repo.Report, path: []const u8, bytes: []const u8) !void {
    const owner = ownerDir(path);
    const dir = std.fs.path.dirnamePosix(path) orelse "";
    var rest = bytes;
    while (std.mem.find(u8, rest, "@import(\"")) |start| {
        rest = rest[start + "@import(\"".len ..];
        const end = std.mem.findScalar(u8, rest, '"') orelse break;
        const target = rest[0..end];
        rest = rest[end..];
        if (!std.mem.endsWith(u8, target, ".zig")) continue;
        const resolved = try std.fs.path.resolveAllocPosix(report.arena, &.{ dir, target });
        if (!std.mem.startsWith(u8, resolved, owner)) {
            try report.add(
                "{s}: relative import '{s}' leaves owner '{s}'",
                .{ path, target, owner },
            );
        }
    }
}

test "ownerDir prefers the declared module root" {
    try std.testing.expectEqualStrings("libs/ui/core", ownerDir("libs/ui/core/layout.zig"));
    try std.testing.expectEqualStrings("libs/platform", ownerDir("libs/platform/windows/fs.zig"));
    try std.testing.expectEqualStrings("apps/setup", ownerDir("apps/setup/cli.zig"));
}
