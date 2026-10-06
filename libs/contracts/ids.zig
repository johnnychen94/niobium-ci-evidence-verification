//! Wire value validators shared by manifest, package, privilege and trust. Pure functions.

const std = @import("std");

pub const reserved_component = "__installer_runtime";

pub const Platform = enum {
    @"macos-aarch64",
    @"macos-x86_64",
    @"windows-x86_64",
    @"windows-aarch64",
    @"linux-x86_64",
    @"linux-aarch64",

    pub fn host(os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) ?Platform {
        return switch (os) {
            .macos => switch (arch) {
                .aarch64 => .@"macos-aarch64",
                .x86_64 => .@"macos-x86_64",
                else => null,
            },
            .windows => switch (arch) {
                .x86_64 => .@"windows-x86_64",
                .aarch64 => .@"windows-aarch64",
                else => null,
            },
            .linux => switch (arch) {
                .x86_64 => .@"linux-x86_64",
                .aarch64 => .@"linux-aarch64",
                else => null,
            },
            else => null,
        };
    }

    pub fn current() ?Platform {
        const builtin = @import("builtin");
        return host(builtin.os.tag, builtin.cpu.arch);
    }
};

pub const Channel = enum { stable, beta, nightly };
pub const Scope = enum { user, machine };

fn allIn(text: []const u8, comptime extra: []const u8) bool {
    for (text) |char| {
        const ok = std.ascii.isLower(char) or std.ascii.isDigit(char) or
            std.mem.findScalar(u8, extra, char) != null;
        if (!ok) return false;
    }
    return true;
}

/// Reverse-domain product id: `[a-z0-9.-]`, 3–128 bytes, dot-separated non-empty labels.
pub fn isProductId(text: []const u8) bool {
    if (text.len < 3 or text.len > 128 or !allIn(text, ".-")) return false;
    if (std.mem.findScalar(u8, text, '.') == null) return false;
    var labels = std.mem.splitScalar(u8, text, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label[0] == '-') return false;
    }
    return true;
}

/// `[a-z0-9_-]`, 1–64 bytes.
pub fn isComponentId(text: []const u8) bool {
    return text.len >= 1 and text.len <= 64 and allIn(text, "_-");
}

pub const Digest = [32]u8;

/// `sha256:` + 64 lowercase hex.
pub fn parseDigest(text: []const u8) ?Digest {
    const prefix = "sha256:";
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    return parseHex32(text[prefix.len..]);
}

/// Exactly 64 lowercase hex characters.
pub fn parseHex32(text: []const u8) ?Digest {
    if (text.len != 64) return null;
    for (text) |char| {
        if (!(std.ascii.isDigit(char) or (char >= 'a' and char <= 'f'))) return null;
    }
    var out: Digest = @splat(0);
    _ = std.fmt.hexToBytes(&out, text) catch return null;
    return out;
}

pub fn hexDigest(digest: Digest) [64]u8 {
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn parseSemver(text: []const u8) ?std.SemanticVersion {
    if (text.len == 0 or text.len > 64) return null;
    return std.SemanticVersion.parse(text) catch null;
}

pub const EntrypointRef = struct { component: []const u8, name: []const u8 };

/// `<component>.<entrypoint-name>`.
pub fn parseEntrypointRef(text: []const u8) ?EntrypointRef {
    const dot = std.mem.findScalar(u8, text, '.') orelse return null;
    const ref: EntrypointRef = .{ .component = text[0..dot], .name = text[dot + 1 ..] };
    if (!isComponentId(ref.component) or !isComponentId(ref.name)) return null;
    return ref;
}

/// `#RRGGBB`.
pub fn parseColor(text: []const u8) ?u32 {
    if (text.len != 7 or text[0] != '#') return null;
    return std.fmt.parseInt(u32, text[1..], 16) catch null;
}

pub const PathError = error{UnsafePath};

/// Normalized relative path (artifact-format-v1): UTF-8, non-empty, at most `max` bytes,
/// `/`-separated, no leading `/`, drive letter, backslash, NUL, empty, `.` or `..` segment.
pub fn checkRelativePath(path: []const u8, max: u16) PathError!void {
    if (path.len == 0 or path.len > max) return error.UnsafePath;
    if (!std.unicode.utf8ValidateSlice(path)) return error.UnsafePath;
    if (path[0] == '/') return error.UnsafePath;
    if (path.len >= 2 and path[1] == ':') return error.UnsafePath;
    if (std.mem.findAny(u8, path, "\\\x00:") != null) return error.UnsafePath;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return error.UnsafePath;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(
            u8,
            segment,
            "..",
        )) return error.UnsafePath;
    }
}

test "ids" {
    try std.testing.expect(isProductId("com.example.hello"));
    try std.testing.expect(!isProductId("Com.Example"));
    try std.testing.expect(!isProductId("nodots"));
    try std.testing.expect(!isProductId("a..b"));
    try std.testing.expect(isComponentId("runtime"));
    try std.testing.expect(!isComponentId("Runtime"));
    const hex16 = "0123456789abcdef";
    const lower = "sha256:" ++ hex16 ++ hex16 ++ hex16 ++ hex16;
    try std.testing.expect(parseDigest(lower) != null);
    try std.testing.expect(parseDigest("sha256:" ++ "ABCDEF0123456789" ++ lower[23..]) == null);
    try std.testing.expect(parseEntrypointRef("runtime.main") != null);
    try std.testing.expect(parseEntrypointRef("runtime") == null);
    try std.testing.expectEqual(@as(?u32, 0x3B5BDB), parseColor("#3B5BDB"));
    try std.testing.expect(parseSemver("1.2.0") != null);
}

test "N1-INV-02 unsafe relative paths are rejected" {
    const bad = [_][]const u8{
        "",       "/etc/passwd", "../x",   "a/../b", "a//b", "a/./b", "C:/x", "a\\b",
        "a\x00b", "a/",          "c:evil", ".",
    };
    for (bad) |path| try std.testing.expectError(error.UnsafePath, checkRelativePath(path, 1024));
    try checkRelativePath("files/bin/hello", 1024);
    try checkRelativePath("files/日本/a.txt", 1024);
}
