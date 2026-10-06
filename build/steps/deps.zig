//! Third-party sources from third_party/deps.zon (docs/adr/0014-third-party-fetch.md): one
//! tools/fetch-deps run per package. Its output is keyed on the manifest and the patch files,
//! so the network is touched once per pin; downloads persist in the tool's cache directory.

const std = @import("std");
const graph_mod = @import("../graph.zig");

const manifest_path = "third_party/deps.zon";
const manifest = @import("../../third_party/deps.zon");

pub fn add(b: *std.Build, tool: *std.Build.Step.Compile) graph_mod.Deps {
    // SAFETY: every field is assigned in the loop, which covers each manifest package.
    var deps: graph_mod.Deps = undefined;
    comptime std.debug.assert(manifest.packages.len == std.meta.fieldNames(graph_mod.Deps).len);
    inline for (manifest.packages) |package| {
        @field(deps, package.name) = fetch(b, tool, package.name, &package.patches);
    }
    return deps;
}

fn fetch(
    b: *std.Build,
    tool: *std.Build.Step.Compile,
    name: []const u8,
    patches: []const []const u8,
) std.Build.LazyPath {
    const run = b.addRunArtifact(tool);
    run.setName(b.fmt("fetch {s}", .{name}));
    run.addArg("--manifest");
    run.addFileArg(b.path(manifest_path));
    run.addArgs(&.{ "--package", name });
    for (patches) |patch| {
        run.addArg("--patch");
        run.addFileArg(b.path(b.fmt("third_party/{s}/patches/{s}", .{ name, patch })));
    }
    run.addArg("--out");
    return run.addOutputDirectoryArg(name);
}
