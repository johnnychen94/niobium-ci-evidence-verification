//! Runtime accent derivation for product branding. A brand accent replaces the accent roles
//! of the base theme; it is moved toward black (light) or white (dark) until both the label
//! on it and the accent as link text on the background reach 4.5:1, or it is rejected.

const std = @import("std");
const tokens = @import("ui_tokens");

pub const Color = tokens.Color;
pub const Theme = tokens.Theme;

pub const min_contrast = 4.5;
const max_steps = 20;

pub const Error = error{ UiAccentInvalid, UiAccentRejected };

fn channel(value: u8) f64 {
    const c = @as(f64, @floatFromInt(value)) / 255.0;
    return if (c <= 0.03928) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
}

fn luminance(c: Color) f64 {
    return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/// WCAG 2 contrast ratio.
pub fn contrast(a: Color, b: Color) f64 {
    const la = luminance(a);
    const lb = luminance(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

/// `c` moved `percent` of the way toward `target`.
pub fn mix(c: Color, target: Color, percent: u8) Color {
    const p: u32 = percent;
    const blend = struct {
        fn f(from: u8, to: u8, amount: u32) u8 {
            return @intCast((@as(u32, from) * (100 - amount) + @as(u32, to) * amount + 50) / 100);
        }
    }.f;
    return .{
        .r = blend(c.r, target.r, p),
        .g = blend(c.g, target.g, p),
        .b = blend(c.b, target.b, p),
        .a = c.a,
    };
}

/// `#RRGGBB`.
pub fn parseHex(text: []const u8) Error!Color {
    if (text.len != 7 or text[0] != '#') return error.UiAccentInvalid;
    const r = std.fmt.parseInt(u8, text[1..3], 16) catch return error.UiAccentInvalid;
    const g = std.fmt.parseInt(u8, text[3..5], 16) catch return error.UiAccentInvalid;
    const b = std.fmt.parseInt(u8, text[5..7], 16) catch return error.UiAccentInvalid;
    return .{ .r = r, .g = g, .b = b };
}

const black: Color = .{ .r = 0, .g = 0, .b = 0 };
const white: Color = .{ .r = 255, .g = 255, .b = 255 };

/// The base theme with its accent roles derived from `accent`. `dark` selects the direction
/// in which the accent is pushed for contrast.
pub fn branded(base: *const Theme, accent: Color, dark: bool) Error!Theme {
    var t = base.*;
    const label = if (dark) base.accent_text else white;
    const pole = if (dark) white else black;
    var candidate = accent;
    var step: u8 = 0;
    // loop-bound: at most max_steps adjustments of 5% each.
    while (contrast(label, candidate) < min_contrast or contrast(
        candidate,
        base.bg,
    ) < min_contrast) {
        if (step == max_steps) return error.UiAccentRejected;
        step += 1;
        candidate = mix(accent, pole, step * 5);
    }
    t.accent = candidate;
    t.accent_text = label;
    t.accent_hover = mix(candidate, pole, 10);
    t.accent_pressed = mix(candidate, pole, 20);
    t.focus = if (dark) t.accent_hover else candidate;
    return t;
}

/// Whether `accent` can brand both base themes.
pub fn check(accent: Color) Error!void {
    for ([_]bool{ false, true }) |dark| {
        const base = if (dark) &tokens.dark else &tokens.light;
        const t = try branded(base, accent, dark);
        std.debug.assert(contrast(t.accent_text, t.accent) >= min_contrast);
    }
}

test "base themes meet the accent contrast rules they ship with" {
    for ([_]*const Theme{ &tokens.light, &tokens.dark }) |t| {
        try std.testing.expect(contrast(t.accent_text, t.accent) >= min_contrast);
        try std.testing.expect(contrast(t.text, t.bg) >= min_contrast);
    }
    try std.testing.expectApproxEqAbs(@as(f64, 21), contrast(black, white), 0.01);
}

test "a pale brand accent is darkened on light and lightened on dark until it passes" {
    const yellow = try parseHex("#F5C400");
    const light = try branded(&tokens.light, yellow, false);
    try std.testing.expect(contrast(light.accent_text, light.accent) >= min_contrast);
    try std.testing.expect(contrast(light.accent, light.bg) >= min_contrast);
    try std.testing.expect(luminance(light.accent) < luminance(yellow));
    try std.testing.expect(contrast(light.accent_text, light.accent_pressed) >= min_contrast);

    const navy = try parseHex("#102A5C");
    const dark = try branded(&tokens.dark, navy, true);
    try std.testing.expect(contrast(dark.accent_text, dark.accent) >= min_contrast);
    try std.testing.expect(contrast(dark.accent, dark.bg) >= min_contrast);
    try std.testing.expect(luminance(dark.accent) > luminance(navy));
}

test "accents that cannot reach contrast are rejected, malformed ones are invalid" {
    const gray = try parseHex("#595959");
    const mid: Theme = blk: {
        var t = tokens.light;
        t.bg = gray;
        break :blk t;
    };
    try std.testing.expectError(error.UiAccentRejected, branded(&mid, gray, false));
    try std.testing.expect(contrast(black, gray) < min_contrast);
    try std.testing.expectError(error.UiAccentInvalid, parseHex("0B63CE"));
    try std.testing.expectError(error.UiAccentInvalid, parseHex("#0B63CZ"));
}
