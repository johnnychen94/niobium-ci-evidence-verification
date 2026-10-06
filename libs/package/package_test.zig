const std = @import("std");
const contracts = @import("contracts");
const package = @import("root.zig");
const Tar = package.fixture.Tar;

const component_json = "{\"schema\":1}";

const Harness = struct {
    tmp: std.testing.TmpDir,
    staging: std.Io.Dir,
    arena: std.heap.ArenaAllocator,

    fn init() !Harness {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(std.testing.io, "staging");
        const staging = try tmp.dir.openDir(std.testing.io, "staging", .{ .iterate = true });
        return .{ .tmp = tmp, .staging = staging, .arena = .init(std.testing.allocator) };
    }

    fn deinit(h: *Harness) void {
        h.staging.close(std.testing.io);
        h.arena.deinit();
        h.tmp.cleanup();
    }

    fn extract(
        h: *Harness,
        compressed: []const u8,
        limits: contracts.Limits,
    ) package.Error!package.Extracted {
        var input: std.Io.Reader = .fixed(compressed);
        const options: package.Options = .{ .compressed_len = compressed.len, .limits = limits };
        const gpa = std.testing.allocator;
        const arena = h.arena.allocator();
        return package.extract(gpa, arena, std.testing.io, &input, h.staging, options);
    }

    /// N1-INV-02: the only thing next to staging is staging itself.
    fn expectContained(h: *Harness) !void {
        var it = h.tmp.dir.iterate();
        var count: usize = 0;
        while (try it.next(std.testing.io)) |entry| {
            try std.testing.expectEqualStrings("staging", entry.name);
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), count);
    }
};

fn compress(t: *Tar) ![]u8 {
    return package.fixture.zstdRaw(std.testing.allocator, t.bytes.items);
}

test "extracts a well-formed artifact" {
    var h: Harness = try .init();
    defer h.deinit();
    var t: Tar = .{ .gpa = std.testing.allocator };
    defer t.deinit();
    try t.file("component.json", component_json);
    try t.dir("files/");
    try t.dir("files/bin/");
    try t.file("files/bin/hello", "#!/bin/sh\necho hi\n");
    const long = "files/share/very/long/directory/name/that/keeps/going/and/going/" ++
        "until/it/no/longer/fits/in/one/hundred/bytes/readme.txt";
    try t.paxPath(long);
    try t.header('0', "ignored", 3);
    try t.data("abc");
    try t.end();
    const compressed = try compress(&t);
    defer std.testing.allocator.free(compressed);
    const got = try h.extract(compressed, .{});
    try std.testing.expectEqualStrings(component_json, got.component_json);
    try std.testing.expectEqual(@as(usize, 3), got.entries.len);
    const hello = try h.staging.readFileAlloc(
        std.testing.io,
        "bin/hello",
        h.arena.allocator(),
        .limited(64),
    );
    try std.testing.expectEqualStrings("#!/bin/sh\necho hi\n", hello);
    const readme = try h.staging.readFileAlloc(
        std.testing.io,
        long["files/".len..],
        h.arena.allocator(),
        .limited(8),
    );
    try std.testing.expectEqualStrings("abc", readme);
    try package.markExecutables(std.testing.io, h.staging, &.{"bin/hello"});
    try h.expectContained();
}

const Case = struct {
    name: []const u8,
    build: *const fn (*Tar) anyerror!void,
    expected: package.Error,
    limits: contracts.Limits = .{},
};

fn withComponent(t: *Tar) !void {
    try t.file("component.json", component_json);
}

fn entryCase(comptime flag: u8, comptime name: []const u8) *const fn (*Tar) anyerror!void {
    return struct {
        fn build(t: *Tar) anyerror!void {
            try withComponent(t);
            try t.header(flag, name, 0);
            try t.end();
        }
    }.build;
}

fn duplicate(t: *Tar) anyerror!void {
    try withComponent(t);
    try t.file("files/a", "1");
    try t.file("files/a", "2");
    try t.end();
}

fn caseDuplicate(t: *Tar) anyerror!void {
    try withComponent(t);
    try t.file("files/README", "1");
    try t.file("files/readme", "2");
    try t.end();
}

fn fileThenChild(t: *Tar) anyerror!void {
    try withComponent(t);
    try t.file("files/a", "1");
    try t.file("files/a/b", "2");
    try t.end();
}

fn componentNotFirst(t: *Tar) anyerror!void {
    try t.file("files/a", "1");
    try withComponent(t);
    try t.end();
}

fn paxTraversal(t: *Tar) anyerror!void {
    try withComponent(t);
    try t.pax("21 path=../../escape\n");
    try t.header('0', "files/innocent", 1);
    try t.data("x");
    try t.end();
}

fn badChecksum(t: *Tar) anyerror!void {
    try withComponent(t);
    try t.file("files/a", "1");
    t.bytes.items[tar_second_header + 10] ^= 0x20;
    try t.end();
}

const tar_second_header = 1024;

fn trailingGarbage(t: *Tar) anyerror!void {
    try withComponent(t);
    try t.end();
    try t.bytes.appendSlice(t.gpa, "smuggled");
}

fn truncated(t: *Tar) anyerror!void {
    try withComponent(t);
    try t.header('0', "files/a", 4096);
    try t.data("short");
}

fn oversize(t: *Tar) anyerror!void {
    try withComponent(t);
    try t.header('0', "files/huge", (2 << 30) + 1);
    try t.end();
}

fn manyEntries(t: *Tar) anyerror!void {
    try withComponent(t);
    try t.file("files/a", "1");
    try t.file("files/b", "2");
    try t.file("files/c", "3");
    try t.end();
}

fn declaredBomb(t: *Tar) anyerror!void {
    try withComponent(t);
    try t.header('0', "files/zeros", 64 << 20);
    try t.end();
}

const cases = [_]Case{
    .{
        .name = "traversal",
        .build = entryCase('0', "files/../../escape"),
        .expected = error.UnsafePath,
    },
    .{ .name = "absolute", .build = entryCase('0', "/etc/escape"), .expected = error.UnsafePath },
    .{
        .name = "backslash",
        .build = entryCase('0', "files\\..\\escape"),
        .expected = error.UnsafePath,
    },
    .{ .name = "drive", .build = entryCase('0', "C:/escape"), .expected = error.UnsafePath },
    .{ .name = "reserved", .build = entryCase('0', "files/CON"), .expected = error.UnsafePath },
    .{ .name = "pax traversal", .build = paxTraversal, .expected = error.UnsafePath },
    .{
        .name = "hardlink",
        .build = entryCase('1', "files/link"),
        .expected = error.ForbiddenEntryType,
    },
    .{
        .name = "symlink",
        .build = entryCase('2', "files/link"),
        .expected = error.ForbiddenEntryType,
    },
    .{
        .name = "char device",
        .build = entryCase('3', "files/tty"),
        .expected = error.ForbiddenEntryType,
    },
    .{
        .name = "block device",
        .build = entryCase('4', "files/sda"),
        .expected = error.ForbiddenEntryType,
    },
    .{
        .name = "fifo",
        .build = entryCase('6', "files/fifo"),
        .expected = error.ForbiddenEntryType,
    },
    .{
        .name = "gnu longname",
        .build = entryCase('L', "././@LongLink"),
        .expected = error.ForbiddenEntryType,
    },
    .{
        .name = "global pax",
        .build = entryCase('g', "pax_global_header"),
        .expected = error.ForbiddenEntryType,
    },
    .{ .name = "duplicate", .build = duplicate, .expected = error.DuplicateEntry },
    .{ .name = "case duplicate", .build = caseDuplicate, .expected = error.DuplicateEntry },
    .{ .name = "file then child", .build = fileThenChild, .expected = error.DuplicateEntry },
    .{ .name = "component not first", .build = componentNotFirst, .expected = error.ArchiveLayout },
    .{
        .name = "outside files/",
        .build = entryCase('0', "other/x"),
        .expected = error.ArchiveLayout,
    },
    .{ .name = "bad checksum", .build = badChecksum, .expected = error.ArchiveHeader },
    .{ .name = "trailing garbage", .build = trailingGarbage, .expected = error.ArchiveCorrupt },
    .{ .name = "truncated", .build = truncated, .expected = error.ArchiveCorrupt },
    .{ .name = "oversize entry", .build = oversize, .expected = error.ArchiveEntryTooLarge },
    .{ .name = "declared bomb", .build = declaredBomb, .expected = error.ArchiveBomb },
    .{
        .name = "too many entries",
        .build = manyEntries,
        .expected = error.ArchiveTooManyEntries,
        .limits = limitedEntries(3),
    },
};

fn limitedEntries(n: u32) contracts.Limits {
    var limits: contracts.Limits = .{};
    limits.files_per_artifact = n;
    return limits;
}

test "N1-AC-04 malicious archives are rejected and never escape staging" {
    for (cases) |case| {
        var h: Harness = try .init();
        defer h.deinit();
        var t: Tar = .{ .gpa = std.testing.allocator };
        defer t.deinit();
        try case.build(&t);
        const compressed = try compress(&t);
        defer std.testing.allocator.free(compressed);
        const result = h.extract(compressed, case.limits);
        if (result) |_| {
            std.log.err("case '{s}' unexpectedly extracted", .{case.name});
            return error.TestUnexpectedResult;
        } else |err| {
            if (err != case.expected) {
                std.log.err(
                    "case '{s}': expected {t}, got {t}",
                    .{ case.name, case.expected, err },
                );
                return error.TestUnexpectedResult;
            }
        }
        try h.expectContained();
    }
}

test "N1-AC-04 RLE decompression bomb trips the expansion budget" {
    var h: Harness = try .init();
    defer h.deinit();
    var t: Tar = .{ .gpa = std.testing.allocator };
    defer t.deinit();
    try withComponent(&t);
    const bomb = try package.fixture.zstdBomb(std.testing.allocator, t.bytes.items, 256 << 20);
    defer std.testing.allocator.free(bomb);
    try std.testing.expect(bomb.len < 16 << 10);
    try std.testing.expectError(error.ArchiveBomb, h.extract(bomb, .{}));
    try h.expectContained();
}

test "not zstd" {
    var h: Harness = try .init();
    defer h.deinit();
    try std.testing.expectError(
        error.ArchiveCorrupt,
        h.extract("PK\x03\x04 definitely a zip", .{}),
    );
}
