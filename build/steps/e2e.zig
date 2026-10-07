//! `zig build e2e|c-smoke`: real binaries against a local HTTP / directory repository.

const std = @import("std");
const graph_mod = @import("../graph.zig");
const tests = @import("tests.zig");
const evidence = @import("evidence.zig");

pub const Inputs = struct {
    setup: *std.Build.Step.Compile,
    nbpack: *std.Build.Step.Compile,
    hello: *std.Build.Step.Compile,
    static_lib: *std.Build.Step.Compile,
};

pub fn addE2e(
    b: *std.Build,
    graph: *const graph_mod.Graph,
    inputs: Inputs,
    config: evidence.Config,
) *std.Build.Step {
    const opts = b.addOptions();
    opts.addOptionPath("setup_exe", inputs.setup.getEmittedBin());
    opts.addOptionPath("nbpack_exe", inputs.nbpack.getEmittedBin());
    opts.addOptionPath("hello_exe", inputs.hello.getEmittedBin());
    opts.addOption([]const u8, "example_dir", "examples/hello");
    opts.addOption([]const u8, "evidence_dir", ".evidence/e2e");
    const run = tests.addSuite(b, graph, "e2e", opts, config);
    run.has_side_effects = true;
    run.setCwd(b.path("."));
    return &run.step;
}

/// The sample product's own binary (examples/hello/app); built like any third-party app.
pub fn addHello(b: *std.Build, graph: *const graph_mod.Graph) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path("examples/hello/app/main.zig"),
        .target = graph.config.target,
        .optimize = graph.config.optimize,
    });
    return b.addExecutable(.{ .name = "hello", .root_module = module });
}

/// C program compiled against api/c/distribution.h and the static library.
pub fn addCSmoke(
    b: *std.Build,
    graph: *const graph_mod.Graph,
    static_lib: *std.Build.Step.Compile,
    config: evidence.Config,
) *std.Build.Step {
    const module = b.createModule(.{
        .target = graph.config.target,
        .optimize = graph.config.optimize,
        .link_libc = true,
    });
    module.addCSourceFile(
        .{ .file = b.path("tests/c-smoke/main.c"), .flags = &.{ "-std=c11", "-Wall", "-Werror" } },
    );
    module.addIncludePath(b.path("api/c"));
    module.linkLibrary(static_lib);
    const exe = b.addExecutable(.{ .name = "c-smoke", .root_module = module });
    const run = evidence.addRun(b, config, .@"c-smoke", exe, null);
    return &run.step;
}
