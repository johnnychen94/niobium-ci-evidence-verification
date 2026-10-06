//! Hand-written extern bindings for stb_truetype v1.26 (Zig 0.17 has no @cImport).
//! libc hooks are exported from here so the C object links without libc.

const std = @import("std");

pub const Buf = extern struct {
    data: ?[*]u8,
    cursor: c_int,
    size: c_int,
};

pub const FontInfo = extern struct {
    userdata: ?*anyopaque,
    data: ?[*]u8,
    fontstart: c_int,
    num_glyphs: c_int,
    loca: c_int,
    head: c_int,
    glyf: c_int,
    hhea: c_int,
    hmtx: c_int,
    kern: c_int,
    gpos: c_int,
    svg: c_int,
    index_map: c_int,
    index_to_loc_format: c_int,
    cff: Buf,
    charstrings: Buf,
    gsubrs: Buf,
    subrs: Buf,
    fontdicts: Buf,
    fdselect: Buf,
};

pub extern fn stbtt_GetFontOffsetForIndex(data: [*]const u8, index: c_int) c_int;
pub extern fn stbtt_InitFont(info: *FontInfo, data: [*]const u8, offset: c_int) c_int;
pub extern fn stbtt_FindGlyphIndex(info: *const FontInfo, codepoint: c_int) c_int;
pub extern fn stbtt_ScaleForPixelHeight(info: *const FontInfo, pixels: f32) f32;
pub extern fn stbtt_ScaleForMappingEmToPixels(info: *const FontInfo, pixels: f32) f32;
pub extern fn stbtt_GetFontVMetrics(
    info: *const FontInfo,
    ascent: *c_int,
    descent: *c_int,
    line_gap: *c_int,
) void;
pub extern fn stbtt_GetGlyphHMetrics(
    info: *const FontInfo,
    glyph: c_int,
    advance: *c_int,
    lsb: *c_int,
) void;
pub extern fn stbtt_GetGlyphKernAdvance(info: *const FontInfo, glyph1: c_int, glyph2: c_int) c_int;
pub extern fn stbtt_GetGlyphBitmapBoxSubpixel(
    info: *const FontInfo,
    glyph: c_int,
    scale_x: f32,
    scale_y: f32,
    shift_x: f32,
    shift_y: f32,
    ix0: *c_int,
    iy0: *c_int,
    ix1: *c_int,
    iy1: *c_int,
) void;
pub extern fn stbtt_MakeGlyphBitmapSubpixel(
    info: *const FontInfo,
    output: [*]u8,
    out_w: c_int,
    out_h: c_int,
    out_stride: c_int,
    scale_x: f32,
    scale_y: f32,
    shift_x: f32,
    shift_y: f32,
    glyph: c_int,
) void;
pub extern fn nb_stbtt_fontinfo_size() c_int;

/// Scratch memory handed to stb through FontInfo.userdata. Reset before each glyph;
/// stb never sees the general-purpose heap.
pub const Scratch = struct {
    fba: std.heap.FixedBufferAllocator,

    pub fn init(buffer: []u8) Scratch {
        return .{ .fba = .init(buffer) };
    }

    pub fn reset(scratch: *Scratch) void {
        scratch.fba.reset();
    }
};

export fn nb_stbtt_malloc(size: c_ulonglong, user: ?*anyopaque) ?*anyopaque {
    const scratch: *Scratch = @ptrCast(@alignCast(user orelse return null));
    const len = std.math.cast(usize, size) orelse return null;
    const bytes = scratch.fba.allocator().alignedAlloc(u8, .@"16", len) catch return null;
    return bytes.ptr;
}

export fn nb_stbtt_free(ptr: ?*anyopaque, user: ?*anyopaque) void {
    _ = ptr;
    _ = user;
}

export fn nb_stbtt_assert_fail() noreturn {
    @panic("stb_truetype assertion failed");
}

export fn nb_stbtt_strlen(s: [*:0]const u8) c_ulonglong {
    return std.mem.len(s);
}

export fn nb_stbtt_floor(x: f64) f64 {
    return @floor(x);
}

export fn nb_stbtt_ceil(x: f64) f64 {
    return @ceil(x);
}

export fn nb_stbtt_sqrt(x: f64) f64 {
    return @sqrt(x);
}

export fn nb_stbtt_pow(x: f64, y: f64) f64 {
    return std.math.pow(f64, x, y);
}

export fn nb_stbtt_fmod(x: f64, y: f64) f64 {
    return @rem(x, y);
}

export fn nb_stbtt_cos(x: f64) f64 {
    return @cos(x);
}

export fn nb_stbtt_acos(x: f64) f64 {
    return std.math.acos(x);
}

export fn nb_stbtt_fabs(x: f64) f64 {
    return @abs(x);
}

test "FontInfo layout matches C" {
    try std.testing.expectEqual(@as(c_int, @sizeOf(FontInfo)), nb_stbtt_fontinfo_size());
}
