//! Build API for products that depend on Niobium (docs/development/consuming.md). A dependent's
//! build.zig reaches it as `@import("niobium")`; the wrappers in build.zig resolve the Niobium
//! dependency into a `Toolchain` and call into this file.

const std = @import("std");
const graph_mod = @import("graph.zig");
const targets = @import("targets.zig");
const artifacts = @import("steps/artifacts.zig");

const LazyPath = std.Build.LazyPath;
const Compile = std.Build.Step.Compile;

/// Niobium's build as seen from the package adding steps.
pub const Toolchain = struct {
    /// Niobium's builder: owns the module graph, so its `b.path` calls resolve inside Niobium.
    owner: *std.Build,
    inputs: graph_mod.Inputs,
    /// Runs on the build host.
    nbpack: *Compile,
    version: []const u8,
};

const tokens_name = "ui_tokens";
const deps_prefix = "third_party/";

/// Lets `fromDependency` rebuild `inputs` in a dependent (`Dependency.namedLazyPath`).
pub fn publishInputs(b: *std.Build, inputs: graph_mod.Inputs) void {
    b.addNamedLazyPath(tokens_name, inputs.tokens);
    inline for (comptime std.meta.fieldNames(graph_mod.Deps)) |name| {
        b.addNamedLazyPath(deps_prefix ++ name, @field(inputs.deps, name));
    }
}

pub fn fromDependency(dep: *std.Build.Dependency, version: []const u8) Toolchain {
    // SAFETY: every field is assigned in the loop below.
    var deps: graph_mod.Deps = undefined;
    inline for (comptime std.meta.fieldNames(graph_mod.Deps)) |name| {
        @field(deps, name) = dep.namedLazyPath(deps_prefix ++ name);
    }
    return .{
        .owner = dep.builder,
        .inputs = .{ .tokens = dep.namedLazyPath(tokens_name), .deps = deps },
        .nbpack = dep.artifact("nbpack"),
        .version = version,
    };
}

pub const Component = struct {
    /// Must equal the `id` inside `metadata`; names the artifact file.
    id: []const u8,
    /// `component.json` (docs/spec/component-v1.md).
    metadata: LazyPath,
    /// Tree installed under the component root.
    files: LazyPath,
    version: []const u8,
};

/// `<os>-<arch>` as in manifest `artifacts` keys.
pub fn platformName(b: *std.Build, target: std.Target) []const u8 {
    return b.fmt("{t}-{t}", .{ target.os.tag, target.cpu.arch });
}

/// `nbpack component build`: `<id>.tar.zst` for `target`, an input of `addBundle`.
pub fn addComponent(
    b: *std.Build,
    tc: Toolchain,
    target: std.Target,
    component: Component,
) LazyPath {
    const run = b.addRunArtifact(tc.nbpack);
    run.setName(b.fmt("nbpack component {s}", .{component.id}));
    run.addArgs(&.{ "component", "build", "--version", component.version, "--platform" });
    run.addArg(platformName(b, target));
    run.addArg("--source");
    run.addFileArg(component.metadata);
    run.addArg("--files");
    run.addDirectoryArg(component.files);
    run.addArg("--out");
    return run.addOutputFileArg(b.fmt("{s}.tar.zst", .{component.id}));
}

/// Shipping `setup` with `product_config` (from `nbpack config`) compiled in: ReleaseSafe and
/// stripped ELF, the same settings `zig build cross` gates.
pub fn addSetup(
    tc: Toolchain,
    target: std.Build.ResolvedTarget,
    product_config: LazyPath,
) *Compile {
    const graph = graph_mod.create(tc.owner, .{
        .target = target,
        .optimize = targets.shipping_optimize,
        .strip = targets.shippingStrip(target.result),
        .inputs = tc.inputs,
    });
    return artifacts.addSetup(tc.owner, &graph, .{
        .product_config = product_config,
        .version = tc.version,
    });
}

pub const BundleOptions = struct {
    target: std.Build.ResolvedTarget,
    /// Product template (docs/spec/manifest-v1.md) with empty `artifacts`.
    product: LazyPath,
    /// docs/spec/cli-v1.md `branding`.
    branding: ?LazyPath = null,
    /// From `addComponent`, all for `target`.
    artifacts: []const LazyPath,
    /// `nbpack keygen` output. null generates throwaway keys per clean build: a later bundle
    /// cannot update an install made from an earlier one. Tests and demos only.
    keys: ?LazyPath = null,
    /// Online repository the setup also uses (`nbpack config --repository`).
    repository_url: ?[]const u8 = null,
    /// Metadata expiry of the fresh repository.
    days: u32 = 365,
};

pub const Bundle = struct {
    keys: LazyPath,
    /// Signed TUF repository; upload as is to serve `repository_url`.
    repository: LazyPath,
    product_config: LazyPath,
    setup: *Compile,
    /// `setup`, `repository/` and `licenses/` (docs/runbooks/offline-bundle.md).
    dir: LazyPath,
};

/// A fresh repository for one release, a branded setup trusting it, and the offline bundle.
/// Later releases go through `nbpack publish` on the kept repository
/// (docs/runbooks/release-signing.md), not through this function.
pub fn addBundle(b: *std.Build, tc: Toolchain, options: BundleOptions) Bundle {
    const keys = options.keys orelse keygen(b, tc);
    const publish = b.addRunArtifact(tc.nbpack);
    publish.setName("nbpack publish");
    publish.addArgs(&.{ "publish", "--init", "--days" });
    publish.addArg(b.fmt("{d}", .{options.days}));
    publish.addArgs(&.{ "--timestamp-days", b.fmt("{d}", .{options.days}), "--keys" });
    publish.addDirectoryArg(keys);
    publish.addArg("--product");
    publish.addFileArg(options.product);
    for (options.artifacts) |artifact| {
        publish.addArg("--artifact");
        publish.addFileArg(artifact);
    }
    publish.addArg("--repo");
    const repo = publish.addOutputDirectoryArg("repository");

    const config = b.addRunArtifact(tc.nbpack);
    config.setName("nbpack config");
    config.addArg("config");
    config.addArg("--repo");
    config.addDirectoryArg(repo);
    config.addArg("--product");
    config.addFileArg(options.product);
    if (options.branding) |branding| {
        config.addArg("--branding");
        config.addFileArg(branding);
    }
    if (options.repository_url) |url| config.addArgs(&.{ "--repository", url });
    config.addArg("--out");
    const product_config = config.addOutputFileArg("product-config.json");
    const setup = addSetup(tc, options.target, product_config);
    return .{
        .keys = keys,
        .repository = repo,
        .product_config = product_config,
        .setup = setup,
        .dir = bundleDir(b, tc, repo, setup),
    };
}

fn keygen(b: *std.Build, tc: Toolchain) LazyPath {
    const run = b.addRunArtifact(tc.nbpack);
    run.setName("nbpack keygen (throwaway)");
    run.addArgs(&.{ "keygen", "--out" });
    return run.addOutputDirectoryArg("keys");
}

fn bundleDir(b: *std.Build, tc: Toolchain, repo: LazyPath, setup: *Compile) LazyPath {
    const bundle = b.addRunArtifact(tc.nbpack);
    bundle.setName("nbpack bundle");
    bundle.addArg("bundle");
    bundle.addArg("--repo");
    bundle.addDirectoryArg(repo);
    bundle.addArg("--setup");
    bundle.addFileArg(setup.getEmittedBin());
    bundle.addArg("--out");
    const out = bundle.addOutputDirectoryArg("bundle");
    // OFL-1.1 travels with the embedded Inter font.
    const files = b.addWriteFiles();
    // lint-allow(no-discard-call): both copies are reached through the directory below.
    _ = files.addCopyDirectory(out, "", .{});
    // lint-allow(no-discard-call): see above.
    _ = files.addCopyFile(tc.inputs.deps.inter.path(b, "LICENSE.txt"), "licenses/Inter-OFL.txt");
    return files.getDirectory();
}
