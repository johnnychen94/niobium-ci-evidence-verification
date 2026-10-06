//! Every build target in `build/targets.zig` must have a row in the tier table of the user site's
//! Platform support page, so a target cannot be added without a tier
//! (docs/adr/0014-tier-based-platform-support.md).

const std = @import("std");

pub const targets_path = "build/targets.zig";
pub const platforms_page = "apps/user-docs/src/content/docs/platforms.md";

pub const Result = union(enum) {
    ok,
    /// The `.name = "..."` pattern matched nothing, so the check would pass vacuously.
    no_targets,
    /// First target name without a tier table row.
    missing: []const u8,
};

pub fn check(source: []const u8, page: []const u8) Result {
    const marker = ".name = \"";
    var found = false;
    var rest = source;
    while (std.mem.find(u8, rest, marker)) |start| {
        rest = rest[start + marker.len ..];
        const end = std.mem.findScalar(u8, rest, '"') orelse break;
        const name = rest[0..end];
        rest = rest[end..];
        found = true;
        if (name.len == 0 or !hasTierRow(page, name)) return .{ .missing = name };
    }
    return if (found) .ok else .no_targets;
}

/// A tier table row starts with the target as inline code: "| `<name>` |".
fn hasTierRow(page: []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);
    const open = "| `";
    const close = "` |";
    var lines = std.mem.splitScalar(u8, page, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, open)) continue;
        const cell = line[open.len..];
        if (std.mem.startsWith(u8, cell, name) and
            std.mem.startsWith(u8, cell[name.len..], close)) return true;
    }
    return false;
}

const page_fixture = "| `aarch64-macos` | 1 |\n| `x86_64-linux` | 1 |\n";

test "targets named on the page pass" {
    const source = ".{ .name = \"aarch64-macos\" },\n.{ .name = \"x86_64-linux\" },\n";
    try std.testing.expectEqual(Result.ok, check(source, page_fixture));
}

test "a target missing from the page is reported" {
    const source = ".{ .name = \"aarch64-macos\" },\n.{ .name = \"x86_64-windows\" },\n";
    try std.testing.expectEqualStrings("x86_64-windows", check(source, page_fixture).missing);
}

test "a name only inside a longer word does not count" {
    const source = ".{ .name = \"x86_64-lin\" },\n";
    try std.testing.expectEqualStrings("x86_64-lin", check(source, page_fixture).missing);
}

test "a mention outside the tier table does not count" {
    const page = "The VM lane exercises `aarch64-linux`.\n| aarch64-linux | 2 |\n";
    const source = ".{ .name = \"aarch64-linux\" },\n";
    try std.testing.expectEqualStrings("aarch64-linux", check(source, page).missing);
}

test "an empty target name is reported" {
    try std.testing.expectEqualStrings("", check(".{ .name = \"\" },\n", page_fixture).missing);
}

test "a source without target names fails instead of passing vacuously" {
    try std.testing.expectEqual(Result.no_targets, check("const x = 1;\n", page_fixture));
}
