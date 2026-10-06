//! Screens with the real kit and the deterministic measurer: every screen fits its window on
//! every platform, theme and scale with long and CJK copy; flows driven through ui_core input.

const std = @import("std");
const contracts = @import("contracts");
const ui = @import("ui_core");
const tokens = @import("ui_tokens");
const screens = @import("root.zig");

const Controller = screens.Controller;
const Command = screens.Command;

const defaults: screens.controller.Defaults = .{
    .user_location = "/Users/me/Applications/Hello",
    .machine_location = "/Applications/Hello",
};

const Copy = enum { normal, long, cjk };

fn repeat(comptime s: []const u8, comptime n: usize) []const u8 {
    comptime var out: []const u8 = "";
    inline for (0..n) |_| out = out ++ s;
    return out;
}

fn config(c: Copy) contracts.installation.ProductConfig {
    return .{
        .schema = 1,
        .mode = .branded,
        .product_id = "com.example.hello",
        .branding = switch (c) {
            .normal => .{ .product_name = "Hello", .publisher = "Example Ltd.", .license = "MIT" },
            .long => .{
                .product_name = "Hello Professional Workstation Edition für Unternehmen",
                .publisher = "Example Internationale Softwareentwicklungsgesellschaft mbH",
                .welcome_body = "Dieses Programm installiert die Anwendung zusammen mit allen " ++
                    "Komponenten, Verknüpfungen und Dateizuordnungen auf diesem Computer.",
                .license = comptime repeat(
                    "Permission is hereby granted, free of charge, to any person. ",
                    20,
                ),
            },
            .cjk => .{
                .product_name = "你好专业版",
                .publisher = "示例软件有限公司",
                .welcome_body = "安装程序将在此计算机上安装你好专业版，所有下载在更改前都会经过验证。",
                .license = "许可协议",
            },
        },
    };
}

const World = struct {
    arena_state: std.heap.ArenaAllocator,
    c: Controller,
    s: ui.Interaction = .{},
    env: ui.Env,
    current: ui.Frame = undefined, // SAFETY: set by refresh() before any read.

    fn init(op: contracts.ui.Operation, c: Copy, o: ui.testing.EnvOptions) !*World {
        const w = try std.testing.allocator.create(World);
        w.* = .{
            .arena_state = .init(std.testing.allocator),
            .c = undefined, // SAFETY: assigned below before any read.
            .env = ui.testing.env(o),
        };
        const arena = w.arena_state.allocator();
        const cfg = try arena.create(contracts.installation.ProductConfig);
        cfg.* = config(c);
        const vm = try screens.model.viewModel(arena, .{
            .config = cfg,
            .operation = op,
            .fallback_name = "com.example.hello",
            .version = "1.0.0",
            .can_launch = true,
        });
        w.c = .init(arena, vm, defaults);
        try w.refresh();
        return w;
    }

    fn deinit(w: *World) void {
        w.arena_state.deinit();
        std.testing.allocator.destroy(w);
    }

    fn refresh(w: *World) !void {
        const size: ui.geometry.Size = .{
            .w = w.env.px(w.env.metrics.window_width),
            .h = w.env.px(w.env.metrics.window_height),
        };
        const bound = try screens.bindScreen(w.arena_state.allocator(), &w.c, w.env.capabilities);
        w.s.reconcile(bound.tree);
        w.current = try ui.buildFrame(
            @import("ui_kit").Kit,
            w.arena_state.allocator(),
            &w.env,
            bound.tree,
            size,
            &w.s,
        );
    }

    fn send(w: *World, event: ui.input.Event) !?Command {
        const intent = ui.input.handle(
            w.current.tree,
            w.current.layout,
            w.env.direction,
            &w.s,
            event,
        ) orelse return null;
        const command = w.c.handle(intent);
        try w.refresh();
        return command;
    }

    fn key(w: *World, k: ui.input.Key) !?Command {
        return w.send(.{ .key = k });
    }

    fn click(w: *World, id: []const u8) !?Command {
        const r = w.current.layout.rects[w.current.tree.find(id).?];
        const p: ui.geometry.Point = .{
            .x = r.x + @divFloor(r.w, 2),
            .y = r.y + @divFloor(r.h, 2),
        };
        const pressed = try w.send(.{ .pointer_down = p });
        try std.testing.expectEqual(@as(?Command, null), pressed);
        return w.send(.{ .pointer_up = p });
    }
};

fn expectFits(f: ui.Frame, label: []const u8) !void {
    const window = f.layout.rects[0];
    for (f.tree.nodes, 0..) |n, i| {
        if (!ui.input.focusable(n) and n.kind != .text) continue;
        const r = f.layout.visible(@intCast(i));
        if (r.w == 0 and r.h == 0) continue;
        const inside = r.x >= 0 and r.y >= 0 and r.right() <= window.w and r.bottom() <= window.h;
        if (!inside or r.w <= 0) {
            std.log.err("{s}: {t} '{s}' at {f} outside {f}", .{ label, n.kind, n.id, r, window });
            return error.TestUnexpectedResult;
        }
    }
}

test "every screen fits its window across platforms, themes, scales and copy" {
    const vm_states = [_]contracts.ui.Screen{ .welcome, .options, .progress, .failure, .complete };
    for (std.enums.values(tokens.Platform)) |platform| {
        for ([_]u16{ 100, 200 }) |scale| {
            for (std.enums.values(Copy)) |c| {
                const w = try World.init(
                    .install,
                    c,
                    .{
                        .platform = platform,
                        .scale = scale,
                        .theme = if (scale == 200) .dark else .light,
                    },
                );
                defer w.deinit();
                w.c.vm.error_title = "Installation failed";
                w.c.vm.error_message = comptime repeat(
                    "The download did not match its signed hash. ",
                    3,
                );
                w.c.vm.error_code = "TrustHashMismatch";
                for (vm_states) |screen| {
                    w.c.screen = screen;
                    w.c.vm.progress_known = screen == .progress;
                    try w.refresh();
                    const label = try std.fmt.allocPrint(
                        w.arena_state.allocator(),
                        "{t} {t} @{d} {t}",
                        .{ screen, platform, scale, c },
                    );
                    try expectFits(w.current, label);
                }
                w.c.screen = .welcome;
                w.c.vm.show_license = true;
                try w.refresh();
                try expectFits(w.current, "license modal");
            }
        }
    }
}

test "install flow by keyboard: next, pick machine scope, install, complete, launch" {
    const w = try World.init(.install, .normal, .{});
    defer w.deinit();
    try std.testing.expectEqual(@as(?Command, null), try w.key(.enter));
    try std.testing.expectEqual(contracts.ui.Screen.options, w.c.screen);
    try std.testing.expectEqual(@as(?Command, null), try w.key(.tab));
    try std.testing.expectEqualStrings("scope", w.s.focus);
    try std.testing.expectEqual(@as(?Command, null), try w.key(.down));
    try std.testing.expectEqual(contracts.Scope.machine, w.c.vm.scope);
    try std.testing.expectEqualStrings(defaults.machine_location, w.c.vm.location);
    const start = (try w.key(.enter)).?;
    try std.testing.expectEqualDeep(
        Command{ .start = .{ .operation = .install, .scope = .machine } },
        start,
    );
    try std.testing.expectEqual(contracts.ui.Screen.progress, w.c.screen);

    w.c.onEvent(.{ .phase = .download, .progress = 0.5 });
    try std.testing.expectEqualStrings("Downloading", w.c.vm.phase_label);
    try std.testing.expect(w.c.vm.progress_known);
    w.c.finish(.succeeded);
    try w.refresh();
    try std.testing.expectEqual(Command.launch, (try w.key(.enter)).?);
}

test "chosen folder is shown and sent; dismissing the dialog keeps the default" {
    const w = try World.init(
        .install,
        .normal,
        .{ .capabilities = .{ .native_folder_picker = true } },
    );
    defer w.deinit();
    _ = try w.key(.enter);
    try std.testing.expectEqual(Command.choose_folder, (try w.click("location")).?);
    try w.c.folderChosen(null);
    try std.testing.expectEqualStrings(defaults.user_location, w.c.vm.location);
    try w.c.folderChosen("/Volumes/Data/Hello");
    _ = try w.key(.down);
    try std.testing.expectEqualStrings("/Volumes/Data/Hello", w.c.vm.location);
    const start = (try w.click("install")).?;
    try std.testing.expectEqualStrings("/Volumes/Data/Hello", start.start.install_dir.?);
}

test "cancel asks first; Escape keeps going, Stop cancels once" {
    const w = try World.init(.install, .normal, .{});
    defer w.deinit();
    _ = try w.key(.enter);
    _ = try w.key(.enter);
    try std.testing.expectEqual(contracts.ui.Screen.progress, w.c.screen);
    try std.testing.expectEqual(@as(?Command, null), try w.key(.escape));
    try std.testing.expect(w.c.vm.confirm_cancel);
    try std.testing.expect(w.current.tree.find("keep") != null);
    try std.testing.expectEqual(@as(?Command, null), try w.key(.escape));
    try std.testing.expect(!w.c.vm.confirm_cancel);
    _ = try w.click("cancel");
    try std.testing.expectEqual(Command.cancel, (try w.click("stop")).?);
    try std.testing.expect(!w.c.vm.can_cancel);
    try std.testing.expectEqualStrings(screens.copy.canceling, w.c.vm.phase_label);
    w.c.onEvent(.{ .phase = .commit });
    try std.testing.expectEqualStrings(screens.copy.canceling, w.c.vm.phase_label);
    try std.testing.expectEqual(@as(?Command, null), try w.key(.escape));

    w.c.finish(.canceled);
    try w.refresh();
    const again = (try w.key(.enter)).?;
    try std.testing.expectEqual(contracts.ui.Operation.install, again.start.operation);
}

test "uninstall starts from welcome; failures show code and retry only when retryable" {
    const w = try World.init(.uninstall, .normal, .{});
    defer w.deinit();
    try std.testing.expect(w.current.tree.find("next") == null);
    try std.testing.expect(w.current.tree.find("license") == null);
    const start = (try w.key(.enter)).?;
    try std.testing.expectEqual(contracts.ui.Operation.uninstall, start.start.operation);
    w.c.finish(
        .{
            .failed = .{
                .code = "PlatformAccessDenied",
                .message = "Access denied.",
                .retryable = false,
            },
        },
    );
    try w.refresh();
    try std.testing.expect(w.current.tree.find("retry") == null);
    try std.testing.expectEqual(Command.close, (try w.key(.escape)).?);
    try std.testing.expectEqualStrings("Uninstall failed", w.c.vm.error_title);
}

test "license modal opens from the link and closes with Escape" {
    const w = try World.init(.install, .normal, .{});
    defer w.deinit();
    _ = try w.click("license");
    try std.testing.expect(w.c.vm.show_license);
    try std.testing.expectEqual(@as(?Command, null), try w.key(.escape));
    try std.testing.expect(!w.c.vm.show_license);
    try std.testing.expectEqual(Command.close, (try w.key(.escape)).?);
}

test "scope option order matches the controller and branding is validated" {
    const group = screens.templates.options.children[0].children[1];
    try std.testing.expectEqualStrings("scope", group.id.?);
    for (screens.controller.scope_options, group.options) |scope, option| {
        try std.testing.expectEqualStrings(@tagName(scope), option.value);
    }
    try std.testing.expectError(
        error.UiAccentInvalid,
        screens.model.validate(.{ .accent = "blue" }),
    );
    try std.testing.expectError(
        error.UiBrandingInvalid,
        screens.model.validate(.{ .product_name = "\xff" }),
    );
    try screens.model.validate(.{ .accent = "#E0218A" });
    const branded = try screens.model.theme(.{ .accent = "#E0218A" }, .light);
    try std.testing.expect(
        @import("ui_kit").theme.contrast(branded.accent_text, branded.accent) >= 4.5,
    );
}
