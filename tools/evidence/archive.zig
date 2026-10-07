//! Immutable R2 transport. AWS CLI owns authentication; report contents never configure it.
const std = @import("std");
const model = @import("model.zig");
const process = @import("process.zig");
const store = @import("store.zig");
const contracts = @import("contracts");
pub const aws_version = "2.27.49";

pub const Client = struct {
    a: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    endpoint: []const u8,
    bucket: []const u8,
    scratch: []const u8,

    pub fn init(context: std.process.Init) !Client {
        const a = context.arena.allocator();
        const env = context.environ_map;
        const endpoint = env.get("R2_ENDPOINT") orelse return error.MissingR2Endpoint;
        const bucket = env.get("R2_BUCKET") orelse return error.MissingR2Bucket;
        try validateEndpoint(endpoint);
        if (!model.segment(bucket)) return error.InvalidR2Configuration;
        if (env.get("AWS_ACCESS_KEY_ID") == null or env.get("AWS_SECRET_ACCESS_KEY") == null)
            return error.MissingR2Credentials;
        // Native SDK transport retries are bounded by both attempts and the process deadline.
        try env.put("AWS_MAX_ATTEMPTS", "3");
        try env.put("AWS_RETRY_MODE", "standard");
        try env.put("AWS_EC2_METADATA_DISABLED", "true");
        try env.put("AWS_REQUEST_CHECKSUM_CALCULATION", "WHEN_REQUIRED");
        try env.put("AWS_RESPONSE_CHECKSUM_VALIDATION", "WHEN_REQUIRED");
        const version = try process.run(
            a,
            context.io,
            .{ .argv = &.{ "aws", "--version" }, .env = env, .timeout_ms = 10_000 },
        );
        if (version.code != 0 or
            !std.mem.startsWith(u8, version.stdout, "aws-cli/" ++ aws_version ++ " "))
            return error.WrongAwsCliVersion;
        var random: [8]u8 = undefined; // SAFETY: random fills all bytes.
        context.io.random(&random);
        const scratch = try std.fmt.allocPrint(a, ".zig-cache/evidence-{s}", .{
            std.fmt.bytesToHex(random, .lower),
        });
        try std.Io.Dir.cwd().createDirPath(context.io, scratch);
        return .{
            .a = a,
            .gpa = context.gpa,
            .io = context.io,
            .env = env,
            .endpoint = endpoint,
            .bucket = bucket,
            .scratch = scratch,
        };
    }

    pub fn invoke(c: Client, args: []const []const u8) !process.Result {
        const argv = try std.mem.concat(c.a, []const u8, &.{ &.{
            "aws",
            "--endpoint-url",
            c.endpoint,
            "--region",
            "auto",
            "--no-cli-pager",
            "--cli-connect-timeout",
            "10",
            "--cli-read-timeout",
            "60",
            "s3api",
        }, args });
        return process.run(c.a, c.io, .{ .argv = argv, .env = c.env, .timeout_ms = 120_000 });
    }

    pub fn put(c: Client, key: []const u8, bytes: []const u8) !void {
        if (bytes.len > model.limits.test_attachment_bytes) return error.ObjectTooLarge;
        const source = try std.fs.path.join(c.a, &.{ c.scratch, "upload" });
        try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = source, .data = bytes });
        const result = try c.invoke(&.{
            "put-object",
            "--bucket",
            c.bucket,
            "--key",
            key,
            "--body",
            source,
            "--if-none-match",
            "*",
            "--storage-class",
            "STANDARD",
        });
        if (result.code != 0 and std.mem.find(
            u8,
            result.stderr,
            "PreconditionFailed",
        ) == null and std.mem.find(u8, result.stderr, "ConditionalRequestConflict") == null) {
            transportFailure("put", key, result);
            return error.ArchiveUploadFailed;
        }
        // Always read back: neither success nor an ETag proves the intended bytes were stored.
        const stored = try c.get(key, bytes.len);
        defer c.a.free(stored);
        try identical(bytes, stored);
    }

    fn get(c: Client, key: []const u8, size: usize) ![]const u8 {
        const target = try std.fs.path.join(c.a, &.{ c.scratch, "download" });
        const head = try c.invoke(&.{
            "head-object",
            "--bucket",
            c.bucket,
            "--key",
            key,
            "--query",
            "[ContentLength,Expiration]",
            "--output",
            "json",
        });
        if (head.code != 0) {
            transportFailure("head", key, head);
            return error.ArchiveReadbackFailed;
        }
        const info = try contracts.json.decodeValue(c.a, head.stdout, .{
            .max_bytes = model.limits.test_report_bytes,
        });
        if (info != .array or info.array.items.len != 2 or info.array.items[0] != .integer)
            return error.ArchiveReadbackFailed;
        const length = std.math.cast(u64, info.array.items[0].integer) orelse
            return error.ArchiveReadbackFailed;
        if (length != size) return error.ArchiveConflict;
        const expiration = info.array.items[1];
        if (expiration != .null and (expiration != .string or expiration.string.len == 0))
            return error.ArchiveReadbackFailed;
        const ordinary = std.mem.find(u8, key, "/evidence/v1/") != null;
        if ((expiration != .null) != ordinary) return error.ArchiveRetentionMismatch;
        const range = try std.fmt.allocPrint(c.a, "bytes=0-{d}", .{size});
        const args = try std.mem.concat(c.a, []const u8, &.{
            &.{ "get-object", "--bucket", c.bucket, "--key", key },
            if (size == 0) &.{} else &.{ "--range", range },
            &.{target},
        });
        const result = try c.invoke(args);
        if (result.code != 0) {
            transportFailure("get", key, result);
            return error.ArchiveReadbackFailed;
        }
        return std.Io.Dir.cwd().readFileAlloc(
            c.io,
            target,
            c.a,
            .limited(model.limits.test_attachment_bytes),
        );
    }
};

fn transportFailure(operation: []const u8, key: []const u8, result: process.Result) void {
    // Operation/key/status are sufficient for recovery; never print SDK errors or credentials.
    std.debug.print("archive {s} failed: {s}; exit={d}; reason={s}\n", .{
        operation, key, result.code, result.reason,
    });
}

fn validateEndpoint(endpoint: []const u8) !void {
    const host = std.mem.cutPrefix(u8, endpoint, "https://") orelse
        return error.InvalidR2Endpoint;
    const account = std.mem.cutSuffix(u8, host, ".r2.cloudflarestorage.com") orelse
        return error.InvalidR2Endpoint;
    var parts = std.mem.splitScalar(u8, account, '.');
    const id = parts.next() orelse return error.InvalidR2Endpoint;
    if (id.len != 32) return error.InvalidR2Endpoint;
    for (id) |c| if (!std.ascii.isHex(c)) return error.InvalidR2Endpoint;
    if (parts.next()) |jurisdiction| {
        if (!std.mem.eql(u8, jurisdiction, "us") and !std.mem.eql(u8, jurisdiction, "eu") and
            !std.mem.eql(u8, jurisdiction, "fedramp")) return error.InvalidR2Endpoint;
    }
    if (parts.next() != null) return error.InvalidR2Endpoint;
}

pub fn identical(expected: []const u8, actual: []const u8) error{ArchiveConflict}!void {
    if (expected.len != actual.len or !std.mem.eql(
        u8,
        &model.digest(expected),
        &model.digest(actual),
    )) return error.ArchiveConflict;
}

pub fn publish(c: Client, path: []const u8) !void {
    var report = try store.load(c.a, c.io, path);
    if (!report.complete) {
        try store.collect(c.a, c.io, path, &report);
        try model.validate(report);
    }
    try store.rekey(c.a, &report);
    try store.save(c.a, c.io, path, report);
    var dir = try std.Io.Dir.cwd().openDir(c.io, path, .{});
    defer dir.close(c.io);
    try uploadAttachments(c, dir, report.attachments);
    const key = try std.fmt.allocPrint(c.a, "{s}/reports/v1/{s}/report.json", .{
        try model.reportPrefix(c.a, report), try model.identity(c.a, report),
    });
    try c.put(key, try store.read(c.a, c.io, dir, "report.json", model.limits.test_report_bytes));
    std.debug.print(
        "published {t}/{s}: {t}\n",
        .{ report.suite, report.execution, report.verdict },
    );
}

fn upload(c: Client, dir: std.Io.Dir, attachment: model.Attachment, index: usize) !void {
    var arena: std.heap.ArenaAllocator = .init(c.gpa);
    defer arena.deinit();
    var transfer = c;
    transfer.a = arena.allocator();
    transfer.scratch = try std.fmt.allocPrint(transfer.a, "{s}/transfers/{d}", .{
        c.scratch, index,
    });
    try std.Io.Dir.cwd().createDirPath(c.io, transfer.scratch);
    const bytes = try store.read(
        transfer.a,
        c.io,
        dir,
        attachment.file,
        model.limits.test_attachment_bytes,
    );
    try transfer.put(attachment.key, bytes);
}

fn uploadAttachments(c: Client, dir: std.Io.Dir, attachments: []const model.Attachment) !void {
    const Result = @typeInfo(@TypeOf(upload)).@"fn".return_type.?;
    var active: [model.limits.test_archive_workers]?std.Io.Future(Result) = @splat(null);
    defer for (&active) |*slot| {
        if (slot.*) |*future| future.cancel(c.io) catch |err|
            std.debug.print("attachment cancellation: {t}\n", .{err});
    };
    for (attachments, 0..) |attachment, index| {
        const slot = &active[index % active.len];
        if (slot.*) |*future| {
            const result = future.await(c.io);
            slot.* = null;
            try result;
        }
        slot.* = try std.Io.concurrent(c.io, upload, .{ c, dir, attachment, index });
    }
    for (&active) |*slot| if (slot.*) |*future| {
        const result = future.await(c.io);
        slot.* = null;
        try result;
    };
}

test "N1-AC-20 R2 endpoint accepts only account and documented jurisdiction hosts" {
    const account = "0123456789abcdef0123456789abcdef";
    for ([_][]const u8{ "", ".us", ".eu", ".fedramp" }) |suffix| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        try validateEndpoint(try std.fmt.allocPrint(
            arena.allocator(),
            "https://{s}{s}.r2.cloudflarestorage.com",
            .{ account, suffix },
        ));
    }
    for ([_][]const u8{
        "http://" ++ account ++ ".r2.cloudflarestorage.com",
        "https://" ++ account ++ ".unknown.r2.cloudflarestorage.com",
        "https://" ++ account ++ ".us.extra.r2.cloudflarestorage.com",
        "https://" ++ account ++ ".r2.cloudflarestorage.com/bucket",
    }) |endpoint| try std.testing.expectError(error.InvalidR2Endpoint, validateEndpoint(endpoint));
}

test "N1-AC-20 duplicate publication accepts only identical bytes" {
    try identical("saved report", "saved report");
    try std.testing.expectError(error.ArchiveConflict, identical("saved report", "changed data"));
    try std.testing.expectError(error.ArchiveConflict, identical("saved report", "saved"));
}
