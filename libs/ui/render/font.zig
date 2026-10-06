//! Text with the embedded Inter faces through stb_truetype: em-size scaling, pair kerning,
//! quarter-pixel horizontal positioning and a bounded glyph cache. Measuring never
//! allocates and returns exactly the width drawing covers, so layout and pixels agree.

const std = @import("std");
const ui = @import("ui_core");
const stb = @import("stb_truetype");

pub const Error = error{ OutOfMemory, UiFontInvalid };

pub const FaceId = enum(u1) { regular, semibold };

pub const Face = struct {
    info: stb.FontInfo,
    ascent: i32,
    descent: i32,

    fn init(face: *Face, data: []const u8, scratch: *stb.Scratch) Error!void {
        // stb_truetype trusts its input; only OS font files and the embedded faces reach it.
        if (data.len < 12) return error.UiFontInvalid;
        const tags = [_]*const [4]u8{ "\x00\x01\x00\x00", "OTTO", "true", "ttcf" };
        for (tags) |tag| {
            if (std.mem.eql(u8, data[0..4], tag)) break;
        } else return error.UiFontInvalid;
        const offset = stb.stbtt_GetFontOffsetForIndex(data.ptr, 0);
        if (offset < 0) return error.UiFontInvalid;
        if (stb.stbtt_InitFont(&face.info, data.ptr, offset) == 0) return error.UiFontInvalid;
        face.info.userdata = scratch;
        var ascent: c_int = 0;
        var descent: c_int = 0;
        var gap: c_int = 0;
        stb.stbtt_GetFontVMetrics(&face.info, &ascent, &descent, &gap);
        face.ascent = ascent;
        face.descent = descent;
    }

    pub fn scale(face: *const Face, size: i32) f32 {
        return stb.stbtt_ScaleForMappingEmToPixels(&face.info, @floatFromInt(size));
    }
};

pub const Glyph = struct {
    /// Bitmap origin relative to the pen position and baseline.
    x0: i32,
    y0: i32,
    w: i32,
    h: i32,
    alpha: []const u8,
};

const Key = struct { face: FaceId, glyph: u32, size: u16, phase: u2 };

pub const max_cached_glyphs = 4096;
const scratch_bytes = 512 * 1024;
/// Glyphs larger than this (device pixels per side) are not drawn.
pub const max_glyph_side = 512;

pub fn faceOf(style: ui.ir.TextStyle) FaceId {
    return switch (style) {
        .title, .heading => .semibold,
        .body, .caption, .mono => .regular,
    };
}

/// TrueType/OpenType bytes of the platform UI font (static instances, not variable fonts:
/// stb_truetype draws only a variable font's default instance).
pub const System = struct {
    regular: []const u8,
    semibold: []const u8,
};

pub const Fonts = struct {
    gpa: std.mem.Allocator,
    faces: [2]Face,
    scratch_buffer: []u8,
    scratch: stb.Scratch,
    cache: std.AutoHashMapUnmanaged(Key, Glyph) = .empty,
    bitmaps: std.heap.ArenaAllocator,

    /// The embedded Inter faces (goldens, gallery, and the fallback everywhere).
    pub fn create(gpa: std.mem.Allocator) Error!*Fonts {
        return createWith(gpa, null);
    }

    /// Heap-allocated: stb keeps a pointer to `scratch`. `system` bytes must outlive the
    /// fonts; when either system face fails to load, both use Inter so weights stay paired.
    pub fn createWith(gpa: std.mem.Allocator, system: ?System) Error!*Fonts {
        const f = try gpa.create(Fonts);
        errdefer gpa.destroy(f);
        const buffer = try gpa.alloc(u8, scratch_bytes);
        errdefer gpa.free(buffer);
        f.* = .{
            .gpa = gpa,
            .faces = undefined, // SAFETY: both faces are initialized below.
            .scratch_buffer = buffer,
            .scratch = .init(buffer),
            .bitmaps = .init(gpa),
        };
        if (system) |s| {
            if (f.faces[0].init(s.regular, &f.scratch)) |_| {
                if (f.faces[1].init(s.semibold, &f.scratch)) |_| return f else |_| {}
            } else |_| {}
            std.log.info("system font unusable; using the embedded face", .{});
        }
        try f.faces[0].init(@embedFile("font_regular"), &f.scratch);
        try f.faces[1].init(@embedFile("font_semibold"), &f.scratch);
        return f;
    }

    pub fn destroy(f: *Fonts) void {
        f.cache.deinit(f.gpa);
        f.bitmaps.deinit();
        f.gpa.free(f.scratch_buffer);
        f.gpa.destroy(f);
    }

    pub fn face(f: *const Fonts, id: FaceId) *const Face {
        return &f.faces[@backingInt(id)];
    }

    pub fn measurer(f: *Fonts) ui.env.TextMeasurer {
        return .{ .context = f, .width_fn = measureFn };
    }

    fn measureFn(context: *anyopaque, font: ui.env.Font, text: []const u8) i32 {
        const f: *Fonts = @ptrCast(@alignCast(context));
        return f.width(font, text);
    }

    pub fn width(f: *const Fonts, font: ui.env.Font, text: []const u8) i32 {
        var it: Pen = .init(f, font, text);
        // loop-bound: one step per code point of `text`.
        while (it.next()) |_| {}
        return @intFromFloat(@ceil(it.x));
    }

    /// The rasterized glyph, cached. Null for glyphs with no ink (spaces) or oversized ones.
    pub fn glyph(f: *Fonts, id: FaceId, index: u32, size: i32, phase: u2) Error!?Glyph {
        const key: Key = .{ .face = id, .glyph = index, .size = @intCast(size), .phase = phase };
        if (f.cache.get(key)) |g| return if (g.w == 0) null else g;
        if (f.cache.count() >= max_cached_glyphs) {
            f.cache.clearRetainingCapacity();
            // lint-allow(no-discard-call): when capacity cannot be kept the arena frees instead.
            _ = f.bitmaps.reset(.retain_capacity);
        }
        const g = try f.rasterize(id, index, size, phase);
        try f.cache.put(f.gpa, key, g);
        return if (g.w == 0) null else g;
    }

    fn rasterize(f: *Fonts, id: FaceId, index: u32, size: i32, phase: u2) Error!Glyph {
        const fc = f.face(id);
        const s = fc.scale(size);
        const shift = @as(f32, @floatFromInt(phase)) / 4.0;
        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = 0;
        var y1: c_int = 0;
        const g: c_int = @intCast(index);
        stb.stbtt_GetGlyphBitmapBoxSubpixel(&fc.info, g, s, s, shift, 0, &x0, &y0, &x1, &y1);
        const w = x1 - x0;
        const h = y1 - y0;
        if (w <= 0 or h <= 0 or w > max_glyph_side or h > max_glyph_side) {
            return .{ .x0 = 0, .y0 = 0, .w = 0, .h = 0, .alpha = &.{} };
        }
        const alpha = try f.bitmaps.allocator().alloc(u8, @intCast(w * h));
        f.scratch.reset();
        stb.stbtt_MakeGlyphBitmapSubpixel(&fc.info, alpha.ptr, w, h, w, s, s, shift, 0, g);
        return .{ .x0 = x0, .y0 = y0, .w = w, .h = h, .alpha = alpha };
    }
};

/// Walks a run: glyph index and pen position (device pixels from the run start).
pub const Pen = struct {
    face: *const Face,
    scale: f32,
    text: []const u8,
    i: usize = 0,
    previous: c_int = 0,
    x: f32 = 0,

    pub const Step = struct { glyph: u32, x: f32 };

    pub fn init(f: *const Fonts, font: ui.env.Font, text: []const u8) Pen {
        const fc = f.face(faceOf(font.style));
        return .{ .face = fc, .scale = fc.scale(font.size), .text = text };
    }

    /// Next code point; malformed UTF-8 decodes as U+FFFD one byte at a time.
    fn codepoint(p: *Pen) ?u21 {
        if (p.i >= p.text.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(p.text[p.i]) catch {
            p.i += 1;
            return 0xFFFD;
        };
        if (p.i + len > p.text.len) {
            p.i += 1;
            return 0xFFFD;
        }
        const cp = std.unicode.utf8Decode(p.text[p.i..][0..len]) catch {
            p.i += 1;
            return 0xFFFD;
        };
        p.i += len;
        return cp;
    }

    pub fn next(p: *Pen) ?Step {
        const cp = p.codepoint() orelse return null;
        const index = stb.stbtt_FindGlyphIndex(&p.face.info, @intCast(cp));
        if (p.previous != 0) {
            const kern = stb.stbtt_GetGlyphKernAdvance(&p.face.info, p.previous, index);
            p.x += @as(f32, @floatFromInt(kern)) * p.scale;
        }
        const at = p.x;
        var advance: c_int = 0;
        var lsb: c_int = 0;
        stb.stbtt_GetGlyphHMetrics(&p.face.info, index, &advance, &lsb);
        p.x += @as(f32, @floatFromInt(advance)) * p.scale;
        p.previous = index;
        return .{ .glyph = @intCast(index), .x = at };
    }
};

/// Baseline of a line box `line_height` tall starting at `top`, centering the face's
/// ascent + descent.
pub fn baseline(fc: *const Face, size: i32, top: i32, line_height: i32) i32 {
    const s = fc.scale(size);
    const ascent = @as(f32, @floatFromInt(fc.ascent)) * s;
    const content = ascent - @as(f32, @floatFromInt(fc.descent)) * s;
    const lead = (@as(f32, @floatFromInt(line_height)) - content) / 2;
    return top + @as(i32, @intFromFloat(@round(lead + ascent)));
}

test "measuring is monotonic, kerned and matches the pen" {
    const f = try Fonts.create(std.testing.allocator);
    defer f.destroy();
    const body: ui.env.Font = .{ .style = .body, .size = 13 };
    const a = f.width(body, "Install");
    const b = f.width(body, "Install Hello");
    try std.testing.expect(a > 20 and a < 60);
    try std.testing.expect(b > a);
    try std.testing.expectEqual(@as(i32, 0), f.width(body, ""));
    const bold = f.width(.{ .style = .title, .size = 13 }, "Install");
    try std.testing.expect(bold >= a);
    const big = f.width(.{ .style = .body, .size = 26 }, "Install");
    try std.testing.expect(big >= 2 * a - 2 and big <= 2 * a + 2);
    try std.testing.expect(f.width(body, "\xff") > 0);
}

test "glyphs rasterize once and the cache stays bounded" {
    const f = try Fonts.create(std.testing.allocator);
    defer f.destroy();
    const index: u32 = @intCast(stb.stbtt_FindGlyphIndex(&f.faces[0].info, 'H'));
    const g = (try f.glyph(.regular, index, 26, 0)).?;
    try std.testing.expect(g.w > 4 and g.h > 10 and g.y0 < 0);
    const again = (try f.glyph(.regular, index, 26, 0)).?;
    try std.testing.expectEqual(g.alpha.ptr, again.alpha.ptr);
    const space: u32 = @intCast(stb.stbtt_FindGlyphIndex(&f.faces[0].info, ' '));
    try std.testing.expectEqual(@as(?Glyph, null), try f.glyph(.regular, space, 26, 0));
    try std.testing.expect(f.cache.count() <= max_cached_glyphs);
}
