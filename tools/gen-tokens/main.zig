//! tokens.json -> tokens.zig. Unknown fields fail; every contrast pair must reach 4.5:1.
//! Usage: nb-gen-tokens <tokens.json> <out.zig>

const std = @import("std");

const ThemeJson = struct {
    bg: []const u8,
    surface: []const u8,
    text: []const u8,
    text_muted: []const u8,
    accent: []const u8,
    accent_hover: []const u8,
    accent_pressed: []const u8,
    accent_text: []const u8,
    border: []const u8,
    focus: []const u8,
    danger: []const u8,
    success: []const u8,
    warning: []const u8,
    track: []const u8,
    control: []const u8,
    control_hover: []const u8,
    control_pressed: []const u8,
    disabled_bg: []const u8,
    disabled_text: []const u8,
    scrim: []const u8,
};

/// Theme names are the generated `ThemeName` values; `contrast_*` are the system
/// high-contrast modes and win over branding.
const Themes = struct {
    light: ThemeJson,
    dark: ThemeJson,
    contrast_light: ThemeJson,
    contrast_dark: ThemeJson,
};

const theme_names = std.meta.fieldNames(Themes);

const PlatformJson = struct {
    radius_control: u16,
    radius_surface: u16,
    control_height: u16,
    control_min_width: u16,
    body_size: u16,
    body_line: u16,
    heading_size: u16,
    heading_line: u16,
    title_size: u16,
    title_line: u16,
    caption_size: u16,
    caption_line: u16,
    focus_ring: u16,
    window_width: u16,
    window_height: u16,
    primary_on_right: bool,
};

const TokensJson = struct {
    schema: u32,
    themes: Themes,
    contrast_pairs: []const [2][]const u8,
    space: struct { xs: u16, sm: u16, md: u16, lg: u16, xl: u16, xxl: u16 },
    size: struct { logo: u16, list: u16, field: u16, modal: u16 },
    platforms: struct { macos: PlatformJson, windows: PlatformJson, linux: PlatformJson },
    progress: struct { height: u16, indeterminate_period_ms: u32 },
    checkbox: struct { size: u16 },
};

const min_contrast = 4.5;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) return fail("usage: nb-gen-tokens <tokens.json> <out.zig>", .{});
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(1 << 20));
    const tokens = std.json.parseFromSliceLeaky(TokensJson, arena, bytes, .{}) catch |err| {
        return fail("tokens.json: {t}", .{err});
    };
    if (tokens.schema != 1) return fail("tokens.json: unsupported schema {d}", .{tokens.schema});
    try checkContrast(tokens);
    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(&out.writer, tokens);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = out.written() });
}

fn fail(comptime fmt: []const u8, args: anytype) error{TokensInvalid} {
    std.debug.print("gen-tokens: " ++ fmt ++ "\n", args);
    return error.TokensInvalid;
}

const Rgba = struct { r: u8, g: u8, b: u8, a: u8 };

fn parseHex(text: []const u8) error{TokensInvalid}!Rgba {
    if (text.len != 7 and text.len != 9) return fail("color '{s}' must be #RRGGBB[AA]", .{text});
    if (text[0] != '#') return fail("color '{s}' must start with #", .{text});
    const r = std.fmt.parseInt(u8, text[1..3], 16) catch return fail("bad color '{s}'", .{text});
    const g = std.fmt.parseInt(u8, text[3..5], 16) catch return fail("bad color '{s}'", .{text});
    const b = std.fmt.parseInt(u8, text[5..7], 16) catch return fail("bad color '{s}'", .{text});
    const a = if (text.len == 9)
        std.fmt.parseInt(u8, text[7..9], 16) catch return fail("bad color '{s}'", .{text})
    else
        255;
    return .{ .r = r, .g = g, .b = b, .a = a };
}

fn channel(value: u8) f64 {
    const c = @as(f64, @floatFromInt(value)) / 255.0;
    return if (c <= 0.03928) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
}

fn luminance(c: Rgba) f64 {
    return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

pub fn contrastRatio(a: Rgba, b: Rgba) f64 {
    const la = luminance(a);
    const lb = luminance(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

fn themeColor(theme: ThemeJson, name: []const u8) error{TokensInvalid}![]const u8 {
    inline for (comptime std.meta.fieldNames(ThemeJson)) |field_name| {
        if (std.mem.eql(u8, field_name, name)) return @field(theme, field_name);
    }
    return fail("contrast pair names unknown color '{s}'", .{name});
}

fn checkContrast(tokens: TokensJson) error{TokensInvalid}!void {
    inline for (theme_names) |name| {
        const theme = @field(tokens.themes, name);
        for (tokens.contrast_pairs) |pair| {
            const fg = try parseHex(try themeColor(theme, pair[0]));
            const bg = try parseHex(try themeColor(theme, pair[1]));
            const ratio = contrastRatio(fg, bg);
            if (ratio < min_contrast) {
                return fail(
                    "{s}: {s} on {s} contrast {d:.2} < 4.5",
                    .{ name, pair[0], pair[1], ratio },
                );
            }
        }
    }
}

fn emit(w: *std.Io.Writer, tokens: TokensJson) !void {
    try emitPrelude(w);
    try emitThemeType(w);
    inline for (theme_names) |name| try emitTheme(w, name, @field(tokens.themes, name));
    try emitScales(w, tokens);
    try emitMetricsType(w);
    try emitMetrics(w, "macos", tokens.platforms.macos);
    try emitMetrics(w, "windows", tokens.platforms.windows);
    try emitMetrics(w, "linux", tokens.platforms.linux);
    try emitLookups(w);
}

fn emitPrelude(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\//! Generated by tools/gen-tokens from libs/ui/tokens/tokens.json. Do not edit.
        \\
        \\pub const Color = struct {
        \\    r: u8,
        \\    g: u8,
        \\    b: u8,
        \\    a: u8 = 255,
        \\};
        \\
        \\pub const ThemeName = enum { light, dark, contrast_light, contrast_dark };
        \\pub const Platform = enum { macos, windows, linux };
        \\
        \\pub fn isDark(name: ThemeName) bool {
        \\    return name == .dark or name == .contrast_dark;
        \\}
        \\
        \\pub fn isHighContrast(name: ThemeName) bool {
        \\    return name == .contrast_light or name == .contrast_dark;
        \\}
        \\
        \\/// The theme for the system appearance.
        \\pub fn themeName(dark_mode: bool, high_contrast: bool) ThemeName {
        \\    if (high_contrast) return if (dark_mode) .contrast_dark else .contrast_light;
        \\    return if (dark_mode) .dark else .light;
        \\}
        \\
    );
}

fn emitScales(w: *std.Io.Writer, tokens: TokensJson) !void {
    try w.print(
        \\pub const space = struct {{
        \\    pub const xs: u16 = {d};
        \\    pub const sm: u16 = {d};
        \\    pub const md: u16 = {d};
        \\    pub const lg: u16 = {d};
        \\    pub const xl: u16 = {d};
        \\    pub const xxl: u16 = {d};
        \\}};
        \\pub const size = struct {{
        \\    pub const logo: u16 = {d};
        \\    pub const list: u16 = {d};
        \\    pub const field: u16 = {d};
        \\    pub const modal: u16 = {d};
        \\}};
        \\pub const progress_height: u16 = {d};
        \\pub const progress_period_ms: u32 = {d};
        \\pub const checkbox_size: u16 = {d};
        \\
    , .{
        tokens.space.xs,      tokens.space.sm,        tokens.space.md,
        tokens.space.lg,      tokens.space.xl,        tokens.space.xxl,
        tokens.size.logo,     tokens.size.list,       tokens.size.field,
        tokens.size.modal,    tokens.progress.height, tokens.progress.indeterminate_period_ms,
        tokens.checkbox.size,
    });
}

fn emitLookups(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\pub fn theme(name: ThemeName) *const Theme {
        \\    return switch (name) {
        \\        inline else => |n| &@field(@This(), @tagName(n)),
        \\    };
        \\}
        \\
        \\pub fn metrics(platform: Platform) *const Metrics {
        \\    return switch (platform) {
        \\        .macos => &macos,
        \\        .windows => &windows,
        \\        .linux => &linux,
        \\    };
        \\}
        \\
    );
}

fn emitThemeType(w: *std.Io.Writer) !void {
    try w.writeAll("pub const Theme = struct {\n");
    inline for (comptime std.meta.fieldNames(ThemeJson)) |field_name| {
        try w.print("    {s}: Color,\n", .{field_name});
    }
    try w.writeAll("};\n\n");
}

fn emitTheme(w: *std.Io.Writer, name: []const u8, theme: ThemeJson) !void {
    try w.print("pub const {s}: Theme = .{{\n", .{name});
    inline for (comptime std.meta.fieldNames(ThemeJson)) |field_name| {
        const c = try parseHex(@field(theme, field_name));
        try w.print(
            "    .{s} = .{{ .r = {d}, .g = {d}, .b = {d}, .a = {d} }},\n",
            .{ field_name, c.r, c.g, c.b, c.a },
        );
    }
    try w.writeAll("};\n\n");
}

fn emitMetricsType(w: *std.Io.Writer) !void {
    try w.writeAll("pub const Metrics = struct {\n");
    inline for (comptime std.meta.fieldNames(PlatformJson)) |field_name| {
        try w.print(
            "    {s}: {s},\n",
            .{ field_name, @typeName(@FieldType(PlatformJson, field_name)) },
        );
    }
    try w.writeAll("};\n\n");
}

fn emitMetrics(w: *std.Io.Writer, name: []const u8, metrics: PlatformJson) !void {
    try w.print("pub const {s}: Metrics = .{{\n", .{name});
    inline for (comptime std.meta.fieldNames(PlatformJson)) |field_name| {
        try w.print("    .{s} = {any},\n", .{ field_name, @field(metrics, field_name) });
    }
    try w.writeAll("};\n\n");
}

test "contrast ratio of black on white is 21" {
    const ratio = contrastRatio(
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    );
    try std.testing.expectApproxEqAbs(@as(f64, 21.0), ratio, 0.01);
}
