//! `nb-fetch-deps --manifest third_party/deps.zon --package <name> --out <dir> [--cache <dir>]
//! [--patch <file>]...`: one third-party package into `out` (docs/adr/0011-third-party-fetch.md).
//! Every download is checked against its pinned sha256 and kept in `<cache>/<sha256>`, so a
//! package is fetched once per machine; later builds work offline. The cache defaults to
//! `$NIOBIUM_DEPS_CACHE`, else `niobium-deps` in Zig's global cache directory. Patches apply
//! strictly, in the order given. `zig build` runs this per package (build/steps/deps.zig) and
//! fails a step that writes to stderr, so only failures print.

const std = @import("std");
const builtin = @import("builtin");
const patch = @import("patch.zig");

const Dir = std.Io.Dir;
const max_download = 64 << 20;
const max_patch = 1 << 20;

pub const Archive = enum { none, tar_gz };

pub const Source = struct {
    url: []const u8,
    sha256: []const u8,
    archive: Archive = .none,
    /// Leading path components removed from archive entries.
    strip_components: u32 = 0,
    /// Archive entries to keep: exact paths, or directories ending in `/`.
    extract: []const []const u8 = &.{},
    /// Destination of a plain file download.
    file: ?[]const u8 = null,
};

pub const Package = struct {
    name: []const u8,
    version: []const u8,
    sources: []const Source,
    patches: []const []const u8 = &.{},
};

pub const Manifest = struct { packages: []const Package };

const Args = struct {
    manifest: []const u8,
    package: []const u8,
    cache: ?[]const u8,
    out: []const u8,
    patches: []const []const u8,
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = parseArgs(arena, try init.minimal.args.toSlice(arena)) catch {
        std.debug.print("usage: nb-fetch-deps --manifest <deps.zon> --package <name> " ++
            "--out <dir> [--cache <dir>] [--patch <file>]...\n", .{});
        return 2;
    };
    const manifest = try loadManifest(io, arena, args.manifest);
    const package = for (manifest.packages) |p| {
        if (std.mem.eql(u8, p.name, args.package)) break p;
    } else {
        std.debug.print("fetch-deps: {s}: no package {s}\n", .{ args.manifest, args.package });
        return 1;
    };
    const cache = args.cache orelse try defaultCache(arena, init.environ_map);
    var out = try Dir.cwd().createDirPathOpen(io, args.out, .{});
    defer out.close(io);
    for (package.sources) |source| {
        const bytes = try obtain(io, init.gpa, arena, init.environ_map, cache, source);
        switch (source.archive) {
            .none => try out.writeFile(io, .{ .sub_path = source.file.?, .data = bytes }),
            .tar_gz => try extract(io, out, bytes, source),
        }
    }
    for (args.patches) |path| try applyPatch(io, arena, out, path);
    return 0;
}

fn parseArgs(arena: std.mem.Allocator, argv: []const []const u8) !Args {
    var manifest: ?[]const u8 = null;
    var package: ?[]const u8 = null;
    var cache: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var patches: std.ArrayList([]const u8) = .empty;
    var index: usize = 1;
    while (index + 1 < argv.len) : (index += 2) {
        const flag = argv[index];
        const value = argv[index + 1];
        if (std.mem.eql(u8, flag, "--manifest")) {
            manifest = value;
        } else if (std.mem.eql(u8, flag, "--package")) {
            package = value;
        } else if (std.mem.eql(u8, flag, "--cache")) {
            cache = value;
        } else if (std.mem.eql(u8, flag, "--out")) {
            out = value;
        } else if (std.mem.eql(u8, flag, "--patch")) {
            try patches.append(arena, value);
        } else return error.UsageFetchDeps;
    }
    if (index != argv.len) return error.UsageFetchDeps;
    return .{
        .manifest = manifest orelse return error.UsageFetchDeps,
        .package = package orelse return error.UsageFetchDeps,
        .cache = cache,
        .out = out orelse return error.UsageFetchDeps,
        .patches = patches.items,
    };
}

/// Mirrors Zig's own global cache resolution, so downloads live next to `zig fetch` packages.
fn defaultCache(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    if (environ.get("NIOBIUM_DEPS_CACHE")) |dir| return dir;
    const zig_cache = environ.get("ZIG_GLOBAL_CACHE_DIR") orelse if (builtin.os.tag == .windows)
        try std.fs.path.join(arena, &.{
            environ.get("LOCALAPPDATA") orelse return error.FetchNoCacheDir,
            "zig",
        })
    else if (environ.get("XDG_CACHE_HOME")) |xdg|
        try std.fs.path.join(arena, &.{ xdg, "zig" })
    else
        try std.fs.path.join(arena, &.{
            environ.get("HOME") orelse return error.FetchNoCacheDir,
            ".cache",
            "zig",
        });
    return std.fs.path.join(arena, &.{ zig_cache, "niobium-deps" });
}

fn loadManifest(io: std.Io, arena: std.mem.Allocator, path: []const u8) !Manifest {
    const bytes = try Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
    var diagnostics: std.zon.parse.Diagnostics = undefined; // SAFETY: filled by fromSlice.
    return std.zon.parse.fromSlice(Manifest, .{
        .gpa = arena,
        .arena = arena,
        .source = try arena.dupeSentinel(u8, bytes, 0),
        .diagnostics = &diagnostics,
    }) catch |err| {
        std.debug.print("fetch-deps: {f}\n", .{diagnostics.fmt(path)});
        return err;
    };
}

/// The verified bytes of `source`: from `cache/<sha256>` when present, else downloaded.
fn obtain(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    cache_path: []const u8,
    source: Source,
) ![]const u8 {
    var cache = try Dir.cwd().createDirPathOpen(io, cache_path, .{});
    defer cache.close(io);
    if (cache.readFileAlloc(io, source.sha256, arena, .limited(max_download))) |bytes| {
        // A corrupt cache entry is fetched again and overwritten.
        if (matches(bytes, source.sha256)) return bytes;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const bytes = try downloadRetrying(io, gpa, arena, environ, source.url);
    if (!matches(bytes, source.sha256)) {
        std.debug.print("fetch-deps: {s}: sha256 mismatch, expected {s}\n", .{
            source.url,
            source.sha256,
        });
        return error.FetchHashMismatch;
    }
    const tmp = try std.fmt.allocPrint(arena, "{s}.tmp", .{source.sha256});
    try cache.writeFile(io, .{ .sub_path = tmp, .data = bytes });
    try Dir.rename(cache, tmp, cache, source.sha256, io);
    return bytes;
}

/// Connections to GitHub and jsDelivr drop often enough from some networks that one attempt
/// fails builds; a hash mismatch is not retried (the caller checks it once).
fn downloadRetrying(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    url: []const u8,
) ![]const u8 {
    const retries = 3;
    var delay_seconds: i64 = 2;
    for (0..retries) |_| {
        const bytes = download(io, gpa, arena, environ, url) catch {
            try io.sleep(.fromSeconds(delay_seconds), .awake);
            delay_seconds *= 2;
            continue;
        };
        return bytes;
    }
    return download(io, gpa, arena, environ, url);
}

fn download(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    url: []const u8,
) ![]const u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    try client.initDefaultProxies(arena, environ);
    var body: std.Io.Writer.Allocating = .init(arena);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
    });
    if (result.status != .ok) {
        std.debug.print("fetch-deps: {s}: HTTP {d}\n", .{ url, @backingInt(result.status) });
        return error.FetchHttpStatus;
    }
    if (body.written().len > max_download) return error.FetchTooLarge;
    return body.written();
}

fn matches(bytes: []const u8, expected_hex: []const u8) bool {
    var digest: [32]u8 = undefined; // SAFETY: written by hash.
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.mem.eql(u8, &hex, expected_hex);
}

fn extract(io: std.Io, out: Dir, bytes: []const u8, source: Source) !void {
    var input: std.Io.Reader = .fixed(bytes);
    var window: [std.compress.flate.max_window_len]u8 = undefined; // SAFETY: inflate window.
    var inflate: std.compress.flate.Decompress = .init(&input, .gzip, &window);
    var name_buffer: [Dir.max_path_bytes]u8 = undefined; // SAFETY: tar entry names.
    var link_buffer: [Dir.max_path_bytes]u8 = undefined; // SAFETY: tar link names.
    var entries: std.tar.Iterator = .init(&inflate.reader, .{
        .file_name_buffer = &name_buffer,
        .link_name_buffer = &link_buffer,
    });
    var kept: usize = 0;
    while (try entries.next()) |entry| {
        if (entry.kind != .file) continue;
        const path = strip(entry.name, source.strip_components) orelse continue;
        if (!selected(path, source.extract)) continue;
        if (!safe(path)) return error.FetchUnsafePath;
        if (std.fs.path.dirname(path)) |parent| try out.createDirPath(io, parent);
        var file = try out.createFile(io, path, .{});
        defer file.close(io);
        var buffer: [64 << 10]u8 = undefined; // SAFETY: writer scratch.
        var writer = file.writer(io, &buffer);
        try entries.streamRemaining(entry, &writer.interface);
        try writer.interface.flush();
        kept += 1;
    }
    if (kept == 0) return error.FetchNothingExtracted;
}

fn applyPatch(io: std.Io, arena: std.mem.Allocator, out: Dir, path: []const u8) !void {
    const text = try Dir.cwd().readFileAlloc(io, path, arena, .limited(max_patch));
    for (try patch.parse(arena, text)) |file| {
        if (!safe(file.path)) return error.FetchUnsafePath;
        const original = if (file.create) "" else try out.readFileAlloc(
            io,
            file.path,
            arena,
            .limited(max_download),
        );
        const patched = patch.apply(arena, original, file) catch |err| {
            std.debug.print("fetch-deps: {s}: {s}: {t}\n", .{ path, file.path, err });
            return err;
        };
        if (std.fs.path.dirname(file.path)) |parent| try out.createDirPath(io, parent);
        try out.writeFile(io, .{ .sub_path = file.path, .data = patched });
    }
}

/// `path` without its first `count` components; null when nothing is left.
fn strip(path: []const u8, count: u32) ?[]const u8 {
    var rest = path;
    for (0..count) |_| {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        rest = rest[slash + 1 ..];
    }
    return if (rest.len == 0) null else rest;
}

fn selected(path: []const u8, keep: []const []const u8) bool {
    for (keep) |entry| {
        if (std.mem.endsWith(u8, entry, "/")) {
            if (std.mem.startsWith(u8, path, entry)) return true;
        } else if (std.mem.eql(u8, path, entry)) return true;
    }
    return false;
}

fn safe(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null) {
        return false;
    }
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) {
            return false;
        }
    }
    return true;
}

test {
    _ = patch;
}

test "archive entry selection" {
    try std.testing.expectEqualStrings("lib/zstd.h", strip("zstd-1.5.7/lib/zstd.h", 1).?);
    try std.testing.expect(strip("zstd-1.5.7/", 1) == null);
    const keep = [_][]const u8{ "LICENSE", "lib/common/" };
    try std.testing.expect(selected("lib/common/xxhash.c", &keep));
    try std.testing.expect(selected("LICENSE", &keep));
    try std.testing.expect(!selected("LICENSE.md", &keep));
    try std.testing.expect(!selected("lib/decompress/x.c", &keep));
    try std.testing.expect(!safe("../x"));
    try std.testing.expect(!safe("a//b"));
    try std.testing.expect(safe("lib/common/x.c"));
}

test "the pinned sha256 is compared as lowercase hex" {
    try std.testing.expect(matches(
        "abc",
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    ));
    try std.testing.expect(!matches("abd", "ba7816bf"));
}
