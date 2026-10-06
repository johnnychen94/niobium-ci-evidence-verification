//! ui-workbench: renders the component catalog and the five screens offscreen for visual
//! review. `gallery --out <dir>` writes `<dir>/<UTC>/` with every catalog case, every screen
//! per platform x theme x scale (100, 200), and an index.html that shows them side by side.
//! Advisory: goldens, not the gallery, gate changes. `window [--fail]` opens the native window
//! with a simulated operation.

const std = @import("std");
const core = @import("core");
const kit = @import("ui_kit");
const screens = @import("ui_screens");
const render = @import("ui_render");
const tokens = @import("ui_tokens");
const backend = @import("ui_backend");
const native_window = @import("window.zig");

pub const panic = std.debug.FullPanic(core.crash.panic);
pub const debug = struct {
    pub const handleSegfault = core.crash.handleSegfault;
};

const usage = "usage: ui-workbench gallery --out <dir>\n       ui-workbench window [--fa" ++
    "il|--smoke]\n";

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "window")) {
        const mode: ?native_window.Mode = if (args.len == 2)
            .demo
        else if (args.len == 3 and std.mem.eql(u8, args[2], "--fail"))
            .fail
        else if (args.len == 3 and std.mem.eql(u8, args[2], "--smoke"))
            .smoke
        else
            null;
        if (mode == null) {
            try std.Io.File.stderr().writeStreamingAll(init.io, usage);
            return 2;
        }
        return native_window.run(init, mode.?);
    }
    if (args.len != 4 or !std.mem.eql(
        u8,
        args[1],
        "gallery",
    ) or !std.mem.eql(u8, args[2], "--out")) {
        try std.Io.File.stderr().writeStreamingAll(init.io, usage);
        return 2;
    }
    var stamp: [32]u8 = undefined; // SAFETY: only the written prefix is read.
    var w: std.Io.Writer = .fixed(&stamp);
    try core.crash.writeUtc(&w, std.Io.Clock.real.now(init.io).toSeconds());
    const root = try std.fs.path.join(arena, &.{ args[3], w.buffered() });
    var g: Gallery = .{ .io = init.io, .arena = arena, .root = root, .gpa = init.gpa };
    try g.run();
    var out_buffer: [256]u8 = undefined; // SAFETY: writer scratch.
    var out = std.Io.File.stdout().writerStreaming(init.io, &out_buffer);
    try out.interface.print(
        "gallery: {d} images in {s}/index.html\n",
        .{ g.images.items.len, root },
    );
    try out.interface.flush();
    return 0;
}

const Gallery = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    root: []const u8,
    images: std.ArrayList([]const u8) = .empty,

    fn run(g: *Gallery) !void {
        var r = try backend.offscreen.Renderer.init(g.gpa);
        defer r.deinit();
        for (kit.catalog.catalog.components) |entry| {
            for (try kit.catalog.cases(g.arena, entry)) |case| {
                var c = try r.catalogCase(g.arena, entry, case);
                defer c.deinit(g.gpa);
                try g.save(try kit.catalog.goldenPath(g.arena, entry, case), &c);
            }
        }
        for (std.enums.values(screens.Screen)) |screen| {
            for (std.enums.values(tokens.Platform)) |platform| {
                for (std.enums.values(tokens.ThemeName)) |theme| {
                    for ([_]u16{ 100, 200 }) |scale| {
                        const case: backend.offscreen.ScreenCase = .{
                            .screen = screen,
                            .platform = platform,
                            .theme = theme,
                            .scale = scale,
                        };
                        var out = try r.screen(g.arena, case);
                        defer out.canvas.deinit(g.gpa);
                        const name = "screens/{t}-{t}-{t}@{d}.png";
                        const rel = try std.fmt.allocPrint(g.arena, name, .{
                            screen, platform, theme, scale,
                        });
                        try g.save(rel, &out.canvas);
                    }
                }
            }
        }
        try g.index();
    }

    fn save(g: *Gallery, rel: []const u8, c: *const render.Canvas) !void {
        const path = try std.fs.path.join(g.arena, &.{ g.root, rel });
        try std.Io.Dir.cwd().createDirPath(g.io, std.fs.path.dirname(path).?);
        const bytes = try render.png.encode(g.arena, render.imageOf(c));
        try std.Io.Dir.cwd().writeFile(g.io, .{ .sub_path = path, .data = bytes });
        try g.images.append(g.arena, rel);
    }

    fn index(g: *Gallery) !void {
        var html: std.Io.Writer.Allocating = .init(g.arena);
        const w = &html.writer;
        try w.writeAll("<!doctype html><meta charset=utf-8><title>Niobium UI gallery</title>" ++
            "<style>body{font:13px system-ui;background:#888}figure{display:inline-block;" ++
            "margin:8px;vertical-align:top}figcaption{color:#fff}</style>\n");
        for (g.images.items) |rel| {
            try w.print(
                "<figure><img src=\"{s}\"><figcaption>{s}</figcaption></figure>\n",
                .{ rel, rel },
            );
        }
        const path = try std.fs.path.join(g.arena, &.{ g.root, "index.html" });
        try std.Io.Dir.cwd().writeFile(g.io, .{ .sub_path = path, .data = html.written() });
    }
};
