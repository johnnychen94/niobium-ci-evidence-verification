//! Shipping and developer executables for one module graph.

const std = @import("std");
const graph_mod = @import("../graph.zig");

pub const Options = struct {
    /// Optional branded product config embedded into setup (`-Dproduct-config`).
    product_config: ?std.Build.LazyPath = null,
    version: []const u8,
};

pub const setup_imports = [_][]const u8{
    "core",       "contracts", "platform",   "engine",     "privilege",
    "bootstrap",  "portable",  "ui_core",    "ui_screens", "ui_render",
    "ui_backend", "trust",     "repository", "manifest",   "planner",
    "ui_tokens",
};

pub fn addSetup(
    b: *std.Build,
    graph: *const graph_mod.Graph,
    options: Options,
) *std.Build.Step.Compile {
    const module = graph.root("apps/setup/main.zig", &setup_imports);
    module.addOptions("build_options", buildOptions(b, options));
    addProductConfig(b, module, options.product_config);
    const exe = b.addExecutable(.{ .name = "setup", .root_module = module });
    addWindowsResources(b, exe, graph.config.target, "apps/setup/setup.rc");
    return exe;
}

pub const nbpack_imports = [_][]const u8{ "core", "contracts", "packager" };

pub fn addNbpack(
    b: *std.Build,
    graph: *const graph_mod.Graph,
    options: Options,
) *std.Build.Step.Compile {
    const module = graph.root("apps/nbpack/main.zig", &nbpack_imports);
    module.addOptions("build_options", buildOptions(b, options));
    return b.addExecutable(.{ .name = "nbpack", .root_module = module });
}

pub const LibKind = enum { static, dynamic };

pub const libdistribution_imports = [_][]const u8{
    "core",  "contracts", "platform", "engine", "repository",
    "trust", "planner",   "portable",
};

/// No libc of its own on Linux: the environment comes from /proc (apps/libdistribution/root.zig).
pub fn configureLibdistribution(module: *std.Build.Module) void {
    module.pic = true;
}

pub fn addLibdistribution(
    b: *std.Build,
    graph: *const graph_mod.Graph,
    kind: LibKind,
    options: Options,
) *std.Build.Step.Compile {
    const module = graph.root("apps/libdistribution/root.zig", &libdistribution_imports);
    module.addOptions("build_options", buildOptions(b, options));
    configureLibdistribution(module);
    return b.addLibrary(.{
        .name = "distribution",
        .linkage = if (kind == .static) .static else .dynamic,
        .root_module = module,
    });
}

pub fn addWorkbench(b: *std.Build, graph: *const graph_mod.Graph) *std.Build.Step.Compile {
    const module = graph.root("apps/ui-workbench/main.zig", &.{
        "ui_core",   "ui_kit",     "ui_screens", "ui_render",
        "ui_tokens", "ui_backend", "contracts",  "core",
    });
    return b.addExecutable(.{ .name = "ui-workbench", .root_module = module });
}

/// `@import("product_config").bytes`: the product config JSON compiled into setup.
pub fn addProductConfig(
    b: *std.Build,
    module: *std.Build.Module,
    config: ?std.Build.LazyPath,
) void {
    const files = b.addWriteFiles();
    // lint-allow(no-discard-call): the copy is reached through the generated source's @embedFile.
    _ = files.addCopyFile(
        config orelse b.path("apps/setup/generic-config.json"),
        "product-config.json",
    );
    const source = files.add(
        "product_config.zig",
        "pub const bytes = @embedFile(\"product-config.json\");\n",
    );
    module.addAnonymousImport("product_config", .{ .root_source_file = source });
}

fn buildOptions(b: *std.Build, options: Options) *std.Build.Step.Options {
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", options.version);
    opts.addOption(bool, "branded", options.product_config != null);
    return opts;
}

/// Windows application manifest (DPI awareness, UAC level) and icon via `zig rc`.
fn addWindowsResources(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    rc_path: []const u8,
) void {
    if (target.result.os.tag != .windows) return;
    const rc = b.addSystemCommand(&.{
        b.graph.zig_exe, "rc", "/:no-preprocess", "/:auto-includes", "none", "/i",
    });
    rc.addDirectoryArg(b.path(std.fs.path.dirname(rc_path) orelse "."));
    rc.addArg("/fo");
    const res = rc.addOutputFileArg("setup.res");
    rc.addArg("--");
    rc.addFileArg(b.path(rc_path));
    rc.addFileInput(b.path("apps/setup/setup.manifest"));
    exe.root_module.addObjectFile(res);
}
