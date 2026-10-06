const std = @import("std");
const fixture = @import("fixture.zig");
const bind_mod = @import("bind.zig");
const semantics = @import("semantics.zig");

const expected_tree =
    \\window w=fill h=fill "Install Hello"
    \\  stack column gap=md pad=xl align=start w=fill h=fill
    \\    text title normal w=content h=content "Welcome to Hello"
    \\    text body muted w=content h=content "Installs into your user folder."
    \\    checkbox #shortcut checked w=content h=content "Create a desktop shortcut"
    \\    radio_group #scope gap=sm pad=none align=start w=content h=content "Install for"
    \\      radio_option 0 selected w=content h=content "Just me"
    \\      radio_option 1 w=content h=content "All users"
    \\    folder_picker #location path="/Apps/Hello" fallback=text w=fill h=content "Location"
    \\    spacer w=content h=fill
    \\    stack row gap=md pad=none align=center w=fill h=content
    \\      link #license action=show_license w=content h=content "License"
    \\      spacer w=fill h=content
    \\      button #cancel secondary action=cancel w=content h=content "Cancel"
    \\      button #install primary action=install w=content h=content "Install"
    \\
;

const expected_display =
    \\fill 0,0 640x460 r0 #FFFFFFFF
    \\text 24,24 lh26 title/20 #1C1C1EFF "Welcome to Hello"
    \\text 24,62 lh18 body/13 #1C1C1EFF "Installs into your user folder."
    \\text 24,92 lh18 body/13 #1C1C1EFF "Create a desktop shortcut"
    \\text 24,122 lh18 body/13 #1C1C1EFF "Just me"
    \\text 24,148 lh18 body/13 #1C1C1EFF "All users"
    \\text 24,178 lh18 body/13 #1C1C1EFF "Location"
    \\text 24,413 lh18 body/13 #1C1C1EFF "License"
    \\fill 443,408 80x28 r6 #FFFFFFFF
    \\text 459,408 lh18 body/13 #1C1C1EFF "Cancel"
    \\fill 535,408 81x28 r6 #0B63CEFF
    \\text 551,408 lh18 body/13 #1C1C1EFF "Install"
    \\
;

const expected_semantics =
    \\window "Install Hello" 0,0 640x460
    \\  text "Welcome to Hello" 24,24 192x26
    \\  text "Installs into your user folder." 24,62 217x18
    \\  checkbox #shortcut "Create a desktop shortcut" 24,92 199x18 focusable checked +toggle
    \\  radiogroup #scope "Install for" 24,122 87x44 focusable
    \\    radio "Just me" 24,122 73x18 selected +select
    \\    radio "All users" 24,148 87x18 +select
    \\  text #location "Location" value="/Apps/Hello" 24,178 592x28
    \\  link #license "License" 24,413 49x18 focusable +press
    \\  button #cancel "Cancel" 443,408 80x28 focusable +press
    \\  button #install "Install" 535,408 81x28 focusable +press
    \\
;

test "N1-AC-11 UiTree, DisplayList and SemanticTree snapshots are deterministic" {
    var w = fixture.World.init();
    defer w.deinit();
    const first = try w.frameOf(.{}, .{}, &.{});
    const second = try w.frameOf(.{}, .{}, &.{});
    try std.testing.expectEqualStrings(expected_tree, try w.snapshot(.tree, first));
    try std.testing.expectEqualStrings(expected_display, try w.snapshot(.display, first));
    try std.testing.expectEqualStrings(expected_semantics, try w.snapshot(.semantics, first));
    try std.testing.expectEqualStrings(
        try w.snapshot(.display, first),
        try w.snapshot(.display, second),
    );
    try std.testing.expectEqualStrings(
        try w.snapshot(.semantics, first),
        try w.snapshot(.semantics, second),
    );
}

test "N1-AC-11 scale changes device geometry, not structure" {
    var w = fixture.World.init();
    defer w.deinit();
    const one = try w.frameOf(.{}, .{}, &.{});
    const two = try w.frameOf(.{}, .{ .scale = 200 }, &.{});
    try std.testing.expectEqualStrings(try w.snapshot(.tree, one), try w.snapshot(.tree, two));
    try std.testing.expectEqual(@as(i32, 1280), two.layout.rects[0].w);
    try std.testing.expectEqual(one.layout.rects[2].x * 2, two.layout.rects[2].x);
    try std.testing.expectEqual(one.layout.rects[2].y * 2, two.layout.rects[2].y);
    try std.testing.expectEqual(one.layout.rects[1].w * 2, two.layout.rects[1].w);
    const install = fixture.rectOf(two, "install");
    try std.testing.expectEqual(two.layout.rects[0].w - 48, install.right());
    try std.testing.expectEqual(two.layout.rects[0].h - 48, install.bottom());
    const odd = try w.frameOf(.{}, .{ .scale = 150 }, &.{});
    try std.testing.expectEqual(@as(i32, 36), odd.layout.rects[2].x);
    try std.testing.expectEqual(@as(i32, 960), odd.layout.rects[0].w);
}

test "RTL mirrors every rect inside the window" {
    var w = fixture.World.init();
    defer w.deinit();
    const ltr = try w.frameOf(.{}, .{}, &.{});
    const rtl = try w.frameOf(.{}, .{ .direction = .rtl }, &.{});
    for (ltr.layout.rects, rtl.layout.rects) |a, b| {
        try std.testing.expectEqual(a.mirrored(fixture.viewport.w), b);
    }
    try std.testing.expectEqual(@as(i32, 24), fixture.rectOf(rtl, "install").x);
}

test "capability diagnostics: folder picker falls back to text without a native picker" {
    var w = fixture.World.init();
    defer w.deinit();
    const vm: fixture.ViewModel = .{};
    const plain = try bind_mod.bind(fixture.ViewModel, w.arena(), &fixture.options, &vm, .{});
    try std.testing.expectEqual(@as(usize, 1), plain.diagnostics.len);
    try std.testing.expectEqualStrings("location", plain.diagnostics[0].id);
    try std.testing.expectEqual(.native_folder_picker, plain.diagnostics[0].capability);
    try std.testing.expectEqual(.text, plain.diagnostics[0].resolution);

    const native = try bind_mod.bind(
        fixture.ViewModel,
        w.arena(),
        &fixture.options,
        &vm,
        fixture.native,
    );
    try std.testing.expectEqual(@as(usize, 0), native.diagnostics.len);
    const f = try w.frameOf(.{}, .{ .capabilities = fixture.native }, &.{});
    const node = f.semantics.nodes[findSemantic(f.semantics, "location").?];
    try std.testing.expectEqual(semantics.Role.button, node.role);
    try std.testing.expect(node.focusable and node.actions.press);
}

fn findSemantic(t: semantics.Tree, id: []const u8) ?usize {
    for (t.nodes, 0..) |n, i| if (std.mem.eql(u8, n.id, id)) return i;
    return null;
}

test "visible_bind drops subtrees and enabled_bind disables controls" {
    var w = fixture.World.init();
    defer w.deinit();
    const busy = try w.frameOf(.{ .busy = true, .can_install = false }, .{}, &.{});
    const tree = try w.snapshot(.tree, busy);
    try std.testing.expect(std.mem.find(u8, tree, "progress_bar 37%") != null);
    try std.testing.expect(std.mem.find(u8, tree, "action=install disabled") != null);
    const sem = busy.semantics.nodes[findSemantic(busy.semantics, "install").?];
    try std.testing.expect(sem.state.disabled and !sem.focusable and !sem.actions.press);

    const modal = try w.frameOf(.{ .confirm_cancel = true }, .{}, &.{});
    const box = fixture.rectOf(modal, "details");
    try std.testing.expect(box.h <= 48);
    const dialog = modal.tree.nodes[modal.tree.find("details").?].parent;
    try std.testing.expectEqual(.modal, modal.tree.nodes[dialog].kind);
    const r = modal.layout.rects[dialog];
    try std.testing.expectEqual(@as(i32, 120), r.x);
    try std.testing.expectEqual(@as(i32, 400), r.w);
}
