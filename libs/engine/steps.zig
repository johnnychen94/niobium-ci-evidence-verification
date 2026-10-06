//! Prepare-stage steps: nothing here touches the install root except user-scope staging, which
//! lives inside it so placing the release is a rename.

const std = @import("std");
const platform = @import("platform");
const manifest = @import("manifest");
const portable = @import("portable");
const root = @import("root.zig");

const Engine = root.Engine;
const Error = root.Error;
const Dir = std.Io.Dir;
const artifact = portable.artifact;

fn openDownloads(e: *Engine, create: bool) Error!Dir {
    const io = e.options.io;
    const path = try std.fs.path.join(e.arena(), &.{ e.cache, "downloads" });
    const cwd = Dir.cwd();
    const dir = if (create)
        cwd.createDirPathOpen(io, path, .{})
    else
        cwd.openDir(io, path, .{});
    return dir catch |err| platform.api.mapFs(err);
}

/// Download every selected artifact into the user cache, checking length and SHA-256.
pub fn fetch(e: *Engine) Error!void {
    try e.expect(.resolved);
    const o = e.options;
    const resolution = e.resolution.?;
    e.sink().phase(.prepare);
    var total: u64 = 0;
    for (resolution.artifacts) |a| total += a.length;
    if (try o.platform.freeSpace(e.cache) < total) return error.FsNoSpace;
    var downloads = try openDownloads(e, true);
    defer downloads.close(o.io);
    var done: u64 = 0;
    e.sink().progress(.download, 0, total);
    for (resolution.artifacts) |a| {
        try e.checkCancel();
        const name = artifact.fileName(a.digest);
        try artifact.download(o.io, o.repository, a, downloads, &name);
        done += a.length;
        e.sink().progress(.download, done, total);
    }
    e.sink().phase(.verify);
    e.step = .fetched;
}

/// Extract each artifact into `<staging>/<component>/` and validate its metadata. Any failure
/// removes the staging directory.
pub fn stage(e: *Engine) Error!void {
    try e.expect(.fetched);
    const o = e.options;
    const resolution = e.resolution.?;
    const cwd = Dir.cwd();
    cwd.deleteTree(o.io, e.staging) catch |err| return platform.api.mapFs(err);
    errdefer discardStaging(e);
    var staging = cwd.createDirPathOpen(o.io, e.staging, .{}) catch |err|
        return platform.api.mapFs(err);
    defer staging.close(o.io);
    var downloads = try openDownloads(e, false);
    defer downloads.close(o.io);
    const metas = try e.arena().alloc(manifest.ComponentMeta, resolution.artifacts.len);
    var expanded: u64 = 0;
    for (resolution.artifacts, metas) |a, *meta| {
        try e.checkCancel();
        var dest = staging.createDirPathOpen(o.io, a.component, .{}) catch |err|
            return platform.api.mapFs(err);
        defer dest.close(o.io);
        const name = artifact.fileName(a.digest);
        const unpacked = try artifact.unpack(o.gpa, e.arena(), o.io, downloads, &name, dest, .{
            .component = a.component,
            .platform = o.target_platform,
            .limits = o.limits,
            .cancel = o.cancel,
        });
        meta.* = unpacked.meta;
        expanded += unpacked.expanded;
    }
    for (resolution.artifacts) |a| {
        const name = artifact.fileName(a.digest);
        downloads.deleteFile(o.io, &name) catch |err| std.log.debug("download: {t}", .{err});
    }
    // Machine scope copies the staged tree into the root; user scope renames it in place.
    if (e.scope.? == .machine and try o.platform.freeSpace(e.root) < expanded) {
        return error.FsNoSpace;
    }
    e.metas = metas;
    e.step = .staged;
}

pub fn discardStaging(e: *Engine) void {
    if (e.staging.len == 0) return;
    Dir.cwd().deleteTree(e.options.io, e.staging) catch |err|
        std.log.debug("discard staging: {t}", .{err});
}
