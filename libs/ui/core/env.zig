//! Everything layout and drawing read besides the tree: tokens, scale, direction, backend
//! capabilities, and the text measurer that ui_render supplies.

const std = @import("std");
const tokens = @import("ui_tokens");
const ir = @import("ir.zig");

pub const Direction = enum { ltr, rtl };

/// What the backend can do natively. A node that needs a missing capability renders through
/// its declared fallback and produces a capability diagnostic.
pub const Capabilities = struct {
    native_folder_picker: bool = false,
};

pub const Capability = std.meta.FieldEnum(Capabilities);

pub const Font = struct {
    style: ir.TextStyle,
    /// Device pixels.
    size: i32,
};

/// Advance width of a UTF-8 run in device pixels. The context belongs to the implementation
/// (ui_render's glyph cache); ui_core never dereferences it.
pub const TextMeasurer = struct {
    context: *anyopaque,
    width_fn: *const fn (context: *anyopaque, font: Font, text: []const u8) i32,

    pub fn width(m: TextMeasurer, font: Font, text: []const u8) i32 {
        return m.width_fn(m.context, font, text);
    }
};

pub const Env = struct {
    theme: *const tokens.Theme,
    metrics: *const tokens.Metrics,
    /// Device pixels per 100 logical pixels: 100, 150 or 200.
    scale: u16 = 100,
    direction: Direction = .ltr,
    capabilities: Capabilities = .{},
    reduced_motion: bool = false,
    /// Animation clock for indeterminate progress, in milliseconds.
    time_ms: u64 = 0,
    text: TextMeasurer,

    /// Logical pixels to device pixels, rounding half up.
    pub fn px(env: *const Env, logical: i32) i32 {
        return @divFloor(logical * @as(i32, env.scale) + 50, 100);
    }

    pub fn token(env: *const Env, t: ir.Token) i32 {
        const logical: u16 = switch (t) {
            .none => 0,
            .xs => tokens.space.xs,
            .sm => tokens.space.sm,
            .md => tokens.space.md,
            .lg => tokens.space.lg,
            .xl => tokens.space.xl,
            .xxl => tokens.space.xxl,
            .logo => tokens.size.logo,
            .list => tokens.size.list,
            .field => tokens.size.field,
            .modal => tokens.size.modal,
        };
        return env.px(logical);
    }

    pub fn font(env: *const Env, style: ir.TextStyle) Font {
        const m = env.metrics;
        const logical = switch (style) {
            .title => m.title_size,
            .heading => m.heading_size,
            .body, .mono => m.body_size,
            .caption => m.caption_size,
        };
        return .{ .style = style, .size = env.px(logical) };
    }

    pub fn lineHeight(env: *const Env, style: ir.TextStyle) i32 {
        const m = env.metrics;
        const logical = switch (style) {
            .title => m.title_line,
            .heading => m.heading_line,
            .body, .mono => m.body_line,
            .caption => m.caption_line,
        };
        return env.px(logical);
    }

    pub fn has(env: *const Env, capability: Capability) bool {
        return switch (capability) {
            .native_folder_picker => env.capabilities.native_folder_picker,
        };
    }
};

test "px rounds half up at fractional scales" {
    const env = @import("testing.zig").env(.{ .scale = 150 });
    try std.testing.expectEqual(@as(i32, 20), env.px(13));
    try std.testing.expectEqual(@as(i32, 24), env.token(.lg));
    try std.testing.expectEqual(@as(i32, 20), env.font(.body).size);
}
