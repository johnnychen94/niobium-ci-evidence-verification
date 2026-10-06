//! `zig build test`, `sim`, `fuzz`: unit tests per module plus cross-module suites.

const std = @import("std");
const specs = @import("../modules.zig");
const graph_mod = @import("../graph.zig");
const targets = @import("../targets.zig");
const ui = @import("ui.zig");

pub const suite_imports = [_][]const u8{
    "core",       "contracts",   "platform",    "manifest", "trust",
    "repository", "package",     "executor",    "resolver", "planner",
    "privilege",  "bootstrap",   "transaction", "portable", "engine",
    "packager",   "conformance", "zstd",
};

/// One test binary per library module; each runs under std.testing.allocator (SafeAllocator).
pub fn addUnitTests(b: *std.Build, graph: *const graph_mod.Graph, step: *std.Build.Step) void {
    for (specs.specs, 0..) |spec, index| {
        const unit = b.addTest(.{
            .name = b.fmt("unit-{s}", .{spec.name}),
            .root_module = graph.modules[index],
        });
        const run = b.addRunArtifact(unit);
        step.dependOn(&run.step);
    }
}

/// tests/<suite>/root.zig with access to every service module.
pub fn addSuite(
    b: *std.Build,
    graph: *const graph_mod.Graph,
    suite: []const u8,
    extra: *std.Build.Step.Options,
) *std.Build.Step.Run {
    const module = graph.root(b.fmt("tests/{s}/root.zig", .{suite}), &suite_imports);
    module.addOptions("suite_options", extra);
    const exe = b.addTest(.{ .name = b.fmt("suite-{s}", .{suite}), .root_module = module });
    return b.addRunArtifact(exe);
}

/// Tests that live next to an app (CLI frontend, C ABI).
pub const AppTest = struct {
    source: []const u8,
    imports: []const []const u8,
    configure: *const fn (*std.Build, *std.Build.Module) void,

    fn compile(t: AppTest, b: *std.Build, graph: *const graph_mod.Graph) *std.Build.Step.Compile {
        const module = graph.root(t.source, t.imports);
        t.configure(b, module);
        const name = std.fs.path.basename(std.fs.path.dirname(t.source).?);
        return b.addTest(.{ .name = b.fmt("app-{s}", .{name}), .root_module = module });
    }
};

pub fn addAppTests(
    b: *std.Build,
    graph: *const graph_mod.Graph,
    step: *std.Build.Step,
    apps: []const AppTest,
) void {
    for (apps) |app| step.dependOn(&b.addRunArtifact(app.compile(b, graph)).step);
}

/// `zig build test-cross`: every unit test binary and the conformance suite compiled for each
/// cross target and installed under `zig-out/cross-tests/<target>/`, where vm-smoke runs them
/// (host PlatformContract on real Windows and Linux). Compiling alone proves the per-OS backends
/// type-check on every target.
pub fn addCrossTests(
    b: *std.Build,
    inputs: graph_mod.Inputs,
    apps: []const AppTest,
    step: *std.Build.Step,
) void {
    for (targets.cross_targets) |cross_target| {
        const graph = graph_mod.create(b, .{
            .target = b.resolveTargetQuery(cross_target.query),
            .optimize = .debug,
            .inputs = inputs,
        });
        const dir: std.Build.InstallDir = .{
            .custom = b.fmt("cross-tests/{s}", .{cross_target.name}),
        };
        for (specs.specs, 0..) |spec, index| {
            const unit = b.addTest(.{
                .name = b.fmt("unit-{s}", .{spec.name}),
                .root_module = graph.modules[index],
            });
            const install = b.addInstallArtifact(unit, .{ .dest_dir = .{ .override = dir } });
            step.dependOn(&install.step);
        }
        const module = graph.root("tests/conformance/root.zig", &suite_imports);
        module.addOptions("suite_options", b.addOptions());
        const suite = b.addTest(.{ .name = "suite-conformance", .root_module = module });
        const install = b.addInstallArtifact(suite, .{ .dest_dir = .{ .override = dir } });
        step.dependOn(&install.step);
        const golden = ui.addGoldenSuite(b, &graph, null);
        step.dependOn(&b.addInstallArtifact(golden, .{ .dest_dir = .{ .override = dir } }).step);
        for (apps) |app| {
            const exe = app.compile(b, &graph);
            step.dependOn(&b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = dir } }).step);
        }
    }
}
