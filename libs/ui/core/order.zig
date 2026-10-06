//! Platform button order (`metrics.primary_on_right`). Templates list a button group with the
//! primary action last, which is the macOS and GNOME order. Windows uses the wizard order
//! `< Back`, primary, then the rest (`Cancel`), so every run of adjacent sibling buttons in a
//! row is stably reordered by that rank. Focus order follows node order, so Tab still walks
//! the buttons left to right.

const std = @import("std");
const ir = @import("ir.zig");

const Tree = ir.Tree;
const Node = ir.Node;

/// `tree` itself when no run needs reordering; otherwise a reordered copy in `arena`.
pub fn buttons(
    arena: std.mem.Allocator,
    tree: Tree,
    primary_on_right: bool,
) error{OutOfMemory}!Tree {
    if (primary_on_right) return tree;
    var nodes: ?[]Node = null;
    for (tree.nodes, 0..) |n, index| {
        if (n.kind != .stack or n.axis != .row) continue;
        const parent: u32 = @intCast(index);
        var child = tree.firstChild(parent);
        // loop-bound: visits each child of the row once.
        while (child) |c| {
            const run_end = runEnd(tree, c);
            if (needsReorder(tree.nodes[c..run_end])) {
                const out = nodes orelse try arena.dupe(Node, tree.nodes);
                nodes = out;
                reorder(out[c..run_end], c);
            }
            child = tree.nextSibling(if (isButtonLeaf(tree, c)) run_end - 1 else c);
        }
    }
    return .{ .nodes = nodes orelse return tree };
}

fn isButtonLeaf(tree: Tree, i: u32) bool {
    const n = tree.nodes[i];
    return n.kind == .button and n.end == i + 1;
}

/// One past the last button of the run starting at `start` (`start + 1` when `start` is not a
/// button).
fn runEnd(tree: Tree, start: u32) u32 {
    var end = start + 1;
    if (!isButtonLeaf(tree, start)) return end;
    // loop-bound: advances over sibling leaves, at most the row's child count.
    while (tree.nextSibling(end - 1)) |next| {
        if (next != end or !isButtonLeaf(tree, next)) break;
        end += 1;
    }
    return end;
}

const ranks = 3;

fn rank(n: Node) u2 {
    if (n.variant == .primary) return 1;
    return if (n.action == .back) 0 else 2;
}

fn needsReorder(run: []const Node) bool {
    if (run.len < 2 or run[0].kind != .button) return false;
    for (run[1..], run[0 .. run.len - 1]) |n, before| {
        if (rank(n) < rank(before)) return true;
    }
    return false;
}

/// Stable sort by rank; each leaf's `end` follows its new index.
fn reorder(run: []Node, first: u32) void {
    var buffer: [32]Node = undefined; // SAFETY: the first `run.len` slots are written below.
    std.debug.assert(run.len <= buffer.len);
    var len: usize = 0;
    for (0..ranks) |r| {
        for (run) |n| {
            if (rank(n) != r) continue;
            buffer[len] = n;
            len += 1;
        }
    }
    for (run, buffer[0..len], 0..) |*dst, src, offset| {
        dst.* = src;
        dst.end = first + @as(u32, @intCast(offset)) + 1;
    }
}

test "windows order is back, primary, then the rest" {
    const nodes = [_]Node{
        .{ .kind = .stack, .axis = .row, .end = 5 },
        .{ .kind = .text, .parent = 0, .end = 2, .text = "Version" },
        .{ .kind = .button, .parent = 0, .end = 3, .id = "cancel" },
        .{ .kind = .button, .parent = 0, .end = 4, .id = "back", .action = .back },
        .{ .kind = .button, .parent = 0, .end = 5, .id = "install", .variant = .primary },
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const tree: Tree = .{ .nodes = &nodes };
    const same = try buttons(arena.allocator(), tree, true);
    try std.testing.expectEqual(tree.nodes.ptr, same.nodes.ptr);
    const out = try buttons(arena.allocator(), tree, false);
    const ids = [_][]const u8{ "", "back", "install", "cancel" };
    for (ids, out.nodes[1..]) |id, n| try std.testing.expectEqualStrings(id, n.id);
    for (out.nodes[1..], 2..) |n, end| try std.testing.expectEqual(@as(u32, @intCast(end)), n.end);
    try std.testing.expectEqualStrings("Version", out.nodes[1].text);
}
