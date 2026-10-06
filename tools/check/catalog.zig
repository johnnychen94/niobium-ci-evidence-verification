//! Every case of libs/ui/kit/catalog.zon must have a pixel golden. The types and the case
//! matrix must stay identical to libs/ui/kit/catalog.zig; an unknown field or tag fails here.

const std = @import("std");
const repo = @import("repo");

pub const State = enum { default, hover, pressed, focus, disabled, checked, fallback };
pub const Content = enum { long, cjk, rtl };
pub const Theme = enum { light, dark };

pub const Entry = struct {
    name: []const u8,
    states: []const State,
    themes: []const Theme = &.{ .light, .dark },
    scales: []const u16 = &.{ 150, 200 },
    content: []const Content = &.{},
    width: u16 = 240,
    height: u16 = 64,
};

pub const Catalog = struct {
    components: []const Entry = &.{},
};

pub const catalog_path = "libs/ui/kit/catalog.zon";

pub fn goldenPath(
    arena: std.mem.Allocator,
    entry: Entry,
    variant: []const u8,
    theme: Theme,
    scale: u16,
) ![]const u8 {
    return arena.print(
        "tests/golden/kit/{s}/{s}-{t}@{d}.png",
        .{ entry.name, variant, theme, scale },
    );
}

fn expect(report: *repo.Report, io: std.Io, path: []const u8) !void {
    if (!repo.exists(io, path)) try report.add("{s}: missing golden {s}", .{ catalog_path, path });
}

pub fn check(report: *repo.Report, io: std.Io) !void {
    const bytes = try repo.read(report.arena, io, catalog_path);
    const source = try report.arena.dupeSentinel(u8, bytes, 0);
    var diagnostics: std.zon.parse.Diagnostics = undefined; // SAFETY: initialized by fromSlice.
    const parsed = std.zon.parse.fromSlice(Catalog, .{
        .gpa = report.arena,
        .arena = report.arena,
        .source = source,
        .diagnostics = &diagnostics,
    }) catch {
        return report.add("{s}: invalid catalog ZON", .{catalog_path});
    };
    const a = report.arena;
    for (parsed.components) |entry| {
        for (entry.states) |state| {
            for (entry.themes) |theme| {
                try expect(report, io, try goldenPath(a, entry, @tagName(state), theme, 100));
            }
        }
        for (entry.scales) |scale| {
            for (entry.themes) |theme| {
                try expect(report, io, try goldenPath(a, entry, "default", theme, scale));
            }
        }
        for (entry.content) |content| {
            try expect(report, io, try goldenPath(a, entry, @tagName(content), .light, 100));
        }
    }
}
