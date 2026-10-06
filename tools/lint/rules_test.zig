//! Each rule has a failing fixture; the clean fixture must produce no findings.

const std = @import("std");
const context = @import("context.zig");
const token_rules = @import("token_rules.zig");
const ast_rules = @import("ast_rules.zig");

fn rulesFor(arena: std.mem.Allocator, path: []const u8, source: [:0]const u8) ![]const []const u8 {
    var ctx = try context.Ctx.init(arena, path, source);
    try token_rules.run(&ctx);
    try ast_rules.run(&ctx);
    var rules: std.ArrayList([]const u8) = .empty;
    for (ctx.findings.items) |finding| try rules.append(arena, finding.rule);
    return rules.items;
}

fn expectRule(path: []const u8, source: [:0]const u8, rule: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const rules = try rulesFor(arena_state.allocator(), path, source);
    for (rules) |found| {
        if (std.mem.eql(u8, found, rule)) return;
    }
    std.debug.print("expected rule {s}, got {d} findings\n", .{ rule, rules.len });
    return error.TestExpectedRule;
}

test "catch unreachable and empty catch" {
    try expectRule(
        "libs/x/a.zig",
        "fn f() void { g() catch unreachable; }",
        "no-catch-unreachable",
    );
    try expectRule(
        "libs/x/a.zig",
        "fn f() void { g() catch |e| unreachable; }",
        "no-catch-unreachable",
    );
    try expectRule("libs/x/a.zig", "fn f() void { g() catch {}; }", "no-empty-catch");
    try expectRule(
        "libs/x/a.zig",
        "fn f() void { _ = h() orelse unreachable; }",
        "no-orelse-unreachable",
    );
}

test "while (true) needs loop-bound" {
    try expectRule("libs/x/a.zig", "fn f() void { while (true) {} }", "bounded-loop");
}

test "boundaries" {
    try expectRule("libs/x/a.zig", "var counter: u32 = 0;", "no-global-var");
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const framework = try rulesFor(arena_state.allocator(), "libs/x/a.zig", "extern var k: u32;");
    try std.testing.expectEqual(@as(usize, 0), framework.len);
    try expectRule("libs/x/a.zig", "const a = std.heap.page_allocator;", "no-page-allocator");
    try expectRule("libs/x/a.zig", "fn f() void { std.debug.print(\"\", .{}); }", "no-debug-print");
    try expectRule(
        "libs/trust/a.zig",
        "fn f(x: u64) u8 { return @intCast(x); }",
        "parser-int-cast",
    );
    try expectRule(
        "libs/engine/a.zig",
        "fn f(p: *u8) usize { return @intFromPtr(p); }",
        "ptr-cast-allowlist",
    );
    try expectRule(
        "libs/engine/a.zig",
        "fn f() void { _ = std.process.spawn(io, .{}); }",
        "spawn-allowlist",
    );
    try expectRule("libs/engine/a.zig", "fn f() void { @panic(\"x\"); }", "panic-owner");
    try expectRule("libs/contracts/a.zig", "const T = struct { n: usize };", "no-usize-contracts");
}

test "undefined needs SAFETY" {
    try expectRule(
        "libs/x/a.zig",
        "fn f() void { var b: [4]u8 = undefined; _ = &b; }",
        "undefined-safety",
    );
}

test "TigerStyle shape" {
    try expectRule("libs/x/a.zig", "fn f() void { f(); }", "no-recursion");
    try expectRule(
        "libs/x/a.zig",
        "fn f(a: bool, b: bool) void { assert(a and b); }",
        "split-assert",
    );
    try expectRule("libs/x/a.zig", "fn f() void { _ = g(); }", "no-discard-call");
    try expectRule("libs/x/a.zig", "pub fn f() anyerror!void {}", "no-anyerror-pub");
    var long_line: [120:0]u8 = @splat('/');
    @memcpy(long_line[0..12], "const a = 1;");
    try expectRule("libs/x/a.zig", &long_line, "line-length");
}

test "clean fixture has no findings" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const source =
        \\const std = @import("std");
        \\pub fn sum(values: []const u32) error{Overflow}!u32 {
        \\    var total: u32 = 0;
        \\    for (values) |v| total = try std.math.add(u32, total, v);
        \\    return total;
        \\}
        \\test "sum" {
        \\    _ = try sum(&.{1});
        \\}
    ;
    const rules = try rulesFor(arena_state.allocator(), "libs/x/a.zig", source);
    try std.testing.expectEqual(@as(usize, 0), rules.len);
}
