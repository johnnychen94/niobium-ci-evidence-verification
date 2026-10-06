//! Project linter on std.zig.Ast (zig build lint). Usage: nb-lint [--write-baseline] <roots...>
//! Suppress with `// lint-allow(<rule>): <reason>` on the line or the line above.

const std = @import("std");
const repo = @import("repo");
const context = @import("context.zig");
const token_rules = @import("token_rules.zig");
const ast_rules = @import("ast_rules.zig");
const complexity = @import("complexity.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    var write_baseline = false;
    var roots: std.ArrayList([]const u8) = .empty;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--write-baseline")) {
            write_baseline = true;
        } else {
            try roots.append(arena, arg);
        }
    }
    const files = try repo.list(arena, io);
    var report: repo.Report = .{ .arena = arena, .tool = "lint" };
    var stats: Stats = .{};
    var measured: std.ArrayList(complexity.Entry) = .empty;
    for (files.paths) |path| {
        if (!selected(path, roots.items)) continue;
        const source = try arena.dupeSentinel(u8, try repo.read(arena, io, path), 0);
        var ctx = try context.Ctx.init(arena, path, source);
        try lintFile(&ctx, &report, &stats);
        try measured.append(arena, .{
            .path = path,
            .tokens = @intCast(ctx.tree.tokens.len),
            .nodes = @intCast(ctx.tree.nodes.len),
        });
    }
    if (write_baseline) {
        try complexity.write(arena, io, measured.items);
    } else {
        try complexity.compare(&report, io, measured.items);
    }
    try printSummary(io, stats);
    try report.finish(io);
}

const Stats = struct {
    files: u32 = 0,
    suppressed: u32 = 0,
};

fn selected(path: []const u8, roots: []const []const u8) bool {
    if (!std.mem.endsWith(u8, path, ".zig")) return false;
    if (std.mem.startsWith(u8, path, "tests/fixtures/")) return false;
    const vendored = std.mem.startsWith(u8, path, "third_party/");
    if (vendored and !std.mem.endsWith(u8, path, "/bindings.zig")) return false;
    for (roots) |root| {
        if (std.mem.eql(u8, path, root)) return true;
        if (std.mem.startsWith(
            u8,
            path,
            root,
        ) and path.len > root.len and path[root.len] == '/') return true;
    }
    return false;
}

fn lintFile(ctx: *context.Ctx, report: *repo.Report, stats: *Stats) !void {
    stats.files += 1;
    if (ctx.tree.errors.len > 0) {
        try report.add("{s}: parse error", .{ctx.path});
        return;
    }
    try token_rules.run(ctx);
    try ast_rules.run(ctx);
    for (ctx.findings.items) |finding| {
        switch (suppression(ctx, finding)) {
            .none => try report.add("{s}:{d}: [{s}] {s}", .{
                ctx.path, finding.line, finding.rule, finding.message,
            }),
            .with_reason => stats.suppressed += 1,
            .without_reason => try report.add("{s}:{d}: [{s}] lint-allow needs a reason", .{
                ctx.path, finding.line, finding.rule,
            }),
        }
    }
}

const Suppression = enum { none, with_reason, without_reason };

fn suppression(ctx: *const context.Ctx, finding: context.Finding) Suppression {
    const marker = ctx.arena.print("// lint-allow({s}):", .{finding.rule}) catch return .none;
    const lines = [_]u32{ finding.line, finding.line -| 1 };
    for (lines) |line| {
        if (line == 0) continue;
        const text = ctx.lineText(line);
        const at = std.mem.find(u8, text, marker) orelse continue;
        const reason = std.mem.trim(u8, text[at + marker.len ..], " \t");
        return if (reason.len > 0) .with_reason else .without_reason;
    }
    return .none;
}

fn printSummary(io: std.Io, stats: Stats) !void {
    var buffer: [256]u8 = undefined; // SAFETY: writer scratch, written before read.
    var writer: std.Io.File.Writer = .init(.stderr(), io, &buffer);
    try writer.interface.print(
        "lint: {d} files, {d} suppression(s)\n",
        .{ stats.files, stats.suppressed },
    );
    try writer.interface.flush();
}

test {
    _ = @import("rules_test.zig");
}
