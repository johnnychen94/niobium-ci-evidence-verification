//! `zig build golden|gallery` and the tokens.json -> Zig codegen step.

const std = @import("std");
const evidence = @import("evidence.zig");
const graph_mod = @import("../graph.zig");

/// tokens.json -> tokens.zig (contrast gate runs inside gen-tokens).
pub fn addTokens(b: *std.Build, gen_tokens: *std.Build.Step.Compile) std.Build.LazyPath {
    const run = b.addRunArtifact(gen_tokens);
    run.addFileArg(b.path("libs/ui/tokens/tokens.json"));
    return run.addOutputFileArg("tokens.zig");
}

pub const golden_imports = [_][]const u8{
    "ui_core",   "ui_kit",     "ui_screens", "ui_render",
    "ui_tokens", "ui_backend", "contracts",  "core",
};

/// Pixel + IR goldens. `-Dupdate=<component>` rewrites one scope; there is no bulk update.
pub fn addGolden(
    b: *std.Build,
    graph: *const graph_mod.Graph,
    update: ?[]const u8,
    config: evidence.Config,
) *std.Build.Step {
    const run = evidence.addRun(b, config, .golden, addGoldenSuite(b, graph, update), null);
    run.setCwd(b.path("."));
    // The golden files are read at run time, not tracked as build inputs.
    run.has_side_effects = true;
    return &run.step;
}

/// The golden test binary; it reads `tests/golden` relative to its working directory, so
/// cross builds run it from the repo root (`zig-out/cross-tests/<target>/suite-golden`).
pub fn addGoldenSuite(
    b: *std.Build,
    graph: *const graph_mod.Graph,
    update: ?[]const u8,
) *std.Build.Step.Compile {
    const opts = b.addOptions();
    opts.addOption([]const u8, "golden_dir", "tests/golden");
    opts.addOption(?[]const u8, "update_scope", update);
    const module = graph.root("tests/golden/root.zig", &golden_imports);
    module.addOptions("suite_options", opts);
    return b.addTest(.{ .name = "suite-golden", .root_module = module });
}

/// Writes every catalog state x theme x scale to .evidence/ui-gallery/<UTC>/ (advisory).
pub fn addGallery(b: *std.Build, workbench: *std.Build.Step.Compile) *std.Build.Step {
    const run = b.addRunArtifact(workbench);
    run.addArgs(&.{ "gallery", "--out", ".evidence/ui-gallery" });
    run.has_side_effects = true;
    run.setCwd(b.path("."));
    return &run.step;
}
