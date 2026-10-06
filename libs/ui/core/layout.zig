//! Stack layout over the flat UiTree in device pixels. Containers (window, stack, card,
//! radio_group, modal, scroll) are arranged here; leaves are measured by the comptime `Kit`
//! (`Kit.measure(env, node, max_width) Size`). RTL mirrors every rect after arranging.

const std = @import("std");
const ir = @import("ir.zig");
const geometry = @import("geometry.zig");
const env_mod = @import("env.zig");

const Rect = geometry.Rect;
const Size = geometry.Size;
const Env = env_mod.Env;
const Tree = ir.Tree;

pub const Error = error{OutOfMemory};

/// Space a scroll area keeps free at its trailing edge for the kit's scrollbar, whether or
/// not the content overflows (the content width never jumps).
pub const scrollbar_gutter: ir.Token = .md;

pub const ScrollOffset = struct { id: []const u8, offset: i32 };

pub const ScrollExtent = struct {
    /// Applied offset, clamped to [0, max].
    offset: i32 = 0,
    max: i32 = 0,
};

pub const Layout = struct {
    viewport: Size,
    rects: []Rect,
    /// Visible area for each node: the window intersected with every enclosing scroll viewport.
    clips: []Rect,
    scroll: []ScrollExtent,

    pub fn visible(l: Layout, i: u32) Rect {
        return l.rects[i].intersect(l.clips[i]);
    }
};

pub fn compute(
    comptime Kit: type,
    arena: std.mem.Allocator,
    env: *const Env,
    tree: Tree,
    viewport: Size,
    offsets: []const ScrollOffset,
) Error!Layout {
    const count = tree.nodes.len;
    const result: Layout = .{
        .viewport = viewport,
        .rects = try arena.alloc(Rect, count),
        .clips = try arena.alloc(Rect, count),
        .scroll = try arena.alloc(ScrollExtent, count),
    };
    @memset(result.rects, .empty);
    @memset(result.clips, .empty);
    @memset(result.scroll, .{});
    if (count == 0) return result;
    var engine: Engine = .{
        .arena = arena,
        .measure = Kit.measure,
        .env = env,
        .tree = tree,
        .layout = result,
        .offsets = offsets,
    };
    const window: Rect = .{ .x = 0, .y = 0, .w = viewport.w, .h = viewport.h };
    try engine.arrange(0, window, window);
    if (env.direction == .rtl) {
        for (result.rects) |*r| r.* = r.mirrored(viewport.w);
        for (result.clips) |*r| r.* = r.mirrored(viewport.w);
    }
    return result;
}

fn alignOffset(alignment: ir.Align, space: i32, size: i32) i32 {
    return switch (alignment) {
        .start, .stretch => 0,
        .center => @divFloor(space - size, 2),
        .end => space - size,
    };
}

/// `Kit.measure`: the natural size of a leaf offered `max_width`.
pub const Measure = *const fn (env: *const Env, node: *const ir.Node, max_width: i32) Size;

/// Measuring and arranging recurse through containers (natural -> outer -> natural and
/// arrange -> arrangeStack -> arrange); template.check bounds the depth by max_depth.
const Engine = struct {
    arena: std.mem.Allocator,
    measure: Measure,
    env: *const Env,
    tree: Tree,
    layout: Layout,
    offsets: []const ScrollOffset,

    fn node(e: *const Engine, i: u32) *const ir.Node {
        return &e.tree.nodes[i];
    }

    /// Children that take part in the flow; a window's modal is an overlay.
    fn flowChildren(e: *const Engine, i: u32) Error![]u32 {
        var list: std.ArrayList(u32) = .empty;
        var child = e.tree.firstChild(i);
        while (child) |c| : (child = e.tree.nextSibling(c)) {
            if (e.node(c).kind != .modal) try list.append(e.arena, c);
        }
        return list.items;
    }

    fn natural(e: *const Engine, i: u32, max_w: i32) Error!Size {
        const n = e.node(i);
        return switch (n.kind) {
            .window, .stack, .card, .radio_group, .modal => e.stackNatural(i, max_w),
            .scroll => {
                const child = e.tree.firstChild(i) orelse return .zero;
                const gutter = e.env.token(scrollbar_gutter);
                const inner = try e.outer(child, @max(0, max_w - gutter));
                const cap = if (n.max_height == .none) inner.h else e.env.token(n.max_height);
                return .{ .w = inner.w + gutter, .h = @min(inner.h, cap) };
            },
            else => e.measure(e.env, n, max_w),
        };
    }

    /// The size node `i` takes when offered `avail_w`; fill heights resolve in arrange.
    fn outer(e: *const Engine, i: u32, avail_w: i32) Error!Size {
        const n = e.node(i);
        const limit = switch (n.width) {
            .fixed => |t| e.env.token(t),
            .content, .fill => avail_w,
        };
        const nat = try e.natural(i, limit);
        return .{
            .w = switch (n.width) {
                .fixed => limit,
                .fill => avail_w,
                .content => @min(nat.w, avail_w),
            },
            .h = switch (n.height) {
                .fixed => |t| e.env.token(t),
                .content, .fill => nat.h,
            },
        };
    }

    fn stackNatural(e: *const Engine, i: u32, max_w: i32) Error!Size {
        const n = e.node(i);
        const pad = e.env.token(n.padding);
        const gap = e.env.token(n.gap);
        const children = try e.flowChildren(i);
        const gaps = gap * @as(i32, @intCast(@max(children.len, 1) - 1));
        var w: i32 = 0;
        var h: i32 = 0;
        var remaining = @max(0, max_w - 2 * pad);
        for (children) |c| {
            const s = try e.outer(c, remaining);
            if (n.axis == .column) {
                w = @max(w, s.w);
                h += s.h;
            } else {
                const content_w = if (e.node(c).width == .fill)
                    @min((try e.natural(c, remaining)).w, remaining)
                else
                    s.w;
                w += content_w;
                h = @max(h, s.h);
                remaining = @max(0, remaining - content_w - gap);
            }
        }
        if (n.axis == .column) h += gaps else w += gaps;
        return .{ .w = w + 2 * pad, .h = h + 2 * pad };
    }

    fn arrange(e: *Engine, i: u32, rect: Rect, clip: Rect) Error!void {
        e.layout.rects[i] = rect;
        e.layout.clips[i] = clip;
        const n = e.node(i);
        switch (n.kind) {
            .window => {
                try e.arrangeStack(i, rect, clip);
                try e.arrangeModal(i, rect);
            },
            .stack, .card, .radio_group, .modal => try e.arrangeStack(i, rect, clip),
            .scroll => try e.arrangeScroll(i, rect, clip),
            else => {},
        }
    }

    fn arrangeModal(e: *Engine, window: u32, rect: Rect) Error!void {
        var child = e.tree.firstChild(window);
        while (child) |c| : (child = e.tree.nextSibling(c)) {
            if (e.node(c).kind != .modal) continue;
            const margin = e.env.token(.xl);
            const w = @min(e.env.token(.modal), rect.w - 2 * margin);
            const h = @min((try e.natural(c, w)).h, rect.h - 2 * margin);
            const box: Rect = .{
                .x = rect.x + @divFloor(rect.w - w, 2),
                .y = rect.y + @divFloor(rect.h - h, 2),
                .w = w,
                .h = h,
            };
            try e.arrange(c, box, rect);
        }
    }

    fn arrangeScroll(e: *Engine, i: u32, rect: Rect, clip: Rect) Error!void {
        const child = e.tree.firstChild(i) orelse return;
        const content_w = @max(0, rect.w - e.env.token(scrollbar_gutter));
        const content = try e.outer(child, content_w);
        const max = @max(0, content.h - rect.h);
        var offset: i32 = 0;
        for (e.offsets) |o| {
            if (std.mem.eql(u8, o.id, e.node(i).id)) offset = std.math.clamp(o.offset, 0, max);
        }
        e.layout.scroll[i] = .{ .offset = offset, .max = max };
        const box: Rect = .{
            .x = rect.x,
            .y = rect.y - offset,
            .w = content_w,
            .h = @max(content.h, rect.h),
        };
        try e.arrange(child, box, clip.intersect(rect));
    }

    fn arrangeStack(e: *Engine, i: u32, rect: Rect, clip: Rect) Error!void {
        const n = e.node(i);
        const inner = rect.inset(e.env.token(n.padding));
        const children = try e.flowChildren(i);
        if (children.len == 0) return;
        const sizes = try e.arena.alloc(Size, children.len);
        if (n.axis == .column) {
            try e.columnSizes(n, inner, children, sizes);
        } else {
            try e.rowSizes(n, inner, children, sizes);
        }
        const gap = e.env.token(n.gap);
        var cursor = if (n.axis == .column) inner.y else inner.x;
        for (children, sizes) |c, s| {
            const box: Rect = if (n.axis == .column) .{
                .x = inner.x + alignOffset(n.alignment, inner.w, s.w),
                .y = cursor,
                .w = s.w,
                .h = s.h,
            } else .{
                .x = cursor,
                .y = inner.y + alignOffset(n.alignment, inner.h, s.h),
                .w = s.w,
                .h = s.h,
            };
            try e.arrange(c, box, clip);
            cursor += (if (n.axis == .column) s.h else s.w) + gap;
        }
    }

    fn columnSizes(
        e: *Engine,
        n: *const ir.Node,
        inner: Rect,
        children: []const u32,
        sizes: []Size,
    ) Error!void {
        var used: i32 = e.env.token(n.gap) * @as(i32, @intCast(children.len - 1));
        var fills: i32 = 0;
        for (children, sizes) |c, *s| {
            const child = e.node(c);
            const stretch = n.alignment == .stretch and child.width != .fixed;
            const o = try e.outer(c, inner.w);
            s.w = if (stretch) inner.w else o.w;
            const fitted = if (stretch) (try e.outer(c, s.w)).h else o.h;
            s.h = if (child.height == .fill) 0 else fitted;
            if (child.height == .fill) fills += 1 else used += s.h;
        }
        distribute(e.tree, children, sizes, .column, @max(0, inner.h - used), fills);
    }

    fn rowSizes(
        e: *Engine,
        n: *const ir.Node,
        inner: Rect,
        children: []const u32,
        sizes: []Size,
    ) Error!void {
        var used: i32 = e.env.token(n.gap) * @as(i32, @intCast(children.len - 1));
        var fills: i32 = 0;
        for (children, sizes) |c, *s| {
            const child = e.node(c);
            if (child.width == .fill) {
                s.w = 0;
                fills += 1;
            } else {
                s.w = (try e.outer(c, @max(0, inner.w - used))).w;
                used += s.w;
            }
        }
        distribute(e.tree, children, sizes, .row, @max(0, inner.w - used), fills);
        for (children, sizes) |c, *s| {
            const child = e.node(c);
            const stretch = n.alignment == .stretch or child.height == .fill;
            s.h = if (stretch) inner.h else (try e.outer(c, s.w)).h;
            if (child.height == .fixed) s.h = e.env.token(child.height.fixed);
        }
    }
};

/// Splits `space` between fill children along `axis`; the last one takes the remainder.
fn distribute(
    tree: Tree,
    children: []const u32,
    sizes: []Size,
    axis: ir.Axis,
    space: i32,
    fills: i32,
) void {
    if (fills == 0) return;
    const share = @divFloor(space, fills);
    var left = space;
    var seen: i32 = 0;
    for (children, sizes) |c, *s| {
        const n = tree.nodes[c];
        const fill = if (axis == .column) n.height == .fill else n.width == .fill;
        if (!fill) continue;
        seen += 1;
        const part = if (seen == fills) left else share;
        if (axis == .column) s.h = part else s.w = part;
        left -= part;
    }
}
