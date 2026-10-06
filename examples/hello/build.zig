//! examples/hello as a product repository builds it: its own app, two components, and an
//! offline bundle through the Niobium build API (docs/development/consuming.md).
//! `zig build [-Dtarget=…]` leaves the bundle in zig-out/bundle.

const std = @import("std");
const niobium = @import("niobium");

const version = "1.0.0";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const app = b.addExecutable(.{
        .name = "hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("app/main.zig"),
            .target = target,
            .optimize = .safe,
        }),
    });
    const runtime_files = b.addWriteFiles();
    // lint-allow(no-discard-call): the copy is reached through the directory below.
    _ = runtime_files.addCopyFile(
        app.getEmittedBin(),
        b.fmt("bin/hello{s}", .{target.result.exeFileExt()}),
    );
    const windows = target.result.os.tag == .windows;
    const runtime = niobium.addComponent(b, target, .{
        .id = "runtime",
        .metadata = b.path(if (windows)
            "components/runtime/component.windows.json"
        else
            "components/runtime/component.json"),
        .files = runtime_files.getDirectory(),
        .version = version,
    });
    const docs = niobium.addComponent(b, target, .{
        .id = "docs",
        .metadata = b.path("components/docs/component.json"),
        .files = b.path("components/docs/files"),
        .version = version,
    });
    const bundle = niobium.addBundle(b, .{
        .target = target,
        .product = b.path("product.json"),
        .branding = b.path("branding.json"),
        .artifacts = &.{ runtime, docs },
    });
    b.installDirectory(.{
        .source_dir = bundle.dir,
        .install_dir = .prefix,
        .install_subdir = "bundle",
    });
}
