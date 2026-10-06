//! Commit message lint (zig build check-commits [-- <range>]): `<type>(<scope>): summary`.
//! Default range: origin/main..HEAD. Merge commits are skipped.

const std = @import("std");
const repo = @import("repo");

pub const types = [_][]const u8{
    "feat", "fix", "test", "docs", "refactor", "chore", "adr", "build",
};

pub const max_subject_bytes = 200;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const range = if (args.len > 1) args[1] else "origin/main..HEAD";
    const result = try std.process.run(arena, io, .{
        .argv = &.{ "git", "log", "--no-merges", "--format=%h %s", range },
        .stdout_limit = .limited(4 << 20),
        .stderr_limit = .limited(64 << 10),
    });
    var report: repo.Report = .{ .arena = arena, .tool = "check-commits" };
    if (!result.term.success()) {
        try report.add("git log {s} failed: {s}", .{ range, result.stderr });
        return report.finish(io);
    }
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const space = std.mem.findScalar(u8, line, ' ') orelse continue;
        const subject = line[space + 1 ..];
        if (validate(subject)) |reason| try report.add(
            "{s}: {s}: '{s}'",
            .{ line[0..space], reason, subject },
        );
    }
    try report.finish(io);
}

/// Returns null when the subject is valid, else the reason.
pub fn validate(subject: []const u8) ?[]const u8 {
    if (subject.len > max_subject_bytes) return "subject too long";
    const open = std.mem.findScalar(u8, subject, '(') orelse return "missing (<scope>)";
    const kind = subject[0..open];
    var known = false;
    for (types) |t| {
        if (std.mem.eql(u8, t, kind)) known = true;
    }
    if (!known) return "unknown type";
    const close = std.mem.findScalarPos(u8, subject, open, ')') orelse return "unclosed scope";
    const scope = subject[open + 1 .. close];
    if (scope.len == 0) return "empty scope";
    for (scope) |c| {
        const ok = std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '/' or c == '_';
        if (!ok) return "scope must be lowercase [a-z0-9-/_]";
    }
    if (!std.mem.startsWith(u8, subject[close + 1 ..], ": ")) return "missing ': ' after scope";
    if (subject.len <= close + 3) return "empty summary";
    return null;
}

test "commit subjects" {
    const valid = validate("feat(trust): implement root rotation");
    try std.testing.expectEqual(@as(?[]const u8, null), valid);
    try std.testing.expect(validate("Initial commit") != null);
    try std.testing.expect(validate("feat: missing scope") != null);
    try std.testing.expect(validate("wip(core): x") != null);
    try std.testing.expect(validate("fix(Core): x") != null);
}
