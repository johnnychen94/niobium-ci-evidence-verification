const std = @import("std");
const fixture = @import("fixture.zig");
const input = @import("input.zig");
const frame_mod = @import("frame.zig");
const geometry = @import("geometry.zig");

const Intent = input.Intent;

fn center(r: geometry.Rect) geometry.Point {
    return .{ .x = r.x + @divFloor(r.w, 2), .y = r.y + @divFloor(r.h, 2) };
}

fn send(f: frame_mod.Frame, s: *input.Interaction, event: input.Event) ?Intent {
    return input.handle(f.tree, f.layout, .ltr, s, event);
}

fn click(f: frame_mod.Frame, s: *input.Interaction, at: geometry.Point) !?Intent {
    try std.testing.expectEqual(@as(?Intent, null), send(f, s, .{ .pointer_down = at }));
    return send(f, s, .{ .pointer_up = at });
}

fn expectAction(expected: @import("ir.zig").Action, got: ?Intent) !void {
    try std.testing.expectEqual(expected, got.?.action);
}

test "tab order follows the tree, skips disabled and fallback controls, and wraps" {
    var w = fixture.World.init();
    defer w.deinit();
    var s: input.Interaction = .{};
    const f = try w.frameOf(.{}, .{}, &s);
    const order = [_][]const u8{ "shortcut", "scope", "license", "cancel", "install", "shortcut" };
    for (order) |id| {
        try std.testing.expectEqual(@as(?Intent, null), send(f, &s, .{ .key = .tab }));
        try std.testing.expectEqualStrings(id, s.focus);
    }
    try std.testing.expect(s.focus_visible);
    _ = send(f, &s, .{ .key = .shift_tab });
    try std.testing.expectEqualStrings("install", s.focus);

    const ringed = try w.frameOf(.{}, .{}, &s);
    const display = try w.snapshot(.display, ringed);
    try std.testing.expect(
        std.mem.find(u8, display, "stroke 533,406 85x32 r0 w2 #0B63CEFF") != null,
    );
}

test "pointer press and release on the same control activates it" {
    var w = fixture.World.init();
    defer w.deinit();
    var s: input.Interaction = .{};
    const f = try w.frameOf(.{}, .{}, &s);
    try expectAction(.install, try click(f, &s, center(fixture.rectOf(f, "install"))));
    try std.testing.expectEqualStrings("install", s.focus);
    try std.testing.expect(!s.focus_visible);

    _ = send(f, &s, .{ .pointer_down = center(fixture.rectOf(f, "install")) });
    try std.testing.expectEqual(@as(?Intent, null), send(f, &s, .{
        .pointer_up = center(fixture.rectOf(f, "cancel")),
    }));

    const toggled = try click(f, &s, center(fixture.rectOf(f, "shortcut")));
    try std.testing.expectEqualStrings("shortcut", toggled.?.toggle);
    const scope = f.tree.find("scope").?;
    const second = f.layout.rects[scope + 2];
    const picked = (try click(f, &s, center(second))).?.select;
    try std.testing.expectEqualStrings("scope", picked.id);
    try std.testing.expectEqual(@as(u32, 1), picked.index);

    _ = send(f, &s, .{ .pointer_move = center(fixture.rectOf(f, "cancel")) });
    try std.testing.expectEqualStrings("cancel", s.hover.id);
    _ = send(f, &s, .{ .pointer_move = .{ .x = 1, .y = 1 } });
    try std.testing.expect(s.hover.none());
    try std.testing.expectEqual(
        @as(?Intent, null),
        try click(f, &s, center(fixture.rectOf(f, "location"))),
    );
}

test "keyboard: enter, space, arrows and escape" {
    var w = fixture.World.init();
    defer w.deinit();
    var s: input.Interaction = .{};
    const f = try w.frameOf(.{}, .{}, &s);
    try expectAction(.install, send(f, &s, .{ .key = .enter }));
    _ = send(f, &s, .{ .key = .tab });
    try std.testing.expectEqualStrings("shortcut", send(f, &s, .{ .key = .space }).?.toggle);
    _ = send(f, &s, .{ .key = .tab });
    try std.testing.expectEqual(@as(u32, 1), send(f, &s, .{ .key = .down }).?.select.index);
    try std.testing.expectEqual(@as(?Intent, null), send(f, &s, .{ .key = .up }));
    const mirrored = input.handle(f.tree, f.layout, .rtl, &s, .{ .key = .left });
    try std.testing.expectEqual(@as(u32, 1), mirrored.?.select.index);
    try expectAction(.cancel, send(f, &s, .{ .key = .escape }));

    var blocked: input.Interaction = .{};
    const disabled = try w.frameOf(.{ .can_install = false }, .{}, &blocked);
    try std.testing.expectEqual(@as(?Intent, null), send(disabled, &blocked, .{ .key = .enter }));
    try std.testing.expectEqual(
        @as(?Intent, null),
        try click(disabled, &blocked, center(fixture.rectOf(disabled, "install"))),
    );
}

test "a modal captures pointer, focus and escape" {
    var w = fixture.World.init();
    defer w.deinit();
    var s: input.Interaction = .{};
    const f = try w.frameOf(.{ .confirm_cancel = true }, .{}, &s);
    try std.testing.expectEqual(
        @as(?Intent, null),
        try click(f, &s, center(fixture.rectOf(f, "license"))),
    );
    for ([_][]const u8{ "keep", "stop", "keep" }) |id| {
        _ = send(f, &s, .{ .key = .tab });
        try std.testing.expectEqualStrings(id, s.focus);
    }
    try expectAction(.close, send(f, &s, .{ .key = .escape }));
    try expectAction(.back, send(f, &s, .{ .key = .enter }));
    var fresh: input.Interaction = .{};
    try expectAction(.close, send(f, &fresh, .{ .key = .enter }));
}

test "wheel scrolls the scroll area under the pointer, clamped to its content" {
    var w = fixture.World.init();
    defer w.deinit();
    var s: input.Interaction = .{};
    const f = try w.frameOf(.{ .confirm_cancel = true }, .{}, &s);
    const details = f.tree.find("details").?;
    const extent = f.layout.scroll[details];
    try std.testing.expect(extent.max > 0);
    _ = send(f, &s, .{ .wheel = .{ .at = center(f.layout.rects[details]), .dy = 1000 } });
    try std.testing.expectEqual(extent.max, s.offsets()[0].offset);

    const scrolled = try w.frameOf(.{ .confirm_cancel = true }, .{}, &s);
    const view = scrolled.layout.rects[details];
    try std.testing.expectEqual(view.y - extent.max, scrolled.layout.rects[details + 1].y);
    const display = try w.snapshot(.display, scrolled);
    try std.testing.expect(std.mem.find(u8, display, "clip ") != null);
    try std.testing.expect(std.mem.find(u8, display, "unclip") != null);
}

test "reconcile drops state for controls that vanished or became disabled" {
    var w = fixture.World.init();
    defer w.deinit();
    var s: input.Interaction = .{ .focus = "install", .hover = .{ .id = "stop" } };
    const f = try w.frameOf(.{ .can_install = false }, .{}, &s);
    s.reconcile(f.tree);
    try std.testing.expectEqualStrings("", s.focus);
    try std.testing.expect(s.hover.none());
}
