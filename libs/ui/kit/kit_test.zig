//! Kit behavior over the whole catalog with the deterministic test measurer: every case
//! builds, is deterministic, and draws inside its viewport; plus DisplayList snapshots.

const std = @import("std");
const ui = @import("ui_core");
const kit = @import("root.zig");

const catalog = kit.catalog;

fn frameOf(arena: std.mem.Allocator, entry: catalog.Entry, case: catalog.Case) !ui.Frame {
    const sample = try catalog.sample(arena, entry, case);
    const env = try arena.create(ui.Env);
    env.* = ui.testing.env(.{
        .theme = case.theme,
        .scale = case.scale,
        .direction = sample.direction,
        .capabilities = sample.capabilities,
    });
    const viewport: ui.geometry.Size = .{
        .w = env.px(sample.viewport.w),
        .h = env.px(sample.viewport.h),
    };
    return ui.buildFrame(kit.Kit, arena, env, sample.tree, viewport, &sample.interaction);
}

fn snapshot(arena: std.mem.Allocator, f: ui.Frame) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try f.display.write(&out.writer);
    return out.written();
}

fn expectInside(f: ui.Frame, viewport: ui.geometry.Rect, label: []const u8) !void {
    var clipped: u32 = 0;
    for (f.display.items()) |c| {
        const rect: ?ui.geometry.Rect = switch (c) {
            .clip => {
                clipped += 1;
                continue;
            },
            .unclip => {
                clipped -= 1;
                continue;
            },
            .fill => |x| x.rect,
            .stroke => |x| x.rect,
            .icon => |x| x.rect,
            .image => |x| x.rect,
            .ring => |x| x.rect,
            .text => |x| .{ .x = x.x, .y = x.y, .w = x.font.size, .h = x.line_height },
        };
        if (clipped > 0) continue;
        const r = rect.?;
        const inside = r.x >= 0 and r.y >= 0 and
            r.right() <= viewport.w and r.bottom() <= viewport.h;
        if (!inside) {
            std.log.err("{s}: {f} outside {f}", .{ label, r, viewport });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(@as(u32, 0), clipped);
}

test "every catalog case builds deterministically inside its viewport" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (catalog.catalog.components) |entry| {
        for (try catalog.cases(arena, entry)) |case| {
            const label = try catalog.goldenPath(arena, entry, case);
            const a = try frameOf(arena, entry, case);
            const b = try frameOf(arena, entry, case);
            try std.testing.expectEqualStrings(try snapshot(arena, a), try snapshot(arena, b));
            try expectInside(a, a.layout.rects[0], label);
            try std.testing.expect(a.semantics.nodes.len > 0);
        }
    }
}

test "primary button: hover, focus ring and disabled colors" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entry = catalog.find("button-primary").?;
    const focus = try frameOf(
        arena,
        entry,
        .{ .variant = .{ .state = .focus }, .theme = .light, .scale = 100 },
    );
    try std.testing.expectEqualStrings(
        \\fill 0,0 240x64 r0 #FFFFFFFF
        \\fill 12,12 81x28 r6 #0B63CEFF
        \\text 28,17 lh18 body/13 #FFFFFFFF "Install"
        \\stroke 7,7 91x38 r11 w3 #0B63CEFF
        \\
    , try snapshot(arena, focus));
    const disabled = try frameOf(
        arena,
        entry,
        .{ .variant = .{ .state = .disabled }, .theme = .dark, .scale = 100 },
    );
    try std.testing.expectEqualStrings(
        \\fill 0,0 240x64 r0 #1C1C1FFF
        \\fill 12,12 81x28 r6 #2B2B30FF
        \\text 28,17 lh18 body/13 #6E6E77FF "Install"
        \\
    , try snapshot(arena, disabled));
}

test "checkbox mark moves to the right edge in RTL and scales at 200%" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entry = catalog.find("checkbox").?;
    const rtl = try frameOf(
        arena,
        entry,
        .{ .variant = .{ .content = .rtl }, .theme = .light, .scale = 100 },
    );
    const mark = rtl.display.items()[1].fill.rect;
    const box = rtl.layout.rects[1];
    try std.testing.expectEqual(box.right(), mark.right());
    const label = rtl.display.items()[3].text;
    try std.testing.expect(label.x + 25 * 7 <= mark.x);

    const big = try frameOf(
        arena,
        entry,
        .{ .variant = .{ .state = .default }, .theme = .light, .scale = 200 },
    );
    try std.testing.expectEqual(@as(i32, 32), big.display.items()[1].fill.rect.w);
}

test "modal draws the scrim over the window, scroll draws a thumb after its content" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const modal = try frameOf(
        arena,
        catalog.find("modal").?,
        .{ .variant = .{ .state = .default }, .theme = .light, .scale = 100 },
    );
    var scrim: ?ui.geometry.Rect = null;
    for (modal.display.items()) |c| {
        if (c == .fill and c.fill.color.a == 0x4D) scrim = c.fill.rect;
    }
    try std.testing.expectEqual(modal.layout.rects[0], scrim.?);

    const scroll = try frameOf(
        arena,
        catalog.find("scroll").?,
        .{ .variant = .{ .state = .default }, .theme = .light, .scale = 100 },
    );
    const items = scroll.display.items();
    try std.testing.expect(items[items.len - 2] == .unclip);
    try std.testing.expect(items[items.len - 1] == .fill);
}

test "folder picker fallback is a muted path line with a capability-free frame" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entry = catalog.find("folder-picker").?;
    const f = try frameOf(
        arena,
        entry,
        .{ .variant = .{ .state = .fallback }, .theme = .light, .scale = 100 },
    );
    for (f.display.items()) |c| try std.testing.expect(c != .stroke);
    try std.testing.expectEqual(ui.semantics.Role.text, f.semantics.nodes[1].role);
}
