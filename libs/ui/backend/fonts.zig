//! The platform UI font for native windows (docs/architecture/ui-engine.md). Offscreen
//! rendering never uses it, so goldens stay on the embedded Inter.
//!
//! - macOS: Inter. SF Pro ships only as a variable font and stb_truetype cannot instance its
//!   semibold weight; Inter shares SF's proportions.
//! - Windows: Segoe UI and Segoe UI Semibold from `%WINDIR%\Fonts`.
//! - Linux: the first static regular/semibold pair found among the common desktop fonts.

const std = @import("std");
const render = @import("ui_render");
const tokens = @import("ui_tokens");

pub const max_font_bytes = 32 << 20;

const Pair = struct { regular: []const u8, semibold: []const u8 };

const linux_pairs = [_]Pair{
    .{
        .regular = "/usr/share/fonts/truetype/ubuntu/Ubuntu-R.ttf",
        .semibold = "/usr/share/fonts/truetype/ubuntu/Ubuntu-M.ttf",
    },
    .{
        .regular = "/usr/share/fonts/opentype/cantarell/Cantarell-Regular.otf",
        .semibold = "/usr/share/fonts/opentype/cantarell/Cantarell-Bold.otf",
    },
    .{
        .regular = "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
        .semibold = "/usr/share/fonts/truetype/noto/NotoSans-SemiBold.ttf",
    },
    .{
        .regular = "/usr/share/fonts/noto/NotoSans-Regular.ttf",
        .semibold = "/usr/share/fonts/noto/NotoSans-SemiBold.ttf",
    },
    .{
        .regular = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        .semibold = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    },
};

fn read(io: std.Io, arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_font_bytes)) catch null;
}

fn pair(io: std.Io, arena: std.mem.Allocator, p: Pair) ?render.font.System {
    const regular = read(io, arena, p.regular) orelse return null;
    const semibold = read(io, arena, p.semibold) orelse return null;
    return .{ .regular = regular, .semibold = semibold };
}

/// The font bytes (owned by `arena`), or null for the embedded face.
pub fn load(
    io: std.Io,
    arena: std.mem.Allocator,
    platform: tokens.Platform,
    environ: *const std.process.Environ.Map,
) ?render.font.System {
    switch (platform) {
        .macos => return null,
        .windows => {
            const root = environ.get("WINDIR") orelse environ.get("SystemRoot") orelse
                "C:\\Windows";
            const regular = std.fmt.allocPrint(arena, "{s}\\Fonts\\segoeui.ttf", .{root}) catch
                return null;
            const semibold = std.fmt.allocPrint(arena, "{s}\\Fonts\\seguisb.ttf", .{root}) catch
                return null;
            return pair(io, arena, .{ .regular = regular, .semibold = semibold });
        },
        .linux => {
            for (linux_pairs) |p| if (pair(io, arena, p)) |found| return found;
            return null;
        },
    }
}

test "missing font files fall back to the embedded face" {
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("WINDIR", "/nonexistent-niobium-test");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(null, load(std.testing.io, a, .windows, &map));
    try std.testing.expectEqual(null, load(std.testing.io, a, .macos, &map));
    const f = try render.Fonts.createWith(std.testing.allocator, .{
        .regular = "not a font",
        .semibold = "",
    });
    defer f.destroy();
    try std.testing.expect(f.width(.{ .style = .body, .size = 13 }, "Install") > 0);
}
