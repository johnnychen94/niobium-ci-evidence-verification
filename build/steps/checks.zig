//! `zig build fmt|lint|check|check-docs|check-commits`. All tools are host Zig executables.

const std = @import("std");
const evidence = @import("evidence.zig");

pub const source_roots = [_][]const u8{
    "apps",
    "libs",
    "tools",
    "tests",
    "build",
    "build.zig",
    "examples",
    "third_party/stb_truetype/bindings.zig",
    "third_party/zstd/bindings.zig",
};

pub const Tools = struct {
    evidence: *std.Build.Step.Compile,
    lint: *std.Build.Step.Compile,
    check: *std.Build.Step.Compile,
    check_docs: *std.Build.Step.Compile,
    check_commits: *std.Build.Step.Compile,
    check_binary: *std.Build.Step.Compile,
    gen_tokens: *std.Build.Step.Compile,
    vm_smoke: *std.Build.Step.Compile,
    fetch_deps: *std.Build.Step.Compile,
};

pub fn addTools(b: *std.Build, host: std.Build.ResolvedTarget) Tools {
    const module_specs = b.createModule(.{ .root_source_file = b.path("build/modules.zig") });
    const repo = b.createModule(.{ .root_source_file = b.path("tools/repo/root.zig") });
    const shared: ToolImports = .{ .module_specs = module_specs, .repo = repo };
    const publisher = tool(b, host, "evidence", shared);
    publisher.root_module.addImport("test_catalog", b.createModule(.{
        .root_source_file = b.path("build/test_catalog.zig"),
    }));
    publisher.root_module.addImport("contracts", b.createModule(.{
        .root_source_file = b.path("libs/contracts/root.zig"),
    }));
    return .{
        .evidence = publisher,
        .lint = tool(b, host, "lint", shared),
        .check = tool(b, host, "check", shared),
        .check_docs = tool(b, host, "check-docs", shared),
        .check_commits = tool(b, host, "check-commits", shared),
        .check_binary = tool(b, host, "check-binary", shared),
        .gen_tokens = tool(b, host, "gen-tokens", shared),
        .vm_smoke = tool(b, host, "vm-smoke", shared),
        .fetch_deps = tool(b, host, "fetch-deps", shared),
    };
}

const ToolImports = struct {
    module_specs: *std.Build.Module,
    repo: *std.Build.Module,
};

fn tool(
    b: *std.Build,
    host: std.Build.ResolvedTarget,
    name: []const u8,
    imports: ToolImports,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path(b.fmt("tools/{s}/main.zig", .{name})),
        .target = host,
        .optimize = .debug,
    });
    module.addImport("module_specs", imports.module_specs);
    module.addImport("repo", imports.repo);
    return b.addExecutable(.{ .name = b.fmt("nb-{s}", .{name}), .root_module = module });
}

/// Unit tests of the tools themselves (host).
pub fn addToolTests(
    b: *std.Build,
    tools: Tools,
    step: *std.Build.Step,
    config: evidence.Config,
) void {
    inline for (comptime std.meta.fieldNames(Tools)) |name| {
        const exe = @field(tools, name);
        const unit = b.addTest(
            .{ .name = b.fmt("tool-{s}", .{name}), .root_module = exe.root_module },
        );
        step.dependOn(&evidence.addRun(b, config, .unit, unit, null).step);
    }
}

/// `zig fmt --check --ast-check` over every Zig source root.
pub fn addFmtCheck(b: *std.Build) *std.Build.Step {
    const run = b.addSystemCommand(&.{ b.graph.zig_exe, "fmt", "--check", "--ast-check" });
    run.addArgs(&source_roots);
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    return &run.step;
}

pub fn addFmtFix(b: *std.Build) *std.Build.Step {
    const fmt = b.addFmt(.{ .paths = pathList(b) });
    return &fmt.step;
}

fn pathList(b: *std.Build) []const std.Build.LazyPath {
    const list = b.allocator.alloc(std.Build.LazyPath, source_roots.len) catch @panic("OOM");
    for (source_roots, list) |root, *path| path.* = b.path(root);
    return list;
}

/// Runs a repository tool with the repository root as cwd. Tools must not write to the tree.
pub fn addRepoRun(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    args: []const []const u8,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    run.addArgs(args);
    run.has_side_effects = true;
    return run;
}
