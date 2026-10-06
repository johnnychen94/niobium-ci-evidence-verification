//! Strict tar.zst artifact extraction (docs/spec/artifact-format-v1.md). Entries are written only
//! through the staging `Dir` handle with validated relative paths; `files/X` lands at `X`.
//! `component.json` is returned in memory for the caller to validate (manifest.parseComponent).

const std = @import("std");
const contracts = @import("contracts");

pub const tar = @import("tar.zig");
pub const path = @import("path.zig");
pub const fixture = @import("fixture.zig");

pub const Error = error{
    ArchiveCorrupt,
    ArchiveHeader,
    ArchiveLayout,
    ArchiveTooManyEntries,
    ArchiveEntryTooLarge,
    ArchiveBomb,
    ForbiddenEntryType,
    UnsafePath,
    DuplicateEntry,
    FsNoSpace,
    FsAccessDenied,
    FsWriteFailed,
    Canceled,
    OutOfMemory,
};

pub const Options = struct {
    /// Size of the compressed artifact, for the expansion ratio check.
    compressed_len: u64,
    limits: contracts.Limits = .{},
    cancel: ?*const std.atomic.Value(bool) = null,
};

pub const Entry = struct {
    /// Relative to the staging root (without the `files/` prefix).
    path: []const u8,
    kind: enum { file, directory },
    size: u64,
    digest: contracts.Digest,
};

pub const Extracted = struct {
    component_json: []const u8,
    entries: []const Entry,
    expanded: u64,
};

const component_name = "component.json";
const files_prefix = "files/";
const pax_max = 64 << 10;

/// `gpa` holds the zstd window for the duration of the call; results live in `arena`.
pub fn extract(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    input: *std.Io.Reader,
    staging: std.Io.Dir,
    options: Options,
) Error!Extracted {
    const window = try gpa.alloc(
        u8,
        std.compress.zstd.default_window_len + std.compress.zstd.block_size_max,
    );
    defer gpa.free(window);
    var decompress: std.compress.zstd.Decompress = .init(input, window, .{});
    var walker: Walker = .{
        .io = io,
        .arena = arena,
        .staging = staging,
        .limits = options.limits,
        .reader = &decompress.reader,
        .budget = budget(options.limits, options.compressed_len),
        .cancel = options.cancel,
    };
    try walker.run();
    return .{
        .component_json = walker.component_json orelse return error.ArchiveLayout,
        .entries = walker.entries.items,
        .expanded = walker.consumed,
    };
}

fn budget(limits: contracts.Limits, compressed_len: u64) u64 {
    const by_ratio = std.math.mul(
        u64,
        compressed_len,
        limits.compression_ratio,
    ) catch std.math.maxInt(u64);
    return @min(limits.expanded_bytes, @max(by_ratio, limits.compression_ratio_floor_bytes));
}

const Walker = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    staging: std.Io.Dir,
    limits: contracts.Limits,
    reader: *std.Io.Reader,
    budget: u64,
    cancel: ?*const std.atomic.Value(bool),
    consumed: u64 = 0,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    component_json: ?[]u8 = null,

    fn charge(w: *Walker, n: u64) Error!void {
        w.consumed = std.math.add(u64, w.consumed, n) catch return error.ArchiveBomb;
        if (w.consumed > w.budget) return error.ArchiveBomb;
    }

    fn readBlock(w: *Walker) Error!*[tar.block_len]u8 {
        try w.charge(tar.block_len);
        return w.reader.takeArray(tar.block_len) catch error.ArchiveCorrupt;
    }

    fn skip(w: *Walker, n: u64) Error!void {
        try w.charge(n);
        w.reader.discardAll64(n) catch return error.ArchiveCorrupt;
    }

    fn run(w: *Walker) Error!void {
        // loop-bound: every iteration charges at least one block against the finite budget.
        while (true) {
            if (w.cancel) |flag| {
                if (flag.load(.acquire)) return error.Canceled;
            }
            var header = try tar.parseHeader(try w.readBlock());
            if (header.kind == .end) return w.trailer();
            var pax: tar.Pax = .{};
            if (header.kind == .pax) {
                pax = try w.readPax(header.size);
                header = try tar.parseHeader(try w.readBlock());
                if (header.kind == .pax or header.kind == .end) return error.ArchiveHeader;
            }
            const name = pax.path orelse try join(w.arena, header.prefix, header.name);
            try w.entry(header.kind, name, pax.size orelse header.size);
        }
    }

    fn readPax(w: *Walker, size: u64) Error!tar.Pax {
        if (size > pax_max) return error.ArchiveHeader;
        try w.charge(size);
        const content = w.reader.readAlloc(w.arena, try usizeOf(size)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ArchiveCorrupt,
        };
        try w.skip(tar.padding(size));
        return tar.parsePax(content);
    }

    /// Everything after the end-of-archive block must be zero padding.
    fn trailer(w: *Walker) Error!void {
        var buffer: [tar.block_len]u8 = undefined; // SAFETY: filled by readSliceShort.
        // loop-bound: every iteration charges n > 0 bytes against the finite budget.
        while (true) {
            const n = w.reader.readSliceShort(&buffer) catch return error.ArchiveCorrupt;
            if (n == 0) return;
            try w.charge(n);
            for (buffer[0..n]) |byte| {
                if (byte != 0) return error.ArchiveCorrupt;
            }
        }
    }

    fn entry(w: *Walker, kind: tar.Kind, raw: []const u8, size: u64) Error!void {
        if (w.seen.count() >= w.limits.files_per_artifact) return error.ArchiveTooManyEntries;
        const name = if (kind == .directory and std.mem.endsWith(
            u8,
            raw,
            "/",
        )) raw[0 .. raw.len - 1] else raw;
        try path.check(name, w.limits);
        try w.remember(name);
        if (size > w.limits.archive_entry_bytes) return error.ArchiveEntryTooLarge;
        if (w.consumed +| size +| tar.padding(size) > w.budget) return error.ArchiveBomb;
        if (w.component_json == null) return w.component(kind, name, size);
        if (kind == .directory and std.mem.eql(u8, name, "files")) return;
        if (!std.mem.startsWith(u8, name, files_prefix)) return error.ArchiveLayout;
        const relative = name[files_prefix.len..];
        switch (kind) {
            .directory => {
                w.staging.createDirPath(w.io, relative) catch |err| return mapFs(err);
                try w.entries.append(
                    w.arena,
                    .{ .path = relative, .kind = .directory, .size = 0, .digest = @splat(0) },
                );
            },
            .file => try w.file(relative, size),
            .pax, .end => unreachable,
        }
    }

    /// Case-folded so `Bin/a` and `bin/a` collide everywhere, not only on case-insensitive volumes.
    fn remember(w: *Walker, name: []const u8) Error!void {
        const key = try std.ascii.allocLowerString(w.arena, name);
        const slot = try w.seen.getOrPut(w.arena, key);
        if (slot.found_existing) return error.DuplicateEntry;
    }

    fn component(w: *Walker, kind: tar.Kind, name: []const u8, size: u64) Error!void {
        if (kind != .file or !std.mem.eql(u8, name, component_name)) return error.ArchiveLayout;
        if (size > w.limits.manifest_bytes) return error.ArchiveEntryTooLarge;
        try w.charge(size);
        w.component_json = w.reader.readAlloc(w.arena, try usizeOf(size)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ArchiveCorrupt,
        };
        try w.skip(tar.padding(size));
    }

    fn file(w: *Walker, relative: []const u8, size: u64) Error!void {
        if (std.fs.path.dirnamePosix(relative)) |parent| {
            w.staging.createDirPath(w.io, parent) catch |err| return mapFs(err);
        }
        const out = w.staging.createFile(
            w.io,
            relative,
            .{ .exclusive = true, .resolve_beneath = true },
        ) catch |err| return mapFs(err);
        defer out.close(w.io);
        var write_buffer: [64 << 10]u8 = undefined; // SAFETY: file writer scratch.
        var hash_buffer: [4096]u8 = undefined; // SAFETY: hashed writer scratch.
        var writer = out.writer(w.io, &write_buffer);
        var hashed = writer.interface.hashed(std.crypto.hash.sha2.Sha256.init(.{}), &hash_buffer);
        try w.charge(size);
        w.reader.streamExact64(&hashed.writer, size) catch |err| switch (err) {
            error.ReadFailed, error.EndOfStream => return error.ArchiveCorrupt,
            error.WriteFailed => return mapFs(writer.err orelse error.Unexpected),
        };
        hashed.writer.flush() catch return mapFs(writer.err orelse error.Unexpected);
        writer.interface.flush() catch return mapFs(writer.err orelse error.Unexpected);
        try w.skip(tar.padding(size));
        try w.entries.append(w.arena, .{
            .path = relative,
            .kind = .file,
            .size = size,
            .digest = hashed.hasher.finalResult(),
        });
    }
};

fn usizeOf(size: u64) Error!usize {
    return std.math.cast(usize, size) orelse error.ArchiveEntryTooLarge;
}

fn join(arena: std.mem.Allocator, prefix: []const u8, name: []const u8) Error![]const u8 {
    if (prefix.len == 0) return arena.dupe(u8, name);
    return std.mem.concat(arena, u8, &.{ prefix, "/", name });
}

fn mapFs(err: anyerror) Error {
    return switch (err) {
        error.PathAlreadyExists, error.IsDir, error.NotDir => error.DuplicateEntry,
        error.NoSpaceLeft, error.DiskQuota => error.FsNoSpace,
        error.AccessDenied, error.PermissionDenied => error.FsAccessDenied,
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.FsWriteFailed,
    };
}

/// Sets the executable bit on `paths` (relative to staging). No-op where the platform has none.
pub fn markExecutables(io: std.Io, staging: std.Io.Dir, paths: []const []const u8) Error!void {
    if (!std.Io.File.Permissions.has_executable_bit) return;
    for (paths) |relative| {
        const file = staging.openFile(io, relative, .{}) catch |err| return mapFs(err);
        defer file.close(io);
        file.setPermissions(io, .executable_file) catch |err| return mapFs(err);
    }
}

test {
    _ = tar;
    _ = path;
    _ = fixture;
    _ = @import("package_test.zig");
}
