//! `zig build test`, `sim`, `fuzz`: unit tests per module plus cross-module suites.

const std = @import("std");
const specs = @import("../modules.zig");
const graph_mod = @import("../graph.zig");
const targets = @import("../targets.zig");
const ui = @import("ui.zig");
const evidence = @import("evidence.zig");

pub const suite_imports = [_][]const u8{
    "core",       "contracts",   "platform",    "manifest", "trust",
    "repository", "package",     "executor",    "resolver", "planner",
    "privilege",  "bootstrap",   "transaction", "portable", "engine",
    "packager",   "conformance", "zstd",
};

/// One test binary per library module; each runs under std.testing.allocator (SafeAllocator).
/// `coverage_root` runs each binary under kcov and writes `coverage_root/unit-<module>`.
pub fn addUnitTests(
    b: *std.Build,
    graph: *const graph_mod.Graph,
    step: *std.Build.Step,
    coverage_root: ?[]const u8,
    config: evidence.Config,
) void {
    for (specs.specs, 0..) |spec, index| {
        const unit = b.addTest(.{
            .name = b.fmt("unit-{s}", .{spec.name}),
            .root_module = graph.modules[index],
        });
        const dir = coverageDir(b, coverage_root, b.fmt("unit-{s}", .{spec.name}));
        dependOnTest(b, step, unit, dir, config, .unit);
    }
}

/// tests/<suite>/root.zig with access to every service module.
pub fn compileSuite(
    b: *std.Build,
    graph: *const graph_mod.Graph,
    suite: []const u8,
    extra: *std.Build.Step.Options,
) *std.Build.Step.Compile {
    const module = graph.root(b.fmt("tests/{s}/root.zig", .{suite}), &suite_imports);
    module.addOptions("suite_options", extra);
    evidence.addModule(b, module);
    return b.addTest(.{ .name = b.fmt("suite-{s}", .{suite}), .root_module = module });
}

/// tests/<suite>/root.zig, executed directly. sim, e2e and fuzz use this path.
pub fn addSuite(
    b: *std.Build,
    graph: *const graph_mod.Graph,
    suite: []const u8,
    extra: *std.Build.Step.Options,
    config: evidence.Config,
) *std.Build.Step.Run {
    const identity = if (std.mem.eql(
        u8,
        suite,
        "concurrency",
    )) evidence.catalog.Suite.unit else std.meta.stringToEnum(evidence.catalog.Suite, suite).?;
    return evidence.addRun(b, config, identity, compileSuite(b, graph, suite, extra), null);
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
    coverage_root: ?[]const u8,
    config: evidence.Config,
) void {
    for (apps) |app| {
        const exe = app.compile(b, graph);
        const dir = coverageDir(b, coverage_root, exe.name);
        dependOnTest(b, step, exe, dir, config, .unit);
    }
}

/// `dir` null runs the test directly. A path runs it under kcov into that directory.
pub fn dependOnTest(
    b: *std.Build,
    step: *std.Build.Step,
    exe: *std.Build.Step.Compile,
    dir: ?[]const u8,
    config: evidence.Config,
    suite: evidence.catalog.Suite,
) void {
    step.dependOn(&evidence.addRun(b, config, suite, exe, dir).step);
}

fn coverageDir(b: *std.Build, root: ?[]const u8, name: []const u8) ?[]const u8 {
    const base = root orelse return null;
    return b.fmt("{s}/{s}", .{ base, name });
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
        evidence.addModule(b, module);
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
