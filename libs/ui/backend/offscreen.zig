//! Offscreen backend: frames rendered into a canvas with no window. Pixel goldens and the
//! workbench gallery render catalog cases and the five screens through here, with the
//! embedded font only, so the same inputs give the same pixels on every host.

const std = @import("std");
const contracts = @import("contracts");
const ui = @import("ui_core");
const kit = @import("ui_kit");
const screens = @import("ui_screens");
const render = @import("ui_render");
const tokens = @import("ui_tokens");

const catalog = kit.catalog;

pub const Error = render.Error || screens.model.Error || ui.bind_mod.Error ||
    error{ UiCanvasTooLarge, UiCatalogUnknown };

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    fonts: *render.Fonts,

    pub fn init(gpa: std.mem.Allocator) render.font.Error!Renderer {
        return .{ .gpa = gpa, .fonts = try render.Fonts.create(gpa) };
    }

    pub fn deinit(r: *Renderer) void {
        r.fonts.destroy();
    }

    pub fn env(r: *Renderer, o: EnvOptions) ui.Env {
        return .{
            .theme = o.theme,
            .metrics = tokens.metrics(o.platform),
            .scale = o.scale,
            .direction = o.direction,
            .capabilities = o.capabilities,
            .reduced_motion = true,
            .text = r.fonts.measurer(),
        };
    }

    /// The frame's pixels; the caller owns the canvas (`gpa`).
    pub fn frame(r: *Renderer, f: ui.Frame, o: render.Options) Error!render.Canvas {
        const size = f.layout.rects[0];
        var c = try render.Canvas.init(r.gpa, size.w, size.h);
        errdefer c.deinit(r.gpa);
        try render.render(&c, r.fonts, f.display.items(), o);
        return c;
    }

    pub fn catalogCase(
        r: *Renderer,
        arena: std.mem.Allocator,
        entry: catalog.Entry,
        case: catalog.Case,
    ) Error!render.Canvas {
        const sample = try catalog.sample(arena, entry, case);
        const e = try arena.create(ui.Env);
        e.* = r.env(.{
            .theme = tokens.theme(case.theme),
            .scale = case.scale,
            .direction = sample.direction,
            .capabilities = sample.capabilities,
        });
        const viewport: ui.geometry.Size = .{
            .w = e.px(sample.viewport.w),
            .h = e.px(sample.viewport.h),
        };
        const f = try ui.buildFrame(kit.Kit, arena, e, sample.tree, viewport, &sample.interaction);
        return r.frame(f, .{ .placeholder = e.theme.border });
    }

    pub fn screen(r: *Renderer, arena: std.mem.Allocator, s: ScreenCase) Error!Rendered {
        const c = try arena.create(screens.Controller);
        c.* = try sampleController(arena, s.screen);
        const theme = try arena.create(tokens.Theme);
        theme.* = try screens.model.theme(sample_branding, s.theme);
        const e = try arena.create(ui.Env);
        e.* = r.env(.{
            .theme = theme,
            .platform = s.platform,
            .scale = s.scale,
            .capabilities = .{ .native_folder_picker = s.platform != .linux },
        });
        const viewport: ui.geometry.Size = .{
            .w = e.px(e.metrics.window_width),
            .h = e.px(e.metrics.window_height),
        };
        const interaction = try arena.create(ui.Interaction);
        interaction.* = .{};
        const f = try screens.frame(arena, e, c, viewport, interaction);
        return .{ .frame = f, .canvas = try r.frame(f, .{ .placeholder = theme.border }) };
    }
};

pub const EnvOptions = struct {
    theme: *const tokens.Theme,
    platform: tokens.Platform = .macos,
    scale: u16 = 100,
    direction: ui.env.Direction = .ltr,
    capabilities: ui.env.Capabilities = .{},
};

pub const ScreenCase = struct {
    screen: screens.Screen,
    platform: tokens.Platform = .macos,
    theme: tokens.ThemeName = .light,
    scale: u16 = 100,
};

pub const Rendered = struct {
    frame: ui.Frame,
    canvas: render.Canvas,
};

pub const sample_branding: contracts.installation.Branding = .{
    .product_name = "Hello",
    .publisher = "Example Software Ltd.",
    .license = "Permission is hereby granted, free of charge, to any person obtaining a copy " ++
        "of this software, to deal in the software without restriction.",
};

/// The sample product in the state each screen is reviewed in.
pub fn sampleController(arena: std.mem.Allocator, screen: screens.Screen) Error!screens.Controller {
    const config = try arena.create(contracts.installation.ProductConfig);
    config.* = .{
        .schema = 1,
        .mode = .branded,
        .product_id = "com.example.hello",
        .branding = sample_branding,
    };
    const vm = try screens.model.viewModel(arena, .{
        .config = config,
        .operation = .install,
        .fallback_name = "com.example.hello",
        .version = "1.0.0",
        .can_launch = true,
    });
    var c: screens.Controller = .init(arena, vm, .{
        .user_location = "/Users/me/Applications/Hello",
        .machine_location = "/Applications/Hello",
    });
    c.screen = screen;
    switch (screen) {
        .progress => c.onEvent(
            .{ .phase = .download, .progress = 0.37, .message = "hello-1.0.0.tar.zst" },
        ),
        .failure => c.finish(.{ .failed = .{
            .code = "TrustHashMismatch",
            .message = "A downloaded file did not match the signed release. Nothing was changed.",
            .retryable = true,
        } }),
        .complete => c.finish(.succeeded),
        .welcome, .options => {},
    }
    return c;
}

test "every catalog case and screen renders to a canvas of its viewport" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    const entry = catalog.find("button-primary").?;
    var c = try r.catalogCase(
        arena,
        entry,
        .{ .variant = .{ .state = .default }, .theme = .dark, .scale = 200 },
    );
    defer c.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 2 * entry.width), c.width);
    try std.testing.expectEqual(render.canvas.pack(tokens.dark.bg), c.pixels[0]);
    for (std.enums.values(screens.Screen)) |s| {
        var out = try r.screen(arena, .{ .screen = s, .platform = .windows });
        defer out.canvas.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(i32, tokens.windows.window_width), out.canvas.width);
    }
}
