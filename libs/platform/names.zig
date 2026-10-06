//! Validation of the strings a manifest contributes to system integration names. Every host
//! backend builds file names, registry keys and unit names from these; anything that could
//! escape the integration directory or break the target format is rejected up front.

const std = @import("std");
const api = @import("api.zig");

const Error = api.Error;

/// A single file-name segment: no separators, no control characters, no leading dot, no `..`,
/// no characters any of the three platforms reserve.
pub fn segment(text: []const u8) Error![]const u8 {
    if (text.len == 0 or text.len > 128) return error.PlatformIntegrationFailed;
    if (text[0] == '.' or text[0] == ' ') return error.PlatformIntegrationFailed;
    const last = text[text.len - 1];
    if (last == '.' or last == ' ') return error.PlatformIntegrationFailed;
    for (text) |c| {
        if (c < 0x20 or c == 0x7f) return error.PlatformIntegrationFailed;
        if (std.mem.findScalar(u8, "/\\:<>\"|?*%$`", c) != null) {
            return error.PlatformIntegrationFailed;
        }
    }
    return text;
}

/// `[A-Za-z0-9._-]` only; used for unit names, plist labels and registry key names.
pub fn token(text: []const u8) Error![]const u8 {
    if (text.len == 0 or text.len > 128 or text[0] == '.' or text[0] == '-') {
        return error.PlatformIntegrationFailed;
    }
    for (text) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-';
        if (!ok) return error.PlatformIntegrationFailed;
    }
    if (std.mem.find(u8, text, "..") != null) return error.PlatformIntegrationFailed;
    return text;
}

/// A file extension without the dot, lowercase alphanumerics only.
pub fn extension(text: []const u8) Error![]const u8 {
    if (text.len == 0 or text.len > 16) return error.PlatformIntegrationFailed;
    for (text) |c| {
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c)) return error.PlatformIntegrationFailed;
    }
    return text;
}

/// A relative target inside the release: forward slashes, no `..`, no absolute prefix.
pub fn target(text: []const u8) Error![]const u8 {
    if (text.len == 0 or text[0] == '/' or text[0] == '\\') return error.PlatformIntegrationFailed;
    var parts = std.mem.splitScalar(u8, text, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) {
            return error.PlatformIntegrationFailed;
        }
        const checked = try segment(part);
        std.debug.assert(checked.len == part.len);
    }
    return text;
}

/// Suffix that marks a prepared, not yet activated integration file.
pub fn tempName(buffer: []u8, final: []const u8, tx: u64) Error![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}.nb-tx-{d}", .{ final, tx }) catch
        error.PlatformIntegrationFailed;
}

test "integration names reject escapes" {
    const bad = [_][]const u8{ "", ".hidden", "a/b", "a\\b", "..", "x\x00", "C:", "a$b", "tail." };
    for (bad) |text| try std.testing.expectError(error.PlatformIntegrationFailed, segment(text));
    _ = try segment("Hello World");
    _ = try token("com.example.hello-svc_1");
    try std.testing.expectError(error.PlatformIntegrationFailed, token("a b"));
    try std.testing.expectError(error.PlatformIntegrationFailed, token("a..b"));
    _ = try extension("hello");
    try std.testing.expectError(error.PlatformIntegrationFailed, extension("TXT"));
    _ = try target("runtime/bin/hello");
    for ([_][]const u8{ "/abs", "../x", "a//b", "a/./b", "a\\b" }) |text| {
        try std.testing.expectError(error.PlatformIntegrationFailed, target(text));
    }
}
