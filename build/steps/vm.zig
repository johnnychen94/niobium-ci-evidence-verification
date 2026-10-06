//! `zig build vm-smoke`: a branded offline bundle of examples/hello per VM target, driven in
//! Parallels guests by tools/vm-smoke (docs/runbooks/vm-smoke.md).

const std = @import("std");
const targets = @import("../targets.zig");
const example = @import("example.zig");

/// `targets.cross_targets` names with a VM in tools/vm-smoke.
const vm_targets = [_][]const u8{ "x86_64-windows", "aarch64-linux" };

pub fn add(b: *std.Build, tool: *std.Build.Step.Compile) *std.Build.Step {
    const run = b.addRunArtifact(tool);
    run.addArg("--prlctl");
    run.addFileArg(b.findProgramLazy(.{ .names = &.{"prlctl"} }));
    run.addArgs(&.{ "--evidence", ".evidence/vm-smoke" });
    for (targets.cross_targets) |cross_target| {
        if (!isVm(cross_target.name)) continue;
        const triple = cross_target.query.zigTriple(b.allocator) catch @panic("OOM");
        run.addArgs(&.{ "--bundle", cross_target.name });
        run.addDirectoryArg(example.bundle(b, triple));
    }
    run.addPassthruArgs();
    run.has_side_effects = true;
    run.setCwd(b.path("."));
    return &run.step;
}

fn isVm(name: []const u8) bool {
    for (vm_targets) |vm| {
        if (std.mem.eql(u8, vm, name)) return true;
    }
    return false;
}
