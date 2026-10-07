const std = @import("std");
const builtin = @import("builtin");
const model = @import("model.zig");
const store = @import("store.zig");
const process = @import("process.zig");

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    if (args.len < 11) return error.InvalidArguments;
    const a = init.arena.allocator();
    const io = init.io;
    var env = try init.minimal.environ.createMap(a);
    var report = try metadata(a, io, &env, args);
    const path = try std.fmt.allocPrint(a, ".evidence/{t}/{s}", .{
        report.suite, report.execution,
    });
    try std.Io.Dir.cwd().createDirPath(io, path);
    try store.save(a, io, path, report);
    const binary = try std.Io.Dir.cwd().readFileAlloc(
        io,
        args[args.len - 1],
        a,
        .limited(model.limits.test_attachment_bytes),
    );
    try write(a, io, path, "test-binary.sha256", &model.digest(binary));
    try env.put("NIOBIUM_EVIDENCE_DIR", path);
    try env.put("NIOBIUM_TEST_CASE", args[5]);
    const result = process.run(a, io, .{ .argv = args[10..], .env = &env }) catch |err| {
        report.reason = @errorName(err);
        report.verdict = .BLOCKED;
        report.finished_ms = std.Io.Clock.real.now(io).toMilliseconds();
        try store.save(a, io, path, report);
        return err;
    };
    try write(a, io, path, "stdout.txt", result.stdout);
    try write(a, io, path, "stderr.txt", result.stderr);
    report.finished_ms = std.Io.Clock.real.now(io).toMilliseconds();
    report.complete = true;
    report.verdict = if (result.code == 0 and result.reason.len == 0) .PASS else .FAIL;
    report.reason = result.reason;
    try store.collect(a, io, path, &report);
    model.validate(report) catch |err| {
        report.verdict = .FAIL;
        report.reason = @errorName(err);
        report.complete = false;
        try store.save(a, io, path, report);
        return err;
    };
    try store.save(a, io, path, report);
    std.debug.print("{t}/{s}: {t} ({s})\n", .{
        report.suite, args[3], report.verdict, path,
    });
    if (report.verdict != .PASS) {
        std.debug.print("{s}\n{s}\n", .{ result.stdout, result.stderr });
        return error.TestExecutionFailed;
    }
}

fn metadata(
    a: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args: []const []const u8,
) !model.Report {
    const now = std.Io.Clock.real.now(io).toMilliseconds();
    const suite = std.meta.stringToEnum(model.catalog.Suite, args[2]) orelse
        return error.InvalidSuite;
    const revision = try git(a, io, &.{ "git", "rev-parse", "HEAD" });
    const dirty = try git(a, io, &.{ "git", "status", "--porcelain" });
    var random: [8]u8 = undefined; // SAFETY: random fills the complete suffix.
    io.random(&random);
    const execution = try std.fmt.allocPrint(a, "{d}-{s}-{s}", .{
        now, args[3], std.fmt.bytesToHex(random, .lower),
    });
    return .{
        .schema = 1,
        .provenance = null,
        .suite = suite,
        .execution = execution,
        .lane = model.catalog.lane(suite),
        .driver = "native-subprocess",
        .os = @tagName(builtin.os.tag),
        .cpu = @tagName(builtin.cpu.arch),
        .environment = try std.fmt.allocPrint(a, "{s} {s} {s} r2-live={s}", .{
            env.get("RUNNER_ENVIRONMENT") orelse "local",
            env.get("ImageOS") orelse @tagName(builtin.os.tag),
            env.get("ImageVersion") orelse try osVersion(a, io),
            env.get("NIOBIUM_R2_LIVE_VERIFY") orelse "0",
        }),
        .revision = revision,
        .dirty = dirty.len != 0,
        .repository = env.get("GITHUB_REPOSITORY") orelse "local/niobium",
        .run = env.get("GITHUB_RUN_ID") orelse "local",
        .attempt = env.get("GITHUB_RUN_ATTEMPT") orelse "1",
        .job = env.get("GITHUB_JOB") orelse "local",
        .toolchain = builtin.zig_version_string,
        .target = args[4],
        .parameters = args[5..10],
        .started_ms = now,
        .finished_ms = now,
        .complete = false,
        .verdict = .NOT_RUN,
        .reason = "InProgress",
        .cases = &.{},
        .attachments = &.{},
    };
}

fn git(a: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]const u8 {
    const result = try process.run(a, io, .{ .argv = argv, .timeout_ms = 10_000 });
    if (result.code != 0 or result.reason.len != 0) return error.SourceIdentityUnavailable;
    return std.mem.trim(u8, result.stdout, "\r\n");
}

fn write(
    a: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    file: []const u8,
    bytes: []const u8,
) !void {
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(a, &.{ path, file }),
        .data = bytes,
    });
}

fn osVersion(a: std.mem.Allocator, io: std.Io) ![]const u8 {
    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/d", "/c", "ver" }
    else
        &.{ "/usr/bin/uname", "-srv" };
    const result = try process.run(a, io, .{ .argv = argv, .timeout_ms = 10_000 });
    if (result.code != 0) return error.EnvironmentIdentityUnavailable;
    return std.mem.trim(u8, result.stdout, "\r\n ");
}
