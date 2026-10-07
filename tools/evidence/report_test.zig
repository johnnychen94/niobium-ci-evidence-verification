const std = @import("std");
const model = @import("model.zig");
const store = @import("store.zig");
const records = @import("records.zig");
const contracts = @import("contracts");

pub fn fixtureReport() model.Report {
    return .{
        .schema = 1,
        .provenance = null,
        .suite = .unit,
        .execution = "fixture",
        .lane = "L1/L2",
        .driver = "fixture",
        .os = "linux",
        .cpu = "x86_64",
        .environment = "isolated",
        .revision = "0000000000000000000000000000000000000000",
        .dirty = true,
        .repository = "example/project",
        .run = "1",
        .attempt = "1",
        .job = "linux",
        .toolchain = "test",
        .target = "x86_64-linux",
        .parameters = &.{ "", "seeds=1", "seed-start=0", "tsan=false", "coverage=false" },
        .started_ms = 1,
        .finished_ms = 2,
        .complete = true,
        .verdict = .PASS,
        .reason = "",
        .cases = &.{},
        .attachments = &.{},
    };
}

test "N1-AC-20 archive keys retain the source UTC month across publication retries" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var value = fixtureReport();
    value.started_ms = (try contracts.time.parseUtc("2026-10-31T23:59:59Z")) * 1000;
    try std.testing.expectEqualStrings(
        "ci-evidence/2026-10/evidence/v1/example/project/1/1/linux/unit/fixture/stdout.txt",
        try model.objectKey(arena.allocator(), value, "stdout.txt"),
    );
    value.started_ms += 1000;
    try std.testing.expectEqualStrings(
        "ci-evidence/2026-11/evidence/v1/example/project/1/1/linux/unit/fixture/stdout.txt",
        try model.objectKey(arena.allocator(), value, "stdout.txt"),
    );
    value.provenance = .{
        .event = "pull_request",
        .workflow = ".github/workflows/ci.yml",
        .head_sha = value.revision,
        .head_repository = "fork/project",
        .head_branch = "test",
        .fork = true,
        .conclusion = "success",
        .artifact_id = 1,
        .job_id = 2,
        .job_conclusion = "success",
        .run_started_ms = value.started_ms - 1000,
    };
    try std.testing.expectEqualStrings(
        "ci-evidence/2026-10/evidence/v1/example/project/1/1/linux/unit/fixture/stdout.txt",
        try model.objectKey(arena.allocator(), value, "stdout.txt"),
    );
    try std.testing.expectError(
        error.InvalidReport,
        model.archivePrefix(arena.allocator(), model.max_timestamp_ms + 1),
    );
}

test "N1-AC-20 legacy saved keys migrate without accepting unrelated object paths" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    for ([_][]const u8{ "stdout.txt", "stderr.txt" }) |file|
        try tmp.dir.writeFile(io, .{ .sub_path = file, .data = "saved" });
    var value = fixtureReport();
    try store.collect(a, io, path, &value);
    const attachments = try a.dupe(model.Attachment, value.attachments);
    for (attachments) |*attachment| attachment.key = try model.legacyEvidenceKey(
        a,
        value,
        attachment.file,
        attachment.retention,
    );
    value.attachments = attachments;
    try store.save(a, io, path, value);
    var saved = try store.load(a, io, path);
    try store.rekey(a, &saved);
    try store.save(a, io, path, saved);
    const migrated = try store.load(a, io, path);
    try std.testing.expect(std.mem.startsWith(u8, migrated.attachments[0].key, "ci-evidence/"));
    attachments[0].key = "ci-evidence/2026-10/evidence/v1/unrelated/object";
    value.attachments = attachments;
    try store.save(a, io, path, value);
    try std.testing.expectError(error.EvidenceKeyMismatch, store.load(a, io, path));
}

test "N1-AC-20 malformed, missing, changed and partial evidence is never a pass" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    var value = fixtureReport();
    try store.save(a, io, path, value);
    try std.testing.expectError(error.MissingEvidence, store.load(a, io, path));
    for ([_][]const u8{ "stdout.txt", "stderr.txt" }) |file| {
        try tmp.dir.writeFile(io, .{ .sub_path = file, .data = "output" });
    }
    try store.collect(a, io, path, &value);
    try store.save(a, io, path, value);
    const saved = try store.load(a, io, path);
    try std.testing.expectEqual(model.Verdict.PASS, saved.verdict);
    try tmp.dir.writeFile(io, .{ .sub_path = "stdout.txt", .data = "edited" });
    try std.testing.expectError(error.EvidenceDigestMismatch, store.load(a, io, path));
    value.complete = false;
    try std.testing.expectError(error.InvalidReport, model.validate(value));
    value.verdict = .FAIL;
    value.reason = "Timeout";
    try model.validate(value);
    value.suite = .e2e;
    value.lane = "L4";
    value.complete = true;
    value.verdict = .PASS;
    value.reason = "";
    try std.testing.expectError(error.MissingCaseEvidence, model.validate(value));
    try std.testing.expectError(
        error.FileNotFound,
        records.atomicWrite(a, io, try std.fs.path.join(a, &.{ path, "missing", "report" }), "x"),
    );
}

test "N1-AC-20 optional unsupported contracts cannot hide required failures" {
    var value = fixtureReport();
    value.suite = .conformance;
    value.lane = "L3";
    value.parameters = &.{ "host-user", "seeds=1", "seed-start=0", "tsan=false", "coverage=false" };
    // SAFETY: loop fills all entries.
    var cases: [model.catalog.contracts.len]model.Case = undefined;
    for (model.catalog.contracts, &cases) |contract, *case| case.* = .{
        .id = "host-user",
        .contract = contract,
        .acceptance = &.{"N1-AC-14"},
        .scope = "user",
        .verdict = .PASS,
        .reason = "",
        .started_ms = 1,
        .finished_ms = 2,
    };
    value.cases = &cases;
    cases[6].verdict = .NOT_RUN;
    cases[6].reason = "OptionalCapabilityUnsupported";
    try model.validate(value);
    cases[0].verdict = .NOT_RUN;
    cases[0].reason = "OptionalCapabilityUnsupported";
    try std.testing.expectError(error.InvalidReport, model.validate(value));
}

test "N1-AC-20 report replay parameters and timestamps are checked" {
    var value = fixtureReport();
    value.started_ms = -1;
    try std.testing.expectError(error.InvalidReport, model.validate(value));
    value.started_ms = 1;
    value.parameters = &.{ "", "seeds=0", "seed-start=0", "tsan=false", "coverage=false" };
    try std.testing.expectError(error.InvalidReport, model.validate(value));
    value.parameters = &.{ "", "seeds=1", "seed-start=0", "tsan=maybe", "coverage=false" };
    try std.testing.expectError(error.InvalidReport, model.validate(value));
}

test "N1-AC-20 a single maximum seed is valid but an overflowing range is rejected" {
    var value = fixtureReport();
    value.parameters = &.{
        "", "seeds=1", "seed-start=18446744073709551615", "tsan=false", "coverage=false",
    };
    try model.validate(value);
    value.parameters = &.{
        "", "seeds=2", "seed-start=18446744073709551615", "tsan=false", "coverage=false",
    };
    try std.testing.expectError(error.InvalidReport, model.validate(value));
}

test "N1-AC-20 publisher provenance requires its source timestamp" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var value = fixtureReport();
    value.provenance = .{
        .event = "pull_request",
        .workflow = ".github/workflows/ci.yml",
        .head_sha = value.revision,
        .head_repository = "fork/project",
        .head_branch = "test",
        .fork = true,
        .conclusion = "success",
        .artifact_id = 1,
        .job_id = 2,
        .job_conclusion = "success",
        .run_started_ms = 1000,
    };
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    const missing = try std.mem.replaceOwned(u8, a, bytes, ",\"run_started_ms\":1000", "");
    try std.testing.expectError(error.JsonMissingField, model.decode(a, missing));
}

test "N1-AC-20 excluded records do not consume the attachment limit" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    for (0..model.limits.test_attachments) |index| {
        const file = try std.fmt.allocPrint(a, "att-{d:0>4}", .{index});
        try tmp.dir.writeFile(io, .{ .sub_path = file, .data = "" });
    }
    var value = fixtureReport();
    value.complete = false;
    value.verdict = .NOT_RUN;
    value.reason = "InProgress";
    try store.save(a, io, path, value);
    try tmp.dir.writeFile(io, .{ .sub_path = "excluded.tmp", .data = "" });
    try store.collect(a, io, path, &value);
    try std.testing.expectEqual(model.limits.test_attachments, value.attachments.len);
}
