//! Per-file lint context: source, AST, line index, test/function ranges, path classification.

const std = @import("std");
const Ast = std.zig.Ast;

pub const Finding = struct {
    line: u32,
    rule: []const u8,
    message: []const u8,
};

pub const Range = struct {
    start: u32,
    end: u32,

    pub fn contains(range: Range, offset: u32) bool {
        return offset >= range.start and offset < range.end;
    }
};

pub const FnRange = struct {
    name: []const u8,
    body: Range,
    is_pub: bool,
};

pub const Ctx = struct {
    arena: std.mem.Allocator,
    path: []const u8,
    source: [:0]const u8,
    tree: Ast,
    line_starts: []const u32,
    tests: []const Range,
    fns: []const FnRange,
    findings: std.ArrayList(Finding) = .empty,

    pub fn init(arena: std.mem.Allocator, path: []const u8, source: [:0]const u8) !Ctx {
        const tree = try Ast.parse(arena, source, .{});
        var ctx: Ctx = .{
            .arena = arena,
            .path = path,
            .source = source,
            .tree = tree,
            .line_starts = try lineStarts(arena, source),
            .tests = &.{},
            .fns = &.{},
        };
        try ctx.indexRanges();
        return ctx;
    }

    fn indexRanges(ctx: *Ctx) !void {
        var tests: std.ArrayList(Range) = .empty;
        var fns: std.ArrayList(FnRange) = .empty;
        const tags = ctx.tree.nodes.items(.tag);
        for (tags, 0..) |tag, raw| {
            const node: Ast.Node.Index = @fromBackingInt(@as(u32, @intCast(raw)));
            switch (tag) {
                .test_decl => try tests.append(ctx.arena, ctx.nodeRange(node)),
                .fn_decl => try fns.append(ctx.arena, ctx.fnRange(node)),
                else => {},
            }
        }
        ctx.tests = tests.items;
        ctx.fns = fns.items;
    }

    fn fnRange(ctx: *Ctx, node: Ast.Node.Index) FnRange {
        const proto, const body = ctx.tree.nodeData(node).node_and_node;
        var buffer: [1]Ast.Node.Index = undefined; // SAFETY: filled by fullFnProto.
        const full = ctx.tree.fullFnProto(&buffer, proto).?;
        const name = if (full.name_token) |token| ctx.tree.tokenSlice(token) else "";
        const first = ctx.tree.firstToken(node);
        const is_pub = first > 0 and ctx.tree.tokenTag(first) == .keyword_pub;
        return .{ .name = name, .body = ctx.nodeRange(body), .is_pub = is_pub };
    }

    pub fn nodeRange(ctx: *const Ctx, node: Ast.Node.Index) Range {
        const first = ctx.tree.firstToken(node);
        const last = ctx.tree.lastToken(node);
        const end_token = ctx.tree.tokenSlice(last);
        return .{
            .start = ctx.tree.tokenStart(first),
            .end = ctx.tree.tokenStart(last) + @as(u32, @intCast(end_token.len)),
        };
    }

    pub fn lineOf(ctx: *const Ctx, offset: u32) u32 {
        var lo: usize = 0;
        var hi: usize = ctx.line_starts.len;
        while (lo + 1 < hi) {
            const mid = (lo + hi) / 2;
            if (ctx.line_starts[mid] <= offset) lo = mid else hi = mid;
        }
        return @intCast(lo + 1);
    }

    pub fn lineText(ctx: *const Ctx, line: u32) []const u8 {
        if (line == 0 or line > ctx.line_starts.len) return "";
        const start = ctx.line_starts[line - 1];
        const end = if (line < ctx.line_starts.len) ctx.line_starts[line] - 1 else ctx.source.len;
        return ctx.source[start..end];
    }

    pub fn inTest(ctx: *const Ctx, offset: u32) bool {
        if (std.mem.startsWith(u8, ctx.path, "tests/")) return true;
        for (ctx.tests) |range| {
            if (range.contains(offset)) return true;
        }
        return false;
    }

    pub fn inFn(ctx: *const Ctx, offset: u32) bool {
        for (ctx.fns) |f| {
            if (f.body.contains(offset)) return true;
        }
        return false;
    }

    pub fn pathIn(ctx: *const Ctx, prefixes: []const []const u8) bool {
        for (prefixes) |prefix| {
            if (std.mem.startsWith(u8, ctx.path, prefix)) return true;
        }
        return false;
    }

    pub fn report(
        ctx: *Ctx,
        offset: u32,
        rule: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const line = ctx.lineOf(offset);
        try ctx.findings.append(ctx.arena, .{
            .line = line,
            .rule = rule,
            .message = try ctx.arena.print(fmt, args),
        });
    }

    /// True when `line` or the line above carries `marker` (e.g. "// SAFETY:").
    pub fn hasMarker(ctx: *const Ctx, line: u32, marker: []const u8) bool {
        if (std.mem.find(u8, ctx.lineText(line), marker) != null) return true;
        return line > 1 and std.mem.find(u8, ctx.lineText(line - 1), marker) != null;
    }
};

fn lineStarts(arena: std.mem.Allocator, source: []const u8) ![]const u32 {
    var starts: std.ArrayList(u32) = .empty;
    try starts.append(arena, 0);
    for (source, 0..) |c, index| {
        if (c == '\n') try starts.append(arena, @intCast(index + 1));
    }
    return starts.items;
}
