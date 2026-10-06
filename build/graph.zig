//! Instantiates build/modules.zig for one (target, optimize) pair.

const std = @import("std");
const specs = @import("modules.zig");

pub const Config = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    sanitize_thread: bool = false,
    /// null keeps the optimize mode's default (debug info kept).
    strip: ?bool = null,
    inputs: Inputs,
};

/// Generated or fetched sources shared by every graph.
pub const Inputs = struct {
    /// Output of tools/gen-tokens (generated `ui_tokens` module root).
    tokens: std.Build.LazyPath,
    deps: Deps,
};

/// Package roots fetched by build/steps/deps.zig, one field per third_party/deps.zon package.
pub const Deps = struct {
    zstd: std.Build.LazyPath,
    stb_truetype: std.Build.LazyPath,
    inter: std.Build.LazyPath,
};

pub const Graph = struct {
    b: *std.Build,
    config: Config,
    modules: [specs.specs.len]*std.Build.Module,

    pub fn get(graph: *const Graph, name: []const u8) *std.Build.Module {
        for (specs.specs, 0..) |spec, index| {
            if (std.mem.eql(u8, spec.name, name)) return graph.modules[index];
        }
        std.debug.panic("unknown module '{s}'", .{name});
    }

    /// Creates a root module (app, tool, test) importing the named library modules.
    pub fn root(
        graph: *const Graph,
        source: []const u8,
        imports: []const []const u8,
    ) *std.Build.Module {
        const b = graph.b;
        const module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = graph.config.target,
            .optimize = graph.config.optimize,
            .sanitize_thread = graph.config.sanitize_thread,
            .strip = graph.config.strip,
        });
        for (imports) |name| module.addImport(name, graph.get(name));
        return module;
    }
};

pub fn create(b: *std.Build, config: Config) Graph {
    // SAFETY: every module slot is assigned in the loop below before use.
    var graph: Graph = .{ .b = b, .config = config, .modules = undefined };
    for (specs.specs, 0..) |spec, index| {
        graph.modules[index] = createModule(b, config, spec);
    }
    for (specs.specs, 0..) |spec, index| {
        for (spec.imports) |name| graph.modules[index].addImport(name, graph.get(name));
    }
    addEmbeds(b, &graph);
    return graph;
}

fn createModule(b: *std.Build, config: Config, spec: specs.ModuleSpec) *std.Build.Module {
    const source = if (spec.generated) config.inputs.tokens else b.path(spec.root);
    const module = b.createModule(.{
        .root_source_file = source,
        .target = config.target,
        .optimize = config.optimize,
        .sanitize_thread = config.sanitize_thread,
        .strip = config.strip,
    });
    switch (spec.c_library) {
        .none => {},
        .stb_truetype => addStbTruetype(b, module, config.inputs.deps.stb_truetype),
        .zstd_compress => addZstdCompress(module, config.inputs.deps.zstd),
    }
    if (config.target.result.os.tag == .macos and spec.macos_frameworks.len > 0) {
        addMacosSdk(b, config, module);
        for (spec.macos_frameworks) |name| module.linkFramework(name, .{});
    }
    const libraries = switch (config.target.result.os.tag) {
        .macos => spec.macos_libraries,
        .windows => spec.windows_libraries,
        else => &.{},
    };
    for (libraries) |name| module.linkSystemLibrary(name, .{ .use_pkg_config = .no });
    return module;
}

/// Native targets find the SDK on their own; explicit `-Dtarget=*-macos` queries search nothing,
/// so point them at the host SDK when there is one.
fn addMacosSdk(b: *std.Build, config: Config, module: *std.Build.Module) void {
    if (b.graph.host.result.os.tag != .macos) return;
    const sdk = std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &config.target.result) orelse
        return;
    module.addSystemFrameworkPath(
        .{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) },
    );
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
}

fn addEmbeds(b: *std.Build, graph: *Graph) void {
    const render = graph.get("ui_render");
    const inter = graph.config.inputs.deps.inter;
    render.addAnonymousImport("font_regular", .{
        .root_source_file = inter.path(b, "Inter-Regular.ttf"),
    });
    render.addAnonymousImport("font_semibold", .{
        .root_source_file = inter.path(b, "Inter-SemiBold.ttf"),
    });
}

fn addStbTruetype(b: *std.Build, module: *std.Build.Module, upstream: std.Build.LazyPath) void {
    module.addIncludePath(upstream);
    module.addCSourceFile(.{
        .file = b.path("third_party/stb_truetype/stb_truetype_impl.c"),
        // No FMA contraction: glyph coverage must be bit-identical on every target (goldens).
        .flags = &.{
            "-std=c99",
            "-fno-sanitize=undefined",
            "-ffreestanding",
            "-ffp-contract=off",
        },
    });
}

const zstd_sources = [_][]const u8{
    "common/debug.c",
    "common/entropy_common.c",
    "common/error_private.c",
    "common/fse_decompress.c",
    "common/pool.c",
    "common/threading.c",
    "common/xxhash.c",
    "common/zstd_common.c",
    "compress/fse_compress.c",
    "compress/hist.c",
    "compress/huf_compress.c",
    "compress/zstd_compress.c",
    "compress/zstd_compress_literals.c",
    "compress/zstd_compress_sequences.c",
    "compress/zstd_compress_superblock.c",
    "compress/zstd_double_fast.c",
    "compress/zstd_fast.c",
    "compress/zstd_lazy.c",
    "compress/zstd_ldm.c",
    "compress/zstd_opt.c",
    "compress/zstd_preSplit.c",
    "compress/zstdmt_compress.c",
};

fn addZstdCompress(module: *std.Build.Module, upstream: std.Build.LazyPath) void {
    const b = module.owner;
    const lib = upstream.path(b, "lib");
    module.link_libc = true;
    module.addIncludePath(lib);
    module.addCSourceFiles(.{
        .root = lib,
        .files = &zstd_sources,
        .flags = &.{
            "-std=c99",
            "-DZSTD_TRACE=0",
            "-DZSTD_LEGACY_SUPPORT=0",
            "-DZSTD_DISABLE_ASM",
            "-DXXH_NAMESPACE=ZSTD_",
            "-fno-sanitize=undefined",
        },
    });
}
