//! `zig build fuzz`: corpus replay by default; `zig build fuzz --fuzz` runs continuously.
//! Corpus seeds live in tests/fuzz/corpus/<target>/.

const std = @import("std");
const core = @import("core");
const contracts = @import("contracts");
const manifest = @import("manifest");
const package = @import("package");

test "fuzz exit-code classification" {
    try std.testing.fuzz({}, fuzzExitCode, .{ .corpus = &.{ "TrustHashMismatch", "", "Usage" } });
}

fn fuzzExitCode(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [128]u8 = @splat(0);
    const len = smith.slice(&buffer);
    const name = buffer[0..len];
    const code = core.exit_code.fromName(name);
    try std.testing.expect(@backingInt(code) <= 13);
    var out: [512]u8 = @splat(0);
    var writer: std.Io.Writer = .fixed(&out);
    try core.exit_code.eventCode(&writer, name);
}

test "fuzz tar header and pax parsing" {
    try std.testing.fuzz({}, fuzzTar, .{ .corpus = &.{ "", "13 path=a/bc\n", "ustar\x0000" } });
}

fn fuzzTar(_: void, smith: *std.testing.Smith) anyerror!void {
    var block: [package.tar.block_len]u8 = @splat(0);
    _ = smith.slice(&block); // lint-allow(no-discard-call): the length is irrelevant for a block.
    if (package.tar.parseHeader(&block)) |header| {
        try std.testing.expect(header.name.len <= 100);
        try std.testing.expect(header.prefix.len <= 155);
    } else |_| {}
    if (package.tar.parsePax(&block)) |pax| {
        if (pax.path) |p| try std.testing.expect(p.len < block.len);
    } else |_| {}
}

test "fuzz strict extraction never escapes staging" {
    try std.testing.fuzz({}, fuzzExtract, .{ .corpus = &.{ "", "component.json" } });
}

fn fuzzExtract(_: void, smith: *std.testing.Smith) anyerror!void {
    var payload: [4096]u8 = @splat(0);
    const len = smith.slice(&payload);
    const gpa = std.testing.allocator;
    const framed = try package.fixture.zstdRaw(gpa, payload[0..len]);
    defer gpa.free(framed);
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "staging");
    const staging = try tmp.dir.openDir(io, "staging", .{});
    defer staging.close(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var input: std.Io.Reader = .fixed(framed);
    const options: package.Options = .{ .compressed_len = framed.len };
    if (package.extract(gpa, arena.allocator(), io, &input, staging, options)) |_| {} else |_| {}
    var it = tmp.dir.iterate();
    while (try it.next(io)) |entry| try std.testing.expectEqualStrings("staging", entry.name);
}

test "fuzz manifest decoding" {
    try std.testing.fuzz({}, fuzzManifest, .{ .corpus = &.{ "{}", "{\"schema\":1}", "[[[[[[" } });
}

fn fuzzManifest(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [2048]u8 = @splat(0);
    const len = smith.slice(&buffer);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const limits: contracts.Limits = .{};
    if (manifest.parse(arena.allocator(), buffer[0..len], "0.1.0", limits)) |_| {} else |_| {}
}
