//! `zig build cross|check-binary|size-gate`: ReleaseSafe shipping artifacts for every target.

const std = @import("std");
const targets = @import("../targets.zig");
const graph_mod = @import("../graph.zig");
const artifacts = @import("artifacts.zig");

pub const Output = struct {
    target: targets.CrossTarget,
    setup: *std.Build.Step.Compile,
    lib: *std.Build.Step.Compile,
};

pub const Steps = struct {
    cross: *std.Build.Step,
    check_binary: *std.Build.Step,
    size_gate: *std.Build.Step,
    outputs: []Output,
};

pub fn add(
    b: *std.Build,
    inputs: graph_mod.Inputs,
    check_binary: *std.Build.Step.Compile,
    options: artifacts.Options,
) Steps {
    const cross_step = b.step(
        "cross",
        "Build ReleaseSafe setup + libdistribution for every target",
    );
    const binary_step = b.step("check-binary", "Lint dynamic deps, PE flags and RWX sections");
    const size_step = b.step("size-gate", "setup <= 30 MiB and <= 5% growth vs baseline");
    const outputs = b.allocator.alloc(Output, targets.cross_targets.len) catch @panic("OOM");
    const size_run = b.addRunArtifact(check_binary);
    size_run.setCwd(b.path("."));
    size_run.addArgs(&.{ "size", "--baseline", "tools/size-gate/baseline.zon", "--limit" });
    size_run.addArg(b.fmt("{d}", .{targets.setup_size_limit_bytes}));
    for (targets.cross_targets, outputs) |cross_target, *output| {
        output.* = addTarget(b, inputs, cross_target, options);
        const dir: std.Build.InstallDir = .{ .custom = b.fmt("cross/{s}", .{cross_target.name}) };
        const install_setup = b.addInstallArtifact(
            output.setup,
            .{ .dest_dir = .{ .override = dir } },
        );
        const install_lib = b.addInstallArtifact(output.lib, .{ .dest_dir = .{ .override = dir } });
        cross_step.dependOn(&install_setup.step);
        cross_step.dependOn(&install_lib.step);
        binary_step.dependOn(&lintRun(b, check_binary, cross_target, output.setup, "exe").step);
        binary_step.dependOn(&lintRun(b, check_binary, cross_target, output.lib, "dylib").step);
        if (!cross_target.smoke_only) {
            size_run.addArg(cross_target.name);
            size_run.addFileArg(output.setup.getEmittedBin());
        }
    }
    size_run.addPassthruArgs();
    size_run.has_side_effects = true;
    size_step.dependOn(&size_run.step);
    return .{
        .cross = cross_step,
        .check_binary = binary_step,
        .size_gate = size_step,
        .outputs = outputs,
    };
}

fn addTarget(
    b: *std.Build,
    inputs: graph_mod.Inputs,
    cross_target: targets.CrossTarget,
    options: artifacts.Options,
) Output {
    const target = resolve(b, cross_target.query);
    const graph = graph_mod.create(b, .{
        .target = target,
        .optimize = targets.shipping_optimize,
        .strip = targets.shippingStrip(target.result),
        .inputs = inputs,
    });
    return .{
        .target = cross_target,
        .setup = artifacts.addSetup(b, &graph, options),
        .lib = artifacts.addLibdistribution(b, &graph, .dynamic, options),
    };
}

/// Native-OS queries keep SDK detection (macOS frameworks); the CPU stays baseline.
fn resolve(b: *std.Build, query: std.Target.Query) std.Build.ResolvedTarget {
    const host = b.graph.host.result;
    if (query.os_tag == host.os.tag and query.cpu_arch == host.cpu.arch and query.abi == null) {
        return b.resolveTargetQuery(.{ .cpu_model = .baseline });
    }
    return b.resolveTargetQuery(query);
}

fn lintRun(
    b: *std.Build,
    check_binary: *std.Build.Step.Compile,
    cross_target: targets.CrossTarget,
    artifact: *std.Build.Step.Compile,
    kind: []const u8,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(check_binary);
    run.addArgs(&.{ "lint", "--target", cross_target.name, "--kind", kind });
    run.addFileArg(artifact.getEmittedBin());
    return run;
}
