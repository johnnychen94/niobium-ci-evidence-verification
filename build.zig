//! Thin entry. Module graph: build/modules.zig. Steps: build/steps/*.zig. The `pub` functions
//! below are the build API for products that depend on Niobium (docs/development/consuming.md).

const std = @import("std");
const graph_mod = @import("build/graph.zig");
const artifacts = @import("build/steps/artifacts.zig");
const checks = @import("build/steps/checks.zig");
const tests = @import("build/steps/tests.zig");
const cross = @import("build/steps/cross.zig");
const targets = @import("build/targets.zig");
const deps = @import("build/steps/deps.zig");
const e2e = @import("build/steps/e2e.zig");
const ui = @import("build/steps/ui.zig");
const vm = @import("build/steps/vm.zig");
const example = @import("build/steps/example.zig");
const sdk = @import("build/sdk.zig");

pub const version = "0.1.0";

pub const Component = sdk.Component;
pub const BundleOptions = sdk.BundleOptions;
pub const Bundle = sdk.Bundle;

/// `nbpack` for the build host, for publisher steps the helpers below do not cover.
pub fn nbpack(b: *std.Build) *std.Build.Step.Compile {
    return toolchain(b).nbpack;
}

/// `nbpack component build` of `component` for `target`.
pub fn addComponent(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    component: Component,
) std.Build.LazyPath {
    return sdk.addComponent(b, toolchain(b), target.result, component);
}

/// Shipping `setup` for `target` with `product_config` (from `nbpack config`) compiled in.
pub fn addSetup(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    product_config: std.Build.LazyPath,
) *std.Build.Step.Compile {
    return sdk.addSetup(toolchain(b), target, product_config);
}

/// Fresh signed repository, branded setup and offline bundle for one release.
pub fn addBundle(b: *std.Build, options: BundleOptions) Bundle {
    return sdk.addBundle(b, toolchain(b), options);
}

fn toolchain(b: *std.Build) sdk.Toolchain {
    const dep = b.dependencyFromBuildZig(@This(), .{ .optimize = targets.shipping_optimize });
    return sdk.fromDependency(dep, version);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tsan = b.option(bool, "tsan", "ThreadSanitizer lane for test") orelse false;
    const seeds: SimSeeds = .{
        .count = b.option(u32, "seeds", "Seeds for zig build sim") orelse 500,
        .start = b.option(u64, "seed-start", "First sim seed (replay a failure)") orelse 0,
    };
    const update = b.option([]const u8, "update", "Golden scope to rewrite (component name)");
    const product_config = b.option(std.Build.LazyPath, "product-config", "Branded setup config");
    const options: artifacts.Options = .{ .product_config = product_config, .version = version };

    const tools = checks.addTools(b, b.graph.host);
    const inputs: graph_mod.Inputs = .{
        .tokens = ui.addTokens(b, tools.gen_tokens),
        .deps = deps.add(b, tools.fetch_deps),
    };
    sdk.publishInputs(b, inputs);
    const graph = graph_mod.create(
        b,
        .{ .target = target, .optimize = optimize, .inputs = inputs },
    );

    const setup = artifacts.addSetup(b, &graph, options);
    const nbpack_exe = artifacts.addNbpack(b, &graph, options);
    const static_lib = artifacts.addLibdistribution(b, &graph, .static, options);
    const dynamic_lib = artifacts.addLibdistribution(b, &graph, .dynamic, options);
    const workbench = artifacts.addWorkbench(b, &graph);
    const installed = [_]*std.Build.Step.Compile{
        setup, nbpack_exe, static_lib, dynamic_lib, workbench,
    };
    for (installed) |artifact| {
        b.installArtifact(artifact);
    }
    b.installFile("api/c/distribution.h", "include/distribution.h");

    const steps = addQualitySteps(b, &graph, tools, tsan, seeds);
    const cross_steps = cross.add(b, inputs, tools.check_binary, options);
    const cross_tests = b.step("test-cross", "Compile unit + conformance tests for every target");
    tests.addCrossTests(b, inputs, &app_tests, cross_tests);
    const golden_step = b.step("golden", "UI IR / DisplayList / semantic / pixel goldens");
    golden_step.dependOn(ui.addGolden(b, &graph, update));
    b.step(
        "gallery",
        "Render the UI catalog to .evidence/ui-gallery",
    ).dependOn(ui.addGallery(b, workbench));

    const e2e_inputs: e2e.Inputs = .{
        .setup = setup,
        .nbpack = nbpack_exe,
        .hello = e2e.addHello(b, &graph),
        .static_lib = static_lib,
    };
    const e2e_step = b.step("e2e", "install/update/rollback/repair/uninstall, online + offline");
    e2e_step.dependOn(e2e.addE2e(b, &graph, e2e_inputs));
    const c_smoke = b.step("c-smoke", "C program against distribution.h + static library");
    c_smoke.dependOn(e2e.addCSmoke(b, &graph, static_lib));
    const example_step = addExampleSteps(b, target, tools.vm_smoke);

    addRunSteps(b, setup, workbench);

    const verify = b.step("verify", "Definition of Done gate (run with --cache-poison=disallowed)");
    for ([_]*std.Build.Step{
        steps.check,              steps.test_step,       steps.sim,         golden_step,
        e2e_step,                 c_smoke,               cross_steps.cross, cross_tests,
        cross_steps.check_binary, cross_steps.size_gate, example_step,
    }) |step| verify.dependOn(step);
    if (steps.tsan) |tsan_step| verify.dependOn(tsan_step);
}

/// Both build examples/hello as a separate package that depends on this one. Returns `example`.
fn addExampleSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    vm_smoke: *std.Build.Step.Compile,
) *std.Build.Step {
    const example_step = b.step(
        "example",
        "Build examples/hello (a Niobium dependent) into zig-out/example",
    );
    example_step.dependOn(example.add(b, target));
    b.step(
        "vm-smoke",
        "examples/hello bundles in Parallels Windows 11 + Ubuntu ARM64 (-- --start to boot VMs)",
    ).dependOn(vm.add(b, vm_smoke));
    return example_step;
}

const SimSeeds = struct { count: u32, start: u64 };

const QualitySteps = struct {
    check: *std.Build.Step,
    test_step: *std.Build.Step,
    sim: *std.Build.Step,
    tsan: ?*std.Build.Step,
};

fn addQualitySteps(
    b: *std.Build,
    graph: *const graph_mod.Graph,
    tools: checks.Tools,
    tsan: bool,
    seeds: SimSeeds,
) QualitySteps {
    const fmt = b.step("fmt", "zig fmt --check --ast-check");
    fmt.dependOn(checks.addFmtCheck(b));
    b.step("fmt-fix", "Rewrite sources with zig fmt").dependOn(checks.addFmtFix(b));

    const lint = b.step("lint", "tools/lint (TigerStyle + crash-safety + boundary rules)");
    lint.dependOn(&checks.addRepoRun(b, tools.lint, &checks.source_roots).step);
    const baseline = b.step("lint-baseline", "Rewrite tools/lint/complexity-baseline.zon");
    const baseline_run = checks.addRepoRun(b, tools.lint, &.{"--write-baseline"});
    baseline_run.addArgs(&checks.source_roots);
    baseline.dependOn(&baseline_run.step);
    const docs = b.step("check-docs", "Docs links, ADR fields, acceptance IDs, English, URL hosts");
    docs.dependOn(&checks.addRepoRun(b, tools.check_docs, &.{}).step);
    const commits = b.step("check-commits", "Commit message lint on the branch range");
    const commit_run = checks.addRepoRun(b, tools.check_commits, &.{});
    commit_run.addPassthruArgs();
    commits.dependOn(&commit_run.step);

    const check = b.step("check", "fmt + lint + repository checks + docs");
    check.dependOn(fmt);
    check.dependOn(lint);
    check.dependOn(docs);
    check.dependOn(&checks.addRepoRun(b, tools.check, &.{}).step);

    const test_step = b.step("test", "Unit tests per module + conformance (SafeAllocator)");
    addAllTests(b, graph, test_step);
    checks.addToolTests(b, tools, test_step);
    const tsan_step: ?*std.Build.Step = if (tsan or hostSupportsTsan(b)) addTsan(
        b,
        graph,
    ) else null;
    if (tsan) test_step.dependOn(tsan_step.?);

    const sim = b.step("sim", "Seeded VirtualPlatform fault simulation (-Dseeds=N)");
    const sim_opts = b.addOptions();
    sim_opts.addOption(u32, "seeds", seeds.count);
    sim_opts.addOption(u64, "seed_start", seeds.start);
    sim.dependOn(&tests.addSuite(b, graph, "sim", sim_opts).step);

    const fuzz = b.step("fuzz", "Fuzz targets (corpus replay; add --fuzz for continuous)");
    fuzz.dependOn(&tests.addSuite(b, graph, "fuzz", b.addOptions()).step);
    return .{ .check = check, .test_step = test_step, .sim = sim, .tsan = tsan_step };
}

fn addAllTests(b: *std.Build, graph: *const graph_mod.Graph, test_step: *std.Build.Step) void {
    tests.addUnitTests(b, graph, test_step);
    test_step.dependOn(&tests.addSuite(b, graph, "conformance", b.addOptions()).step);
    tests.addAppTests(b, graph, test_step, &app_tests);
}

const app_tests = [_]tests.AppTest{
    .{
        .source = "apps/setup/main.zig",
        .imports = &artifacts.setup_imports,
        .configure = configureSetupTest,
    },
    .{
        .source = "apps/nbpack/main.zig",
        .imports = &artifacts.nbpack_imports,
        .configure = configureNbpackTest,
    },
    .{
        .source = "apps/libdistribution/root.zig",
        .imports = &artifacts.libdistribution_imports,
        .configure = configureLibdistributionTest,
    },
};

fn configureLibdistributionTest(b: *std.Build, module: *std.Build.Module) void {
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", version);
    opts.addOption(bool, "branded", false);
    module.addOptions("build_options", opts);
    artifacts.configureLibdistribution(module);
}

fn configureNbpackTest(b: *std.Build, module: *std.Build.Module) void {
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", version);
    opts.addOption(bool, "branded", false);
    module.addOptions("build_options", opts);
}

fn configureSetupTest(b: *std.Build, module: *std.Build.Module) void {
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", version);
    opts.addOption(bool, "branded", false);
    module.addOptions("build_options", opts);
    artifacts.addProductConfig(b, module, null);
}

fn hostSupportsTsan(b: *std.Build) bool {
    return switch (b.graph.host.result.os.tag) {
        .macos, .linux => true,
        else => false,
    };
}

fn addTsan(b: *std.Build, graph: *const graph_mod.Graph) *std.Build.Step {
    const tsan_graph = graph_mod.create(b, .{
        .target = graph.config.target,
        .optimize = .debug,
        .sanitize_thread = true,
        .inputs = graph.config.inputs,
    });
    const step = b.step("tsan", "ThreadSanitizer over engine, broker and UI-thread tests");
    const opts = b.addOptions();
    opts.addOption(u32, "seeds", 16);
    step.dependOn(&tests.addSuite(b, &tsan_graph, "concurrency", opts).step);
    return step;
}

fn addRunSteps(
    b: *std.Build,
    setup: *std.Build.Step.Compile,
    workbench: *std.Build.Step.Compile,
) void {
    const run_setup = b.addRunArtifact(setup);
    run_setup.addPassthruArgs();
    b.step("run", "Run setup with passthrough args").dependOn(&run_setup.step);
    const run_bench = b.addRunArtifact(workbench);
    run_bench.addPassthruArgs();
    b.step("workbench", "Run ui-workbench").dependOn(&run_bench.step);
}
