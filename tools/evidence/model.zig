//! Bounded report data. No executable or transport configuration is accepted here.
const std = @import("std");
const contracts = @import("contracts");
pub const catalog = @import("test_catalog");
pub const limits = contracts.Limits{};
pub const Verdict = enum { PASS, FAIL, BLOCKED, NOT_RUN, DEFERRED };
pub const Retention = enum { ordinary, release };
pub const Provenance = struct {
    event: []const u8,
    workflow: []const u8,
    head_sha: []const u8,
    head_repository: []const u8,
    head_branch: []const u8,
    fork: bool,
    conclusion: []const u8,
    artifact_id: u64,
    job_id: u64,
    job_conclusion: []const u8,
    run_started_ms: i64,
};
pub const Attachment = struct {
    file: []const u8,
    key: []const u8,
    size: u64,
    sha256: []const u8,
    retention: Retention,
};
pub const Case = struct {
    id: []const u8,
    contract: []const u8,
    acceptance: []const []const u8,
    scope: []const u8,
    verdict: Verdict,
    reason: []const u8,
    started_ms: i64,
    finished_ms: i64,
};
pub const Report = struct {
    schema: u32,
    suite: catalog.Suite,
    execution: []const u8,
    lane: []const u8,
    driver: []const u8,
    os: []const u8,
    cpu: []const u8,
    environment: []const u8,
    revision: []const u8,
    dirty: bool,
    repository: []const u8,
    run: []const u8,
    attempt: []const u8,
    job: []const u8,
    toolchain: []const u8,
    target: []const u8,
    parameters: []const []const u8,
    provenance: ?Provenance,
    started_ms: i64,
    finished_ms: i64,
    complete: bool,
    verdict: Verdict,
    reason: []const u8,
    cases: []const Case,
    attachments: []const Attachment,
};

pub fn decode(a: std.mem.Allocator, bytes: []const u8) !Report {
    const report = try contracts.json.decode(Report, a, bytes, .{
        .max_bytes = limits.test_report_bytes,
        .max_schema = 1,
        .limits = .{ .json_string_bytes = limits.test_string_bytes },
    });
    try validate(report);
    return report;
}

pub fn segment(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    if (std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    for (value) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    }
    return true;
}

pub fn digest(bytes: []const u8) [64]u8 {
    var hash: [32]u8 = undefined; // SAFETY: hash writes all bytes.
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}

pub fn identity(a: std.mem.Allocator, report: Report) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}/{s}/{s}/{t}/{s}", .{
        report.repository, report.run, report.attempt, report.job, report.suite, report.execution,
    });
}

pub const max_timestamp_ms = 253402300799999;

pub fn archivePrefix(a: std.mem.Allocator, started_ms: i64) ![]const u8 {
    if (started_ms < 0 or started_ms > max_timestamp_ms) return error.InvalidReport;
    var buffer: [32]u8 = undefined; // SAFETY: formatUtc writes before reading.
    var writer: std.Io.Writer = .fixed(&buffer);
    try contracts.time.formatUtc(&writer, @divTrunc(started_ms, 1000));
    return std.fmt.allocPrint(a, "ci-evidence/{s}", .{writer.buffered()[0..7]});
}

pub fn reportPrefix(a: std.mem.Allocator, report: Report) ![]const u8 {
    const started = if (report.provenance) |p| p.run_started_ms else report.started_ms;
    return archivePrefix(a, started);
}

pub fn objectKey(a: std.mem.Allocator, report: Report, file: []const u8) ![]const u8 {
    return evidenceKey(a, report, file, .ordinary);
}

pub fn evidenceKey(
    a: std.mem.Allocator,
    report: Report,
    file: []const u8,
    retention: Retention,
) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{
        try reportPrefix(a, report), try legacyEvidenceKey(a, report, file, retention),
    });
}

pub fn legacyEvidenceKey(
    a: std.mem.Allocator,
    report: Report,
    file: []const u8,
    retention: Retention,
) ![]const u8 {
    const prefix = if (retention == .release) "release-evidence/v1" else "evidence/v1";
    return std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ prefix, try identity(a, report), file });
}

pub fn validate(r: Report) !void {
    if (r.schema != 1 or r.started_ms < 0 or r.finished_ms < r.started_ms or
        r.finished_ms > max_timestamp_ms)
        return error.InvalidReport;
    if (r.provenance) |p| {
        if (p.run_started_ms < 0 or p.run_started_ms > max_timestamp_ms)
            return error.InvalidReport;
    }
    for ([_][]const u8{ r.execution, r.run, r.attempt, r.job }) |part| {
        if (!segment(part)) return error.InvalidReport;
    }
    var repository = std.mem.splitScalar(u8, r.repository, '/');
    if (!segment(repository.next() orelse "")) return error.InvalidReport;
    if (!segment(repository.next() orelse "")) return error.InvalidReport;
    if (repository.next() != null) return error.InvalidReport;
    if (!std.mem.eql(u8, r.lane, catalog.lane(r.suite))) return error.InvalidReport;
    if (r.revision.len != 40) return error.InvalidReport;
    for (r.revision) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f'))
        return error.InvalidReport;
    if (r.verdict != .PASS and r.reason.len == 0) return error.InvalidReport;
    if (r.verdict == .PASS and !r.complete) return error.InvalidReport;
    if (r.cases.len > limits.test_cases) return error.InvalidReport;
    if (r.attachments.len > limits.test_attachments) return error.InvalidReport;
    if (r.parameters.len != 5) return error.InvalidReport;
    try validateReplay(r.parameters);
    if (r.parameters[0].len != 0) {
        const selected = catalog.find(r.parameters[0]) orelse return error.InvalidReport;
        if (selected.suite != r.suite) return error.InvalidReport;
    }
    try validateCases(r);
    try validateAttachments(r);
}

fn validateReplay(parameters: []const []const u8) !void {
    const seeds = std.mem.cutPrefix(u8, parameters[1], "seeds=") orelse
        return error.InvalidReport;
    const start = std.mem.cutPrefix(u8, parameters[2], "seed-start=") orelse
        return error.InvalidReport;
    for ([_][]const u8{ seeds, start }) |digits| {
        for (digits) |c| if (!std.ascii.isDigit(c)) return error.InvalidReport;
    }
    const count = std.fmt.parseInt(u32, seeds, 10) catch return error.InvalidReport;
    const first = std.fmt.parseInt(u64, start, 10) catch return error.InvalidReport;
    if (!catalog.validSeedRange(count, first)) return error.InvalidReport;
    if (!std.mem.eql(u8, parameters[3], "tsan=true") and
        !std.mem.eql(u8, parameters[3], "tsan=false")) return error.InvalidReport;
    if (!std.mem.eql(u8, parameters[4], "coverage=true") and
        !std.mem.eql(u8, parameters[4], "coverage=false")) return error.InvalidReport;
}

fn validateCases(r: Report) !void {
    for (r.cases, 0..) |case, index| {
        const spec = catalog.find(case.id) orelse return error.InvalidReport;
        if (spec.suite != r.suite) return error.InvalidReport;
        if (r.parameters[0].len > 0 and !std.mem.eql(u8, r.parameters[0], case.id))
            return error.InvalidReport;
        const scope = if (std.mem.eql(
            u8,
            case.id,
            "host-machine",
        )) "redirected-machine" else "user";
        if (!std.mem.eql(u8, scope, case.scope)) return error.InvalidReport;
        const known: []const []const u8 = if (r.suite == .conformance)
            &catalog.contracts
        else
            &.{"lifecycle-v1"};
        var found = false;
        for (known) |contract| if (std.mem.eql(u8, contract, case.contract)) {
            found = true;
        };
        if (!found) return error.InvalidReport;
        if (case.acceptance.len != spec.acceptance.len) return error.InvalidReport;
        for (case.acceptance, spec.acceptance) |actual, wanted| {
            if (!std.mem.eql(u8, actual, wanted)) return error.InvalidReport;
        }
        if (case.verdict != .PASS and case.reason.len == 0) return error.InvalidReport;
        if (case.started_ms < 0 or case.finished_ms < case.started_ms) return error.InvalidReport;
        if (r.verdict == .PASS and case.verdict == .FAIL) return error.InvalidReport;
        if (r.verdict == .PASS and case.verdict != .PASS) {
            if (r.suite != .conformance or case.verdict != .NOT_RUN or
                !catalog.optional(case.contract, r.os) or
                !std.mem.eql(u8, case.reason, "OptionalCapabilityUnsupported"))
                return error.InvalidReport;
        }
        for (r.cases[0..index]) |previous| {
            if (std.mem.eql(u8, previous.id, case.id) and
                std.mem.eql(u8, previous.contract, case.contract)) return error.InvalidReport;
        }
    }
    if (r.verdict != .PASS) return;
    for (catalog.cases) |case| {
        if (case.suite != r.suite) continue;
        if (r.parameters[0].len > 0 and !std.mem.eql(u8, r.parameters[0], case.id)) continue;
        var count: usize = 0;
        for (r.cases) |record| if (std.mem.eql(u8, case.id, record.id)) {
            count += 1;
        };
        const expected: usize = if (r.suite == .conformance) catalog.contracts.len else 1;
        if (count != expected) return error.MissingCaseEvidence;
    }
}

fn validateAttachments(r: Report) !void {
    var total: u64 = 0;
    for (r.attachments, 0..) |attachment, index| {
        if (attachment.size > limits.test_attachment_bytes) return error.InvalidReport;
        total += attachment.size;
        if (total > limits.test_bundle_bytes) return error.InvalidReport;
        if (!segment(attachment.file)) return error.InvalidReport;
        if (attachment.sha256.len != 64) return error.InvalidReport;
        for (attachment.sha256) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f'))
            return error.InvalidReport;
        for (r.attachments[0..index]) |previous| {
            if (std.mem.eql(u8, previous.file, attachment.file)) return error.InvalidReport;
        }
    }
}

test "N1-AC-20 archive paths and report parsing fail closed" {
    for ([_][]const u8{ "", "..", "../x", "a/b", "a\\b", "--bucket=x" }) |bad| {
        try std.testing.expect(!segment(bad));
    }
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.JsonDuplicateField,
        decode(arena.allocator(), "{\"schema\":1,\"schema\":1}"),
    );
    try std.testing.expectError(
        error.UnsupportedSchema,
        decode(arena.allocator(), "{\"schema\":2}"),
    );
}
