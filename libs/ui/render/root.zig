//! The framework's one software renderer: a BGRA canvas, anti-aliased shapes, text through
//! stb_truetype with the embedded Inter faces, PNG I/O, and the DisplayList executor that
//! every backend and the offscreen goldens share.

const std = @import("std");
const ui = @import("ui_core");

pub const canvas = @import("canvas.zig");
pub const shapes = @import("shapes.zig");
pub const font = @import("font.zig");
pub const png = @import("png.zig");
pub const render_mod = @import("render.zig");

pub const Canvas = canvas.Canvas;
pub const Fonts = font.Fonts;
pub const Image = png.Image;
pub const Options = render_mod.Options;
pub const Images = render_mod.Images;
pub const render = render_mod.render;
pub const Error = render_mod.Error;

comptime {
    // The C object needs the libc hooks that the bindings export.
    _ = @import("stb_truetype");
}

/// Canvas pixels as a PNG-ready image (the canvas layout is already 0xAARRGGBB).
pub fn imageOf(c: *const Canvas) Image {
    return .{ .width = @intCast(c.width), .height = @intCast(c.height), .pixels = c.pixels };
}

test {
    _ = canvas;
    _ = shapes;
    _ = font;
    _ = png;
    _ = render_mod;
    _ = @import("render_test.zig");
    _ = ui;
}
