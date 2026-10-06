//! AST rules: TigerStyle shape (function length, recursion, split asserts, line length),
//! discarded calls, anyerror in pub signatures.

const std = @import("std");
const Ast = std.zig.Ast;
const context = @import("context.zig");

const Ctx = context.Ctx;

pub const max_fn_body_lines = 70;
pub const max_line_columns = 100;

pub fn run(ctx: *Ctx) !void {
    try checkLines(ctx);
    for (ctx.fns) |f| {
        const first = ctx.lineOf(f.body.start);
        const last = ctx.lineOf(f.body.end -| 1);
        const body_lines = if (last > first + 1) last - first - 1 else 0;
        if (body_lines > max_fn_body_lines) {
            try ctx.report(f.body.start, "fn-length", "fn '{s}' body has {d} lines > {d}", .{
                f.name, body_lines, max_fn_body_lines,
            });
        }
    }
    const tags = ctx.tree.nodes.items(.tag);
    for (tags, 0..) |tag, raw| {
        const node: Ast.Node.Index = @fromBackingInt(@as(u32, @intCast(raw)));
        switch (tag) {
            .call, .call_comma, .call_one, .call_one_comma => try checkCall(ctx, node),
            .assign => try checkDiscard(ctx, node),
            .fn_decl => try checkPubAnyerror(ctx, node),
            else => {},
        }
    }
}

fn checkLines(ctx: *Ctx) !void {
    for (1..ctx.line_starts.len + 1) |line_index| {
        const line: u32 = @intCast(line_index);
        const text = ctx.lineText(line);
        const columns = std.unicode.utf8CountCodepoints(text) catch text.len;
        if (columns > max_line_columns) {
            try ctx.report(ctx.line_starts[line - 1], "line-length", "{d} columns > {d}", .{
                columns, max_line_columns,
            });
        }
    }
}

fn calleeName(ctx: *const Ctx, call: Ast.full.Call) ?[]const u8 {
    const tree = &ctx.tree;
    return switch (tree.nodeTag(call.ast.fn_expr)) {
        .identifier => tree.tokenSlice(tree.nodeMainToken(call.ast.fn_expr)),
        .field_access => tree.tokenSlice(tree.nodeData(call.ast.fn_expr).node_and_token[1]),
        else => null,
    };
}

fn checkCall(ctx: *Ctx, node: Ast.Node.Index) !void {
    var buffer: [1]Ast.Node.Index = undefined; // SAFETY: filled by fullCall.
    const call = ctx.tree.fullCall(&buffer, node) orelse return;
    const name = calleeName(ctx, call) orelse return;
    const offset = ctx.nodeRange(node).start;
    if (std.mem.eql(u8, name, "assert") and call.ast.params.len == 1) {
        if (ctx.tree.nodeTag(call.ast.params[0]) == .bool_and) {
            try ctx.report(
                offset,
                "split-assert",
                "split compound assert(a and b) into two asserts",
                .{},
            );
        }
    }
    if (ctx.tree.nodeTag(call.ast.fn_expr) != .identifier) return;
    for (ctx.fns) |f| {
        if (f.body.contains(offset) and std.mem.eql(u8, f.name, name)) {
            try ctx.report(offset, "no-recursion", "fn '{s}' calls itself", .{name});
        }
    }
}

fn checkDiscard(ctx: *Ctx, node: Ast.Node.Index) !void {
    const lhs, const rhs = ctx.tree.nodeData(node).node_and_node;
    if (ctx.tree.nodeTag(lhs) != .identifier) return;
    if (!std.mem.eql(u8, ctx.tree.tokenSlice(ctx.tree.nodeMainToken(lhs)), "_")) return;
    const discarded = switch (ctx.tree.nodeTag(rhs)) {
        .call, .call_comma, .call_one, .call_one_comma, .@"try" => true,
        else => false,
    };
    if (!discarded) return;
    const offset = ctx.nodeRange(node).start;
    if (ctx.inTest(offset)) return;
    try ctx.report(
        offset,
        "no-discard-call",
        "'_ = call()' discards a result; handle or name it",
        .{},
    );
}

fn checkPubAnyerror(ctx: *Ctx, node: Ast.Node.Index) !void {
    const proto, _ = ctx.tree.nodeData(node).node_and_node;
    const first = ctx.tree.firstToken(node);
    if (ctx.tree.tokenTag(first) != .keyword_pub) return;
    const last = ctx.tree.lastToken(proto);
    var token = first;
    while (token <= last) : (token += 1) {
        if (ctx.tree.tokenTag(token) != .identifier) continue;
        if (!std.mem.eql(u8, ctx.tree.tokenSlice(token), "anyerror")) continue;
        const offset = ctx.tree.tokenStart(token);
        if (ctx.inTest(offset)) return;
        return ctx.report(
            offset,
            "no-anyerror-pub",
            "anyerror in a pub signature; declare the error set",
            .{},
        );
    }
}
