//! Pixel and IR goldens (`zig build golden`). Every catalog case renders offscreen and must
//! match `tests/golden/kit/...png` pixel for pixel; every screen renders per platform and
//! theme to `tests/golden/screens/...png`, with UiTree, DisplayList and SemanticTree text
//! snapshots on macOS light. `-Dupdate=<scope>` rewrites one component (or `screens`);
//! mismatches write the actual image under `zig-out/golden-actual/`.

const std = @import("std");
const ui = @import("ui_core");
const kit = @import("ui_kit");
const screens = @import("ui_screens");
const render = @import("ui_render");
const tokens = @import("ui_tokens");
const backend = @import("ui_backend");
const options = @import("suite_options");

const offscreen = backend.offscreen;
const io = std.testing.io;

const Suite = struct {
    arena: std.mem.Allocator,
    failures: std.ArrayList([]const u8) = .empty,
    written: usize = 0,

    fn updating(scope: []const u8) bool {
        const want = options.update_scope orelse return false;
        return std.mem.eql(u8, want, scope);
    }

    fn path(s: *Suite, rel: []const u8) ![]const u8 {
        return std.fs.path.join(s.arena, &.{ options.golden_dir, rel });
    }

    fn write(s: *Suite, full: []const u8, bytes: []const u8) !void {
        const dir = std.fs.path.dirname(full) orelse ".";
        try std.Io.Dir.cwd().createDirPath(io, dir);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full, .data = bytes });
        s.written += 1;
    }

    fn pixels(s: *Suite, scope: []const u8, rel: []const u8, c: *const render.Canvas) !void {
        const full = try s.path(rel);
        const encoded = try render.png.encode(s.arena, render.imageOf(c));
        if (updating(scope)) return s.write(full, encoded);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, full, s.arena, .limited(16 << 20)) catch {
            return s.failures.append(
                s.arena,
                try std.fmt.allocPrint(s.arena, "missing {s}", .{full}),
            );
        };
        const expected = render.png.decode(s.arena, bytes) catch {
            return s.failures.append(
                s.arena,
                try std.fmt.allocPrint(s.arena, "unreadable {s}", .{full}),
            );
        };
        if (expected.width == c.width and expected.height == c.height and
            std.mem.eql(u32, expected.pixels, c.pixels)) return;
        const actual = try std.fs.path.join(s.arena, &.{ "zig-out/golden-actual", rel });
        try s.write(actual, encoded);
        s.written -= 1;
        try s.failures.append(s.arena, try std.fmt.allocPrint(s.arena, "{s}: {d} differi" ++
            "ng pixels (actual: {s})", .{
            full,
            differing(expected, c),
            actual,
        }));
    }

    fn text(s: *Suite, scope: []const u8, rel: []const u8, actual: []const u8) !void {
        const full = try s.path(rel);
        if (updating(scope)) return s.write(full, actual);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, full, s.arena, .limited(16 << 20)) catch {
            return s.failures.append(
                s.arena,
                try std.fmt.allocPrint(s.arena, "missing {s}", .{full}),
            );
        };
        if (std.mem.eql(u8, bytes, actual)) return;
        try s.failures.append(s.arena, try std.fmt.allocPrint(s.arena, "{s} differs", .{full}));
    }

    fn finish(s: *Suite) !void {
        for (s.failures.items) |f| std.log.err("golden: {s}", .{f});
        if (s.failures.items.len > 0) return error.GoldenMismatch;
    }
};

fn differing(expected: render.Image, c: *const render.Canvas) usize {
    if (expected.width != c.width or expected.height != c.height) return c.pixels.len;
    var n: usize = 0;
    for (expected.pixels, c.pixels) |a, b| n += @intFromBool(a != b);
    return n;
}

test "N1-AC-12 kit catalog pixel goldens" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var suite: Suite = .{ .arena = arena_state.allocator() };
    var r = try offscreen.Renderer.init(std.testing.allocator);
    defer r.deinit();
    for (kit.catalog.catalog.components) |entry| {
        for (try kit.catalog.cases(suite.arena, entry)) |case| {
            var c = try r.catalogCase(suite.arena, entry, case);
            defer c.deinit(std.testing.allocator);
            try suite.pixels(entry.name, try kit.catalog.goldenPath(suite.arena, entry, case), &c);
        }
    }
    try suite.finish();
}

fn snapshot(
    arena: std.mem.Allocator,
    f: ui.Frame,
    comptime what: enum { tree, display, semantics },
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    switch (what) {
        .tree => try f.tree.write(&out.writer),
        .display => try f.display.write(&out.writer),
        .semantics => try f.semantics.write(&out.writer),
    }
    return out.written();
}

test "N1-AC-12 N1-AC-11 screen goldens per platform and theme" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var suite: Suite = .{ .arena = arena_state.allocator() };
    var r = try offscreen.Renderer.init(std.testing.allocator);
    defer r.deinit();
    for (std.enums.values(screens.Screen)) |screen| {
        for (std.enums.values(tokens.Platform)) |platform| {
            for (std.enums.values(tokens.ThemeName)) |theme| {
                // High contrast changes colors only; one platform covers it.
                if (tokens.isHighContrast(theme) and platform != .windows) continue;
                var out = try r.screen(
                    suite.arena,
                    .{ .screen = screen, .platform = platform, .theme = theme },
                );
                defer out.canvas.deinit(std.testing.allocator);
                const rel = try std.fmt.allocPrint(
                    suite.arena,
                    "screens/{t}-{t}-{t}.png",
                    .{ screen, platform, theme },
                );
                try suite.pixels("screens", rel, &out.canvas);
                if (platform != .macos or theme != .light) continue;
                inline for (.{ .tree, .display, .semantics }) |what| {
                    const name = try std.fmt.allocPrint(
                        suite.arena,
                        "screens/{t}.{s}.txt",
                        .{ screen, @tagName(what) },
                    );
                    try suite.text("screens", name, try snapshot(suite.arena, out.frame, what));
                }
            }
        }
    }
    try suite.finish();
}
