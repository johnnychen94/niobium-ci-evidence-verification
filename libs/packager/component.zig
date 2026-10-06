//! Component artifacts (docs/spec/component-v1.md, artifact-format-v1.md): a source
//! `component.json` without version and platform plus a payload directory become one
//! reproducible tar.zst. Validation runs the runtime's strict extractor on the result.

const std = @import("std");
const contracts = @import("contracts");
const manifest = @import("manifest");
const package = @import("package");
const zstd = @import("zstd");
const tar = @import("tar.zig");

const Map = contracts.manifest.Map;
const ComponentMeta = contracts.manifest.ComponentMeta;

/// `component.json` as the publisher writes it; `build` adds version and platform.
pub const Source = struct {
    schema: u32,
    id: []const u8,
    entrypoints: Map(contracts.manifest.Entrypoint),
    executables: []const []const u8 = &.{},
};

pub const BuildOptions = struct {
    platform: contracts.Platform,
    version: []const u8,
    level: c_int = 19,
    limits: contracts.Limits = .{},
};

const Item = struct { path: []const u8, kind: enum { file, directory } };

fn lessThan(_: void, a: Item, b: Item) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

/// Payload entries under `files`, sorted by path bytes; anything but files and directories
/// is rejected, as the runtime would.
fn collect(io: std.Io, arena: std.mem.Allocator, files: std.Io.Dir) ![]Item {
    var items: std.ArrayList(Item) = .empty;
    var walker = try files.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const kind: @FieldType(Item, "kind") = switch (entry.kind) {
            .file => .file,
            .directory => .directory,
            else => return error.PackUnsupportedEntry,
        };
        const path = try arena.dupe(u8, entry.path);
        std.mem.replaceScalar(u8, path, '\\', '/');
        try items.append(arena, .{ .path = path, .kind = kind });
    }
    std.mem.sort(Item, items.items, {}, lessThan);
    return items.items;
}

fn has(items: []const Item, path: []const u8) bool {
    for (items) |item| {
        if (item.kind == .file and std.mem.eql(u8, item.path, path)) return true;
    }
    return false;
}

pub fn metaFor(arena: std.mem.Allocator, source_json: []const u8, o: BuildOptions) !ComponentMeta {
    const source = try contracts.json.decode(Source, arena, source_json, .{
        .max_bytes = o.limits.manifest_bytes,
        .max_schema = contracts.manifest.schema_version,
        .limits = o.limits,
    });
    const meta: ComponentMeta = .{
        .schema = source.schema,
        .id = source.id,
        .version = o.version,
        .platform = o.platform,
        .entrypoints = source.entrypoints,
        .executables = source.executables,
    };
    try manifest.validate.componentMeta(meta, null, o.limits);
    return meta;
}

/// The artifact bytes for `source_json` over the payload in `files`.
pub fn build(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    source_json: []const u8,
    files: std.Io.Dir,
    o: BuildOptions,
) ![]const u8 {
    const meta = try metaFor(arena, source_json, o);
    const items = try collect(io, arena, files);
    if (items.len + 1 > o.limits.files_per_artifact) return error.ArchiveTooManyEntries;
    var it = meta.entrypoints.map.iterator();
    while (it.next()) |e| if (!has(items, e.value_ptr.path)) return error.PackMissingFile;
    for (meta.executables) |path| if (!has(items, path)) return error.PackMissingFile;
    var w: tar.Writer = .{ .gpa = gpa };
    defer w.deinit();
    const json = try std.json.Stringify.valueAlloc(arena, meta, .{});
    try w.file("component.json", json);
    for (items) |item| {
        try package.path.check(item.path, o.limits);
        const name = try std.fmt.allocPrint(arena, "files/{s}", .{item.path});
        switch (item.kind) {
            .directory => try w.dir(name),
            .file => {
                const limit: std.Io.Limit = .limited(o.limits.archive_entry_bytes);
                const data = try files.readFileAlloc(io, item.path, gpa, limit);
                defer gpa.free(data);
                try w.file(name, data);
            },
        }
    }
    try w.finish();
    const frame = try zstd.compress(gpa, w.bytes.items, o.level);
    defer gpa.free(frame);
    return arena.dupe(u8, frame);
}

/// Extracts `bytes` into the empty directory `scratch` with the runtime's walker and checks the
/// metadata against the payload; returns the metadata.
pub fn validate(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    bytes: []const u8,
    scratch: std.Io.Dir,
    expected: ?contracts.Platform,
) !ComponentMeta {
    const limits: contracts.Limits = .{};
    var reader: std.Io.Reader = .fixed(bytes);
    const extracted = try package.extract(gpa, arena, io, &reader, scratch, .{
        .compressed_len = bytes.len,
        .limits = limits,
    });
    const meta = try manifest.parseComponent(arena, extracted.component_json, expected, limits);
    var it = meta.entrypoints.map.iterator();
    while (it.next()) |e| {
        if (!extractedFile(extracted.entries, e.value_ptr.path)) return error.PackMissingFile;
    }
    for (meta.executables) |path| {
        if (!extractedFile(extracted.entries, path)) return error.PackMissingFile;
    }
    return meta;
}

fn extractedFile(entries: []const package.Entry, path: []const u8) bool {
    for (entries) |entry| {
        if (entry.kind == .file and std.mem.eql(u8, entry.path, path)) return true;
    }
    return false;
}
