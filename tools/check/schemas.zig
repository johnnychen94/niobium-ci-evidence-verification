//! api/schema rules: every object schema is closed; no forbidden (imperative) field anywhere in
//! schemas or example manifests.

const std = @import("std");
const repo = @import("repo");

/// Fields that would turn the manifest into code (principles 1 and 6).
pub const forbidden_fields = [_][]const u8{
    "post_install",  "pre_install",  "post_uninstall", "pre_uninstall", "script", "scripts",
    "hook",          "hooks",        "command",        "commands",      "exec",   "shell",
    "custom_action", "run_as_admin", "eval",
};

pub fn check(report: *repo.Report, io: std.Io, files: repo.Files) !void {
    for (files.paths) |path| {
        const is_schema = std.mem.startsWith(u8, path, "api/schema/") and std.mem.endsWith(
            u8,
            path,
            ".schema.json",
        );
        const is_example = std.mem.startsWith(
            u8,
            path,
            "examples/",
        ) and std.mem.endsWith(u8, path, ".json");
        if (!is_schema and !is_example) continue;
        const bytes = try repo.read(report.arena, io, path);
        const value = std.json.parseFromSliceLeaky(std.json.Value, report.arena, bytes, .{}) catch {
            try report.add("{s}: invalid JSON", .{path});
            continue;
        };
        try walk(report, path, value, is_schema);
    }
}

const max_depth = 64;

fn walk(report: *repo.Report, path: []const u8, root: std.json.Value, is_schema: bool) !void {
    var stack: std.ArrayList(std.json.Value) = .empty;
    try stack.append(report.arena, root);
    var visited: usize = 0;
    while (stack.pop()) |value| {
        visited += 1;
        if (visited > 1_000_000) return report.add("{s}: JSON too large to check", .{path});
        switch (value) {
            .object => |object| {
                if (is_schema) try checkClosed(report, path, object);
                try checkKeys(report, path, object, is_schema);
                for (object.values()) |child| try stack.append(report.arena, child);
            },
            .array => |array| for (array.items) |child| try stack.append(report.arena, child),
            else => {},
        }
    }
}

fn checkClosed(report: *repo.Report, path: []const u8, object: std.json.ObjectMap) !void {
    const is_object_schema = object.get("properties") != null or isObjectType(object.get("type"));
    if (!is_object_schema) return;
    const additional = object.get("additionalProperties") orelse {
        return report.add("{s}: object schema without additionalProperties: false", .{path});
    };
    if (additional != .bool or additional.bool) {
        try report.add("{s}: additionalProperties must be false", .{path});
    }
}

fn isObjectType(value: ?std.json.Value) bool {
    const v = value orelse return false;
    return v == .string and std.mem.eql(u8, v.string, "object");
}

fn checkKeys(
    report: *repo.Report,
    path: []const u8,
    object: std.json.ObjectMap,
    is_schema: bool,
) !void {
    const keys = if (is_schema) blk: {
        const props = object.get("properties") orelse return;
        if (props != .object) return;
        break :blk props.object.keys();
    } else object.keys();
    for (keys) |key| {
        if (isForbidden(key)) try report.add("{s}: forbidden field '{s}'", .{ path, key });
    }
}

pub fn isForbidden(key: []const u8) bool {
    for (forbidden_fields) |name| {
        if (std.ascii.eqlIgnoreCase(key, name)) return true;
    }
    return false;
}

test "forbidden field detection is case-insensitive" {
    try std.testing.expect(isForbidden("Post_Install"));
    try std.testing.expect(!isForbidden("components"));
}
