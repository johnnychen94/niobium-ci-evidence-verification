//! `zig build example`: examples/hello is its own package and depends on this one by path,
//! the way a product repository does (docs/development/consuming.md). Building it in a child
//! `zig build` exercises the public build API end to end.

const std = @import("std");

/// The child build's `bundle/` (setup, repository/, licenses/) installed as zig-out/example.
pub fn add(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step {
    const triple = if (target.query.isNative()) null else target.query.zigTriple(b.allocator) catch
        @panic("OOM");
    const install = b.addInstallDirectory(.{
        .source_dir = bundle(b, triple),
        .install_dir = .prefix,
        .install_subdir = "example",
    });
    return &install.step;
}

/// `bundle/` of examples/hello built for `triple` (null: the build host).
pub fn bundle(b: *std.Build, triple: ?[]const u8) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    run.setName(b.fmt("zig build examples/hello ({s})", .{triple orelse "native"}));
    run.setCwd(b.path("examples/hello"));
    if (triple) |t| run.addArg(b.fmt("-Dtarget={s}", .{t}));
    run.addArg("--prefix");
    const prefix = run.addOutputDirectoryArg("prefix");
    // The child tracks its own inputs (both packages' sources); always ask it.
    run.has_side_effects = true;
    return prefix.path(b, "bundle");
}
