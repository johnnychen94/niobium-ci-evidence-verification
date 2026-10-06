//! X11 core protocol, the part the installer window needs, as pure functions over bytes: the
//! display name, Xauthority, the connection setup, request encoding and event decoding.
//! Everything read from the server or a file is bounds-checked and length-checked with
//! `std.math.cast`; malformed input is an error, never a panic. Byte order is LSB first.

const std = @import("std");
const ui = @import("ui_core");

pub const Error = error{ UiX11Protocol, UiX11Unsupported, UiNoDisplay };

pub const Display = struct { number: u32 };

/// `:N[.S]`, `unix:N[.S]`. TCP displays are not supported.
pub fn parseDisplay(text: []const u8) Error!Display {
    const colon = std.mem.findScalarLast(u8, text, ':') orelse return error.UiNoDisplay;
    const host = text[0..colon];
    if (host.len > 0 and !std.mem.eql(u8, host, "unix")) return error.UiX11Unsupported;
    const rest = text[colon + 1 ..];
    const end = std.mem.findScalar(u8, rest, '.') orelse rest.len;
    const number = std.fmt.parseInt(u32, rest[0..end], 10) catch return error.UiNoDisplay;
    return .{ .number = number };
}

pub const cookie_name = "MIT-MAGIC-COOKIE-1";

/// The MIT-MAGIC-COOKIE-1 data for a local display, or null when the file has none.
pub fn findCookie(file: []const u8, display: u32) ?[]const u8 {
    var r: Reader = .{ .bytes = file };
    var number_buf: [10]u8 = undefined; // SAFETY: bufPrint writes before the slice is read.
    const number = std.fmt.bufPrint(&number_buf, "{d}", .{display}) catch return null;
    // loop-bound: every entry consumes at least the 10 bytes of its header fields.
    while (r.remaining() > 0) {
        const family = r.u16be() catch return null;
        r.skip(r.u16be() catch return null) catch return null; // address
        const num = r.counted() catch return null;
        const name = r.counted() catch return null;
        const data = r.counted() catch return null;
        const local = family == 256 or family == 65535;
        const matches = num.len == 0 or std.mem.eql(u8, num, number);
        if (local and matches and std.mem.eql(u8, name, cookie_name)) return data;
    }
    return null;
}

/// Bounds-checked little-endian reader (big-endian for Xauthority's fields).
const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn remaining(r: *const Reader) usize {
        return r.bytes.len - r.at;
    }

    fn take(r: *Reader, n: usize) Error![]const u8 {
        if (n > r.remaining()) return error.UiX11Protocol;
        defer r.at += n;
        return r.bytes[r.at..][0..n];
    }

    fn u8le(r: *Reader) Error!u8 {
        return (try r.take(1))[0];
    }

    fn u16le(r: *Reader) Error!u16 {
        return std.mem.readInt(u16, (try r.take(2))[0..2], .little);
    }

    fn u32le(r: *Reader) Error!u32 {
        return std.mem.readInt(u32, (try r.take(4))[0..4], .little);
    }

    fn u16be(r: *Reader) Error!u16 {
        return std.mem.readInt(u16, (try r.take(2))[0..2], .big);
    }

    fn counted(r: *Reader) Error![]const u8 {
        return r.take(try r.u16be());
    }

    fn skip(r: *Reader, n: usize) Error!void {
        if (n > r.remaining()) return error.UiX11Protocol;
        r.at += n;
    }
};

fn pad4(n: usize) usize {
    return (4 - n % 4) % 4;
}

/// Connection setup request with an optional MIT-MAGIC-COOKIE-1.
pub fn setupRequest(out: *std.ArrayList(u8), gpa: std.mem.Allocator, cookie: ?[]const u8) !void {
    const name: []const u8 = if (cookie != null) cookie_name else "";
    const data = cookie orelse "";
    const name_len = std.math.cast(u16, name.len) orelse return error.UiX11Protocol;
    const data_len = std.math.cast(u16, data.len) orelse return error.UiX11Protocol;
    var b: Builder = .{ .out = out, .gpa = gpa };
    try b.byte('l');
    try b.byte(0);
    try b.u16le(11);
    try b.u16le(0);
    try b.u16le(name_len);
    try b.u16le(data_len);
    try b.u16le(0);
    try b.bytes(name);
    try b.bytes(data);
}

pub const Setup = struct {
    id_base: u32,
    id_mask: u32,
    /// In 4-byte units.
    max_request: u16,
    min_keycode: u8,
    max_keycode: u8,
    root: u32,
    root_visual: u32,
    root_depth: u8,
    screen_width: u16,
    screen_height: u16,
};

/// Total length of the setup reply once its 8-byte header is in.
pub fn setupLength(header: *const [8]u8) usize {
    return 8 + 4 * @as(usize, std.mem.readInt(u16, header[6..8], .little));
}

/// Parses a complete setup reply. The window needs a 24-bit TrueColor root visual stored as
/// 32 bits per pixel, LSB first, with 0xFF0000 / 0xFF00 / 0xFF masks: the canvas's layout.
pub fn parseSetup(bytes: []const u8) Error!Setup {
    var r: Reader = .{ .bytes = bytes };
    const status = try r.u8le();
    if (status != 1) return error.UiX11Protocol;
    try r.skip(7);
    try r.skip(4); // release
    const id_base = try r.u32le();
    const id_mask = try r.u32le();
    try r.skip(4); // motion buffer
    const vendor_len = try r.u16le();
    const max_request = try r.u16le();
    const screens = try r.u8le();
    const formats = try r.u8le();
    const image_order = try r.u8le();
    try r.skip(3);
    const min_keycode = try r.u8le();
    const max_keycode = try r.u8le();
    try r.skip(4);
    try r.skip(vendor_len + pad4(vendor_len));
    var bpp24: ?u8 = null;
    for (0..formats) |_| {
        const depth = try r.u8le();
        const bpp = try r.u8le();
        try r.skip(6);
        if (depth == 24) bpp24 = bpp;
    }
    if (screens == 0 or image_order != 0 or bpp24 != 32) return error.UiX11Unsupported;
    const root = try r.u32le();
    try r.skip(16);
    const width = try r.u16le();
    const height = try r.u16le();
    try r.skip(8);
    const root_visual = try r.u32le();
    try r.skip(2);
    const root_depth = try r.u8le();
    const depths = try r.u8le();
    if (root_depth != 24) return error.UiX11Unsupported;
    if (!try visualIsRgb(&r, depths, root_visual)) return error.UiX11Unsupported;
    return .{
        .id_base = id_base,
        .id_mask = id_mask,
        .max_request = max_request,
        .min_keycode = min_keycode,
        .max_keycode = max_keycode,
        .root = root,
        .root_visual = root_visual,
        .root_depth = root_depth,
        .screen_width = width,
        .screen_height = height,
    };
}

fn visualIsRgb(r: *Reader, depths: u8, id: u32) Error!bool {
    for (0..depths) |_| {
        try r.skip(2);
        const visuals = try r.u16le();
        try r.skip(4);
        for (0..visuals) |_| {
            const visual = try r.u32le();
            const class = try r.u8le();
            try r.skip(3);
            const red = try r.u32le();
            const green = try r.u32le();
            const blue = try r.u32le();
            try r.skip(4);
            if (visual != id) continue;
            return class == 4 and red == 0xFF0000 and green == 0xFF00 and blue == 0xFF;
        }
    }
    return false;
}

/// Appends one request; `finish` writes its length in 4-byte units.
pub const Builder = struct {
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    start: usize = 0,

    pub fn begin(out: *std.ArrayList(u8), gpa: std.mem.Allocator, code: u8, data: u8) !Builder {
        var b: Builder = .{ .out = out, .gpa = gpa, .start = out.items.len };
        try b.byte(code);
        try b.byte(data);
        try b.u16le(0);
        return b;
    }

    pub fn finish(b: *Builder) !void {
        try b.out.appendNTimes(b.gpa, 0, pad4(b.out.items.len - b.start));
        const words = (b.out.items.len - b.start) / 4;
        const len = std.math.cast(u16, words) orelse return error.UiX11Protocol;
        std.mem.writeInt(u16, b.out.items[b.start + 2 ..][0..2], len, .little);
    }

    pub fn byte(b: *Builder, v: u8) !void {
        try b.out.append(b.gpa, v);
    }

    pub fn u16le(b: *Builder, v: u16) !void {
        try b.out.appendSlice(b.gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, v)));
    }

    pub fn i16le(b: *Builder, v: i16) !void {
        try b.u16le(@bitCast(v));
    }

    pub fn u32le(b: *Builder, v: u32) !void {
        try b.out.appendSlice(b.gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
    }

    pub fn bytes(b: *Builder, v: []const u8) !void {
        try b.out.appendSlice(b.gpa, v);
        try b.out.appendNTimes(b.gpa, 0, pad4(v.len));
    }
};

pub const opcode = struct {
    pub const create_window = 1;
    pub const map_window = 8;
    pub const configure_window = 12;
    pub const intern_atom = 16;
    pub const change_property = 18;
    pub const get_property = 20;
    pub const create_gc = 55;
    pub const put_image = 72;
    pub const get_image = 73;
    pub const get_keyboard_mapping = 101;
};

pub const atom = struct {
    pub const atom_type = 4;
    pub const cardinal = 6;
    pub const resource_manager = 23;
    pub const string = 31;
    pub const wm_name = 39;
    pub const wm_normal_hints = 40;
    pub const wm_size_hints = 41;
};

pub const event_mask: u32 = 0x1 | 0x4 | 0x8 | 0x20 | 0x40 | 0x8000 | 0x20000;

/// The longest image strip one PutImage may carry: rows of `width` pixels.
pub fn rowsPerPutImage(max_request: u16, width: usize) usize {
    const bytes = @as(usize, max_request) * 4 -| 24;
    return @max(bytes / @max(width * 4, 1), 1);
}

pub const Event = union(enum) {
    key: struct { keycode: u8, shift: bool },
    button_press: struct { button: u8, at: ui.geometry.Point },
    button_release: struct { button: u8, at: ui.geometry.Point },
    motion: ui.geometry.Point,
    leave,
    /// The last Expose of a series.
    expose,
    configure: struct { width: u16, height: u16 },
    client_message: struct { message_type: u32, data0: u32 },
    property: struct { atom: u32 },
    /// Events the window does not use.
    other,
};

pub const Packet = union(enum) {
    event: Event,
    /// Protocol error: error code, major opcode.
    failure: struct { code: u8, major: u8 },
    /// A reply; `bytes` is the whole reply.
    reply: []const u8,
};

/// Bytes of the packet at the head of `bytes` (null until 32 bytes, or the reply, are in).
pub fn packetLength(bytes: []const u8) ?usize {
    if (bytes.len < 32) return null;
    if (bytes[0] != 1) return 32;
    const extra = std.mem.readInt(u32, bytes[4..8], .little);
    const total = std.math.add(usize, 32, std.math.mul(usize, extra, 4) catch return null) catch
        return null;
    return if (bytes.len >= total) total else null;
}

fn point(p: *const [32]u8) ui.geometry.Point {
    const x: i16 = @bitCast(std.mem.readInt(u16, p[24..26], .little));
    const y: i16 = @bitCast(std.mem.readInt(u16, p[26..28], .little));
    return .{ .x = x, .y = y };
}

pub fn decode(bytes: []const u8) Packet {
    std.debug.assert(bytes.len >= 32);
    const p = bytes[0..32];
    return switch (p[0] & 0x7F) {
        0 => .{ .failure = .{ .code = p[1], .major = p[10] } },
        1 => .{ .reply = bytes },
        2 => .{ .event = .{ .key = .{
            .keycode = p[1],
            .shift = std.mem.readInt(u16, p[28..30], .little) & 1 != 0,
        } } },
        4 => .{ .event = .{ .button_press = .{ .button = p[1], .at = point(p) } } },
        5 => .{ .event = .{ .button_release = .{ .button = p[1], .at = point(p) } } },
        6 => .{ .event = .{ .motion = point(p) } },
        8 => .{ .event = .leave },
        12 => .{ .event = if (std.mem.readInt(u16, p[16..18], .little) == 0) .expose else .other },
        22 => .{ .event = .{ .configure = .{
            .width = std.mem.readInt(u16, p[20..22], .little),
            .height = std.mem.readInt(u16, p[22..24], .little),
        } } },
        28 => .{ .event = .{ .property = .{ .atom = std.mem.readInt(u32, p[8..12], .little) } } },
        33 => .{ .event = .{ .client_message = .{
            .message_type = std.mem.readInt(u32, p[8..12], .little),
            .data0 = std.mem.readInt(u32, p[12..16], .little),
        } } },
        else => .{ .event = .other },
    };
}

/// A GetProperty reply's value bytes (format 8).
pub fn propertyValue(reply: []const u8) Error![]const u8 {
    var r: Reader = .{ .bytes = reply };
    try r.skip(1);
    const format = try r.u8le();
    try r.skip(14);
    const count = try r.u32le();
    try r.skip(12);
    if (format != 8 and count != 0) return error.UiX11Protocol;
    return r.take(count);
}

/// InternAtom reply's atom.
pub fn atomOf(reply: []const u8) Error!u32 {
    var r: Reader = .{ .bytes = reply };
    try r.skip(8);
    return r.u32le();
}

pub const Keymap = struct {
    per_keycode: u8,
    min_keycode: u8,
    keysyms: []const u8,

    /// The unshifted keysym of `keycode`, or 0.
    pub fn keysym(k: Keymap, keycode: u8) u32 {
        if (keycode < k.min_keycode or k.per_keycode == 0) return 0;
        const index = (@as(usize, keycode) - k.min_keycode) * k.per_keycode * 4;
        if (index + 4 > k.keysyms.len) return 0;
        return std.mem.readInt(u32, k.keysyms[index..][0..4], .little);
    }
};

pub fn parseKeymap(reply: []const u8, min_keycode: u8) Error!Keymap {
    var r: Reader = .{ .bytes = reply };
    try r.skip(1);
    const per = try r.u8le();
    try r.skip(2);
    const words = try r.u32le();
    try r.skip(24);
    const len = std.math.mul(usize, words, 4) catch return error.UiX11Protocol;
    return .{ .per_keycode = per, .min_keycode = min_keycode, .keysyms = try r.take(len) };
}

pub fn keyOf(keysym: u32, shift: bool) ?ui.input.Key {
    return switch (keysym) {
        0xff09 => if (shift) .shift_tab else .tab,
        0xfe20 => .shift_tab,
        0xff0d, 0xff8d => .enter,
        0x20 => .space,
        0xff1b => .escape,
        0xff51 => .left,
        0xff52 => .up,
        0xff53 => .right,
        0xff54 => .down,
        else => null,
    };
}

/// `Xft.dpi` from the RESOURCE_MANAGER string, or null.
pub fn xftDpi(resources: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, resources, '\n');
    while (lines.next()) |line| {
        const rest = std.mem.cutPrefix(u8, line, "Xft.dpi:") orelse continue;
        const value = std.mem.trim(u8, rest, " \t");
        const dpi = std.fmt.parseFloat(f64, value) catch return null;
        if (!(dpi >= 48 and dpi <= 480)) return null;
        return std.math.lossyCast(u32, @round(dpi));
    }
    return null;
}

pub const Appearance = struct {
    dark: bool = false,
    high_contrast: bool = false,
    reduced_motion: bool = false,
};

fn truthy(value: []const u8) bool {
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true");
}

fn falsy(value: []const u8) bool {
    return std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false");
}

fn themeName(a: *Appearance, theme: []const u8) void {
    if (std.ascii.findIgnoreCase(theme, "highcontrast") != null) {
        a.high_contrast = true;
        if (std.ascii.findIgnoreCase(theme, "inverse") != null) a.dark = true;
    }
    if (std.ascii.findIgnoreCase(theme, "dark") != null) a.dark = true;
}

/// GTK settings.ini (`[Settings]` keys) and `GTK_THEME`, the settings an X11 client can read
/// without a D-Bus portal.
pub fn appearance(settings_ini: []const u8, gtk_theme: ?[]const u8) Appearance {
    var a: Appearance = .{};
    var lines = std.mem.splitScalar(u8, settings_ini, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "gtk-application-prefer-dark-theme")) {
            if (truthy(value)) a.dark = true;
        } else if (std.mem.eql(u8, key, "gtk-theme-name")) {
            themeName(&a, value);
        } else if (std.mem.eql(u8, key, "gtk-enable-animations")) {
            if (falsy(value)) a.reduced_motion = true;
        }
    }
    if (gtk_theme) |theme| themeName(&a, theme);
    return a;
}

test "display names" {
    try std.testing.expectEqual(@as(u32, 0), (try parseDisplay(":0")).number);
    try std.testing.expectEqual(@as(u32, 1), (try parseDisplay("unix:1.0")).number);
    try std.testing.expectError(error.UiX11Unsupported, parseDisplay("host:0"));
    try std.testing.expectError(error.UiNoDisplay, parseDisplay(""));
    try std.testing.expectError(error.UiNoDisplay, parseDisplay(":x"));
}

fn xauthEntry(out: *std.ArrayList(u8), family: u16, number: []const u8, data: []const u8) !void {
    const a = std.testing.allocator;
    try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u16, family)));
    for ([_][]const u8{ "host", number, cookie_name, data }) |field| {
        const len = std.math.cast(u16, field.len).?;
        try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u16, len)));
        try out.appendSlice(a, field);
    }
}

test "xauthority cookie lookup and truncated files" {
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(std.testing.allocator);
    try xauthEntry(&file, 0, "0", "tcp-cookie");
    try xauthEntry(&file, 256, "1", "other");
    try xauthEntry(&file, 256, "0", "0123456789abcdef");
    try std.testing.expectEqualStrings("0123456789abcdef", findCookie(file.items, 0).?);
    try std.testing.expectEqualStrings("other", findCookie(file.items, 1).?);
    try std.testing.expectEqual(null, findCookie(file.items, 7));
    for (0..file.items.len) |cut| _ = findCookie(file.items[0..cut], 0);
}

fn sampleSetup(a: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var b: Builder = .{ .out = &out, .gpa = a };
    try b.byte(1);
    try b.byte(0);
    try b.u16le(11);
    try b.u16le(0);
    try b.u16le(0); // length, patched below
    for ([_]u32{ 0, 0x400000, 0x1FFFFF, 0 }) |v| try b.u32le(v);
    try b.u16le(4); // vendor length
    try b.u16le(65535);
    for ([_]u8{ 1, 1, 0, 0, 32, 32, 8, 255, 0, 0, 0, 0 }) |v| try b.byte(v);
    try b.bytes("Test");
    for ([_]u8{ 24, 32, 32, 0, 0, 0, 0, 0 }) |v| try b.byte(v);
    for ([_]u32{ 0x1E1, 0x20, 0xFFFFFF, 0, 0 }) |v| try b.u32le(v);
    for ([_]u16{ 1920, 1080, 508, 286, 1, 1 }) |v| try b.u16le(v);
    try b.u32le(0x21); // root visual
    for ([_]u8{ 0, 0, 24, 1 }) |v| try b.byte(v);
    for ([_]u8{ 24, 0 }) |v| try b.byte(v);
    try b.u16le(1);
    try b.u32le(0);
    try b.u32le(0x21);
    for ([_]u8{ 4, 8, 0, 1 }) |v| try b.byte(v);
    for ([_]u32{ 0xFF0000, 0xFF00, 0xFF, 0 }) |v| try b.u32le(v);
    const words = std.math.cast(u16, (out.items.len - 8) / 4).?;
    std.mem.writeInt(u16, out.items[6..8], words, .little);
    return out.toOwnedSlice(a);
}

test "setup reply parses and rejects truncation" {
    const a = std.testing.allocator;
    const bytes = try sampleSetup(a);
    defer a.free(bytes);
    try std.testing.expectEqual(bytes.len, setupLength(bytes[0..8]));
    const s = try parseSetup(bytes);
    try std.testing.expectEqual(@as(u32, 0x1E1), s.root);
    try std.testing.expectEqual(@as(u32, 0x21), s.root_visual);
    try std.testing.expectEqual(@as(u8, 8), s.min_keycode);
    for (0..bytes.len) |cut| {
        if (parseSetup(bytes[0..cut])) |_| return error.TestUnexpectedSuccess else |_| {}
    }
}

test "requests carry their length and events decode" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var b: Builder = try .begin(&out, a, opcode.intern_atom, 0);
    try b.u16le(12);
    try b.u16le(0);
    try b.bytes("WM_PROTOCOLS");
    try b.finish();
    try std.testing.expectEqual(@as(usize, 20), out.items.len);
    try std.testing.expectEqual(@as(u16, 5), std.mem.readInt(u16, out.items[2..4], .little));
    var packet: [32]u8 = @splat(0);
    packet[0] = 4;
    packet[1] = 1;
    std.mem.writeInt(u16, packet[24..26], 30, .little);
    std.mem.writeInt(u16, packet[26..28], 40, .little);
    const p = decode(&packet);
    try std.testing.expectEqual(@as(i32, 40), p.event.button_press.at.y);
    packet[0] = 1;
    std.mem.writeInt(u32, packet[4..8], 0xFFFFFFFF, .little);
    try std.testing.expectEqual(null, packetLength(&packet));
    try std.testing.expectEqual(@as(usize, 51), rowsPerPutImage(65535, 1280));
}

test "dpi and gtk appearance" {
    try std.testing.expectEqual(@as(u32, 192), xftDpi("Xft.antialias:\t1\nXft.dpi:\t192\n").?);
    try std.testing.expectEqual(null, xftDpi("Xft.dpi: lots"));
    const a = appearance(
        "[Settings]\ngtk-theme-name=Adwaita-dark\ngtk-enable-animations=false\n",
        null,
    );
    try std.testing.expect(a.dark);
    try std.testing.expect(a.reduced_motion);
    const hc = appearance("", "HighContrastInverse");
    try std.testing.expect(hc.high_contrast);
    try std.testing.expect(hc.dark);
}
