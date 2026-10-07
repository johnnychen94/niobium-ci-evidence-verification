//! Explicit deployment verification; ordinary unit runs never contact the archive.
const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts");
const archive = @import("archive.zig");
const model = @import("model.zig");
const store = @import("store.zig");
const io = std.testing.io;

test "N1-AC-20 live R2 immutability, partial publication, pagination and multipart interruption" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try std.testing.environ.createMap(a);
    defer env.deinit();
    if (!std.mem.eql(u8, env.get("NIOBIUM_R2_LIVE_VERIFY") orelse "0", "1"))
        return error.SkipZigTest;
    const client = try archive.Client.init(.{
        .minimal = .{ .environ = std.testing.environ, .args = .{ .vector = &.{} } },
        .gpa = std.testing.allocator,
        .arena = &arena,
        .io = io,
        .environ_map = &env,
        .preopens = .empty,
    });
    defer std.Io.Dir.cwd().deleteTree(io, client.scratch) catch |err|
        std.debug.print("live verification cleanup: {t}\n", .{err});
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    var report = @import("report_test.zig").fixtureReport();
    report.started_ms = std.Io.Clock.real.now(io).toMilliseconds();
    report.finished_ms = report.started_ms;
    report.repository = "fixture/archive";
    report.run = "verification";
    report.os = @tagName(builtin.os.tag);
    report.cpu = @tagName(builtin.cpu.arch);
    report.verdict = .NOT_RUN;
    report.reason = "Protocol fixture, not conformance certification";
    var random: [8]u8 = undefined; // SAFETY: random initializes all bytes.
    io.random(&random);
    report.execution = try std.fmt.allocPrint(a, "{d}-{s}", .{
        report.started_ms, std.fmt.bytesToHex(random, .lower),
    });
    for ([_][]const u8{ "stdout.txt", "stderr.txt", "probe-a.bin", "probe-b.bin" }) |file|
        try tmp.dir.writeFile(io, .{ .sub_path = file, .data = file });
    try store.collect(a, io, path, &report);
    try store.save(a, io, path, report);
    const root = try std.fmt.allocPrint(a, "{s}/reports/v1/{s}/", .{
        try model.reportPrefix(a, report), try model.identity(a, report),
    });
    try immutable(client, root);
    // A stopped publication may leave one attachment, but no visible report.
    try client.put(report.attachments[0].key, report.attachments[0].file);
    try absent(client, try std.fmt.allocPrint(a, "{s}report.json", .{root}));
    try archive.publish(client, path);
    try archive.publish(client, path);
    try pagination(client, root);
    try multipart(client, try model.objectKey(a, report, "interrupted.bin"), path);
    std.debug.print("R2 live: readback/digests, duplicate/conflict, report-last recovery, " ++
        "pagination, multipart abort and object retention headers verified\n", .{});
}

fn checked(client: archive.Client, args: []const []const u8) ![]const u8 {
    const result = try client.invoke(args);
    if (result.code != 0 or result.reason.len > 0) return error.LiveArchiveOperationFailed;
    return result.stdout;
}

fn decoded(client: archive.Client, args: []const []const u8) !std.json.Value {
    const value = try contracts.json.decodeValue(client.a, try checked(client, args), .{
        .max_bytes = model.limits.test_report_bytes,
    });
    if (value != .object) return error.InvalidArchiveResponse;
    return value;
}

fn immutable(client: archive.Client, root: []const u8) !void {
    const key = try std.fmt.allocPrint(client.a, "{s}probe-a.txt", .{root});
    try client.put(key, "good");
    try client.put(key, "good");
    try std.testing.expectError(error.ArchiveConflict, client.put(key, "evil"));
    try client.put(key, "good"); // Includes readback proving the original remains.
    try client.put(try std.fmt.allocPrint(client.a, "{s}probe-b.txt", .{root}), "second");
}

fn absent(client: archive.Client, key: []const u8) !void {
    const result = try client.invoke(&.{ "head-object", "--bucket", client.bucket, "--key", key });
    try std.testing.expect(result.code != 0);
    try std.testing.expect(std.mem.find(u8, result.stderr, "404") != null);
}

fn pagination(client: archive.Client, prefix: []const u8) !void {
    var token: ?[]const u8 = null;
    var count: usize = 0;
    for (0..model.limits.test_github_pages) |_| {
        const args = try std.mem.concat(client.a, []const u8, &.{
            &.{
                "list-objects-v2",
                "--bucket",
                client.bucket,
                "--prefix",
                prefix,
                "--max-keys",
                "1",
                "--no-paginate",
            },
            if (token) |value| &.{ "--continuation-token", value } else &.{},
        });
        const value = try decoded(client, args);
        const contents = value.object.get("Contents") orelse return error.MissingArchiveObjects;
        if (contents != .array) return error.InvalidArchivePage;
        try std.testing.expectEqual(@as(usize, 1), contents.array.items.len);
        count += contents.array.items.len;
        const truncated = value.object.get("IsTruncated") orelse return error.InvalidArchivePage;
        if (truncated != .bool) return error.InvalidArchivePage;
        if (!truncated.bool) {
            try std.testing.expectEqual(@as(usize, 3), count);
            return;
        }
        const next = value.object.get("NextContinuationToken") orelse
            return error.MissingContinuationToken;
        if (next != .string or next.string.len == 0) return error.MissingContinuationToken;
        token = next.string;
    }
    return error.ArchivePaginationLimit;
}

fn multipart(client: archive.Client, key: []const u8, path: []const u8) !void {
    const created = try decoded(client, &.{
        "create-multipart-upload", "--bucket", client.bucket, "--key", key,
    });
    const upload = created.object.get("UploadId") orelse return error.MissingUploadId;
    if (upload != .string or upload.string.len == 0) return error.MissingUploadId;
    const id = upload.string;
    const body = try std.fs.path.join(client.a, &.{ path, "multipart-part" });
    const bytes = try client.a.alloc(u8, 5 << 20);
    @memset(bytes, 'x');
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = body, .data = bytes });
    const uploaded = try checked(client, &.{
        "upload-part", "--bucket", client.bucket,   "--key", key,
        "--upload-id", id,         "--part-number", "1",     "--body",
        body,
    });
    try std.testing.expect(uploaded.len > 0);
    try absent(client, key);
    const aborted = try checked(client, &.{
        "abort-multipart-upload", "--bucket", client.bucket, "--key", key, "--upload-id", id,
    });
    try std.testing.expect(std.mem.trim(u8, aborted, "\r\n ").len == 0);
}
