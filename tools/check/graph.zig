//! Module graph rules: declared edges respect layers, UI isolation, acyclicity; roots exist.

const std = @import("std");
const repo = @import("repo");
const specs = @import("module_specs");

const Layer = specs.Layer;

fn isUi(layer: Layer) bool {
    const value = @backingInt(layer);
    return value >= @backingInt(Layer.ui_base) and value <= @backingInt(Layer.ui_backend);
}

/// Returns a reason when `from -> to` breaks the dependency direction, else null.
pub fn edgeViolation(from: specs.ModuleSpec, to: specs.ModuleSpec) ?[]const u8 {
    if (to.layer == .third_party) return null;
    if (from.layer == .third_party) return "third_party modules may not import project modules";
    if (isUi(from.layer)) {
        if (isUi(to.layer)) {
            if (@backingInt(to.layer) > @backingInt(from.layer)) return "UI import points upward";
            return null;
        }
        if (to.layer == .core or to.layer == .contracts) return null;
        return "UI modules may only import ui_*, contracts, core";
    }
    if (isUi(to.layer)) return "non-UI modules may not import UI modules";
    if (@backingInt(to.layer) > @backingInt(from.layer)) return "import points to a higher layer";
    return null;
}

pub fn check(report: *repo.Report, io: std.Io, files: repo.Files) !void {
    for (specs.specs) |spec| {
        if (!spec.generated and !repo.exists(io, spec.root)) {
            try report.add("module '{s}': root '{s}' missing", .{ spec.name, spec.root });
        }
        for (spec.imports) |name| {
            const target = specs.find(name) orelse {
                try report.add(
                    "module '{s}': imports undeclared module '{s}'",
                    .{ spec.name, name },
                );
                continue;
            };
            if (edgeViolation(spec, target)) |reason| {
                try report.add("edge {s} -> {s}: {s}", .{ spec.name, name, reason });
            }
        }
    }
    if (hasCycle()) try report.add("module graph has a cycle", .{});
    try checkOrphans(report, files);
}

/// Every libs/**/root.zig must be a declared module.
fn checkOrphans(report: *repo.Report, files: repo.Files) !void {
    for (files.paths) |path| {
        if (!std.mem.startsWith(u8, path, "libs/")) continue;
        if (!std.mem.endsWith(u8, path, "/root.zig")) continue;
        if (std.mem.startsWith(u8, path, "libs/ui/kit/") and !std.mem.eql(
            u8,
            path,
            "libs/ui/kit/root.zig",
        )) continue;
        var declared = false;
        for (specs.specs) |spec| {
            if (std.mem.eql(u8, spec.root, path)) declared = true;
        }
        if (!declared) try report.add(
            "{s}: module root not declared in build/modules.zig",
            .{path},
        );
    }
}

/// Kahn's algorithm over the declared edges; bounded by the spec count.
fn hasCycle() bool {
    const n = specs.specs.len;
    var removed: [n]bool = @splat(false);
    var round: usize = 0;
    while (round < n) : (round += 1) {
        var progressed = false;
        for (specs.specs, 0..) |spec, index| {
            if (removed[index]) continue;
            if (allImportsRemoved(spec, &removed)) {
                removed[index] = true;
                progressed = true;
            }
        }
        if (!progressed) break;
    }
    for (removed) |done| {
        if (!done) return true;
    }
    return false;
}

fn allImportsRemoved(spec: specs.ModuleSpec, removed: []const bool) bool {
    for (spec.imports) |name| {
        for (specs.specs, 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate.name, name) and !removed[index]) return false;
        }
    }
    return true;
}

test "declared graph is acyclic and layered" {
    try std.testing.expect(!hasCycle());
    for (specs.specs) |spec| {
        for (spec.imports) |name| {
            const target = specs.find(name).?;
            try std.testing.expectEqual(@as(?[]const u8, null), edgeViolation(spec, target));
        }
    }
}

test "edge rules reject upward and UI leaks" {
    const engine = specs.find("engine").?;
    const core = specs.find("core").?;
    const ui_core = specs.find("ui_core").?;
    try std.testing.expect(edgeViolation(core, engine) != null);
    try std.testing.expect(edgeViolation(engine, ui_core) != null);
    try std.testing.expect(edgeViolation(ui_core, engine) != null);
}
