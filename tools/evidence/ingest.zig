//! GitHub artifacts are data, including on fork PRs. Extract only bounded regular files.
const std = @import("std");
const model = @import("model.zig");
const store = @import("store.zig");
const archive = @import("archive.zig");
const contracts = @import("contracts");
const Value = std.json.Value;

const Budget = struct {
    compressed: u64 = 0,
    unpacked: u64 = 0,
    files: u32 = 0,

    fn zip(b: *Budget, size: u64) !void {
        if (size > model.limits.test_workflow_zip_bytes - b.compressed)
            return error.WorkflowArchiveTooLarge;
        b.compressed += size;
    }

    fn entry(b: *Budget, size: u64) !void {
        if (size > model.limits.test_workflow_unpacked_bytes - b.unpacked)
            return error.WorkflowArchiveTooLarge;
        if (b.files >= model.limits.test_workflow_files) return error.WorkflowTooManyFiles;
        b.unpacked += size;
        b.files += 1;
    }
};

pub fn publish(c: archive.Client, input: []const u8) !void {
    const run = try json(c, input, "run.json");
    const expected_run = c.env.get("ARCHIVE_RUN_ID") orelse return error.MissingRunIdentity;
    const expected_attempt = c.env.get("ARCHIVE_RUN_ATTEMPT") orelse
        return error.MissingRunIdentity;
    const expected_repo = c.env.get("GITHUB_REPOSITORY") orelse return error.MissingRunIdentity;
    if (try number(run, "id") != try std.fmt.parseInt(u64, expected_run, 10))
        return error.RunIdentityMismatch;
    if (try number(run, "run_attempt") != try std.fmt.parseInt(u64, expected_attempt, 10))
        return error.RunIdentityMismatch;
    const repository = try string(try field(run, "repository"), "full_name");
    if (!std.mem.eql(u8, repository, expected_repo)) return error.RunIdentityMismatch;
    const pages = try json(c, input, "artifacts.json");
    if (pages != .array or pages.array.items.len > model.limits.test_github_pages)
        return error.InvalidArtifacts;
    // The GitHub run and jobs remain an authoritative record even when tests never started.
    const started_ms = (try contracts.time.parseUtc(try string(run, "run_started_at"))) * 1000;
    const key = try std.fmt.allocPrint(c.a, "{s}/reports/v1/{s}/{s}/{s}/github", .{
        try model.archivePrefix(c.a, started_ms), repository, expected_run, expected_attempt,
    });
    try recordSnapshots(c, input, key);
    try publishJobEvidence(c, input, key, pages, expected_attempt);
    var count: usize = 0;
    var budget: Budget = .{};
    for (pages.array.items) |page| {
        const artifacts = try field(page, "artifacts");
        if (artifacts != .array) return error.InvalidArtifacts;
        for (artifacts.array.items) |artifact| {
            if (count >= model.limits.test_github_items) return error.TooManyArtifacts;
            count += 1;
            const name = try string(artifact, "name");
            const prefix = try std.fmt.allocPrint(c.a, "evidence-{s}-", .{expected_attempt});
            const job = std.mem.cutPrefix(u8, name, prefix) orelse continue;
            if (!model.segment(job)) return error.InvalidJob;
            const github_job = try findJob(c, input, job);
            const id = try number(artifact, "id");
            try publishArtifact(c, input, .{
                .run = run,
                .repository = repository,
                .run_id = expected_run,
                .attempt = expected_attempt,
                .job = job,
                .artifact_id = id,
                .github_job = github_job,
                .run_started_ms = started_ms,
            }, &budget);
        }
    }
}

fn publishArtifact(c: archive.Client, input: []const u8, source: Source, budget: *Budget) !void {
    const target = try std.fmt.allocPrint(c.a, "{s}/{d}", .{ c.scratch, source.artifact_id });
    const zip = try std.fmt.allocPrint(c.a, "{s}/{d}.zip", .{ input, source.artifact_id });
    errdefer std.Io.Dir.cwd().deleteTree(c.io, target) catch |err|
        std.debug.print("extraction cleanup: {t}\n", .{err});
    try extractBounded(c.gpa, c.io, zip, target, budget);
    try publishTree(c, target, source);
    try std.Io.Dir.cwd().deleteTree(c.io, target);
}

fn recordSnapshots(c: archive.Client, input: []const u8, key: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(c.io, input, .{});
    defer dir.close(c.io);
    for ([_][]const u8{ "run.json", "jobs.json", "artifacts.json" }) |file| {
        try snapshot(c, key, file, try store.read(
            c.a,
            c.io,
            dir,
            file,
            model.limits.test_report_bytes,
        ));
    }
    // Publisher versions are separate immutable snapshots so redeploying cannot conflict with
    // identical source evidence during recovery of a partially published run.
    try snapshot(c, key, "publisher.json", try std.json.Stringify.valueAlloc(c.a, .{
        .schema = @as(u32, 1),
        .revision = c.env.get("GITHUB_SHA") orelse return error.MissingPublisherRevision,
    }, .{}));
}

fn publishJobEvidence(
    c: archive.Client,
    input: []const u8,
    key: []const u8,
    artifacts: Value,
    attempt: []const u8,
) !void {
    const pages = try json(c, input, "jobs.json");
    if (pages != .array or pages.array.items.len > model.limits.test_github_pages)
        return error.InvalidJobs;
    const Job = struct { id: u64, name: []const u8, conclusion: []const u8, evidence: []const u8 };
    var results: std.ArrayList(Job) = .empty;
    for (pages.array.items) |page| {
        const jobs = try field(page, "jobs");
        if (jobs != .array) return error.InvalidJobs;
        for (jobs.array.items) |job| {
            if (results.items.len >= model.limits.test_github_items) return error.TooManyJobs;
            const name = try string(job, "name");
            const wanted = try std.fmt.allocPrint(c.a, "evidence-{s}-{s}", .{ attempt, name });
            var found = false;
            for (artifacts.array.items) |artifact_page| {
                const list = try field(artifact_page, "artifacts");
                if (list != .array or list.array.items.len > model.limits.test_github_items)
                    return error.InvalidArtifacts;
                for (list.array.items) |artifact| {
                    if (std.mem.eql(u8, wanted, try string(artifact, "name"))) found = true;
                }
            }
            try results.append(c.a, .{
                .id = try number(job, "id"),
                .name = name,
                .conclusion = try string(job, "conclusion"),
                .evidence = if (found) "artifact-present-unvalidated" else "no-saved-evidence",
            });
        }
    }
    const bytes = try std.json.Stringify.valueAlloc(c.a, .{
        .schema = @as(u32, 1),
        .kind = "github-job-evidence",
        .jobs = results.items,
    }, .{});
    try snapshot(c, key, "evidence-status.json", bytes);
}

// GitHub snapshots can change after another attempt or artifact expiry. Preserve each version.
fn snapshot(c: archive.Client, key: []const u8, file: []const u8, bytes: []const u8) !void {
    const path = try std.fmt.allocPrint(c.a, "{s}/{s}/{s}", .{ key, model.digest(bytes), file });
    try c.put(path, bytes);
}

const Source = struct {
    run: Value,
    repository: []const u8,
    run_id: []const u8,
    attempt: []const u8,
    job: []const u8,
    artifact_id: u64,
    github_job: Value,
    run_started_ms: i64,
};

fn findJob(c: archive.Client, input: []const u8, name: []const u8) !Value {
    const pages = try json(c, input, "jobs.json");
    if (pages != .array or pages.array.items.len > model.limits.test_github_pages)
        return error.InvalidJobs;
    for (pages.array.items) |page| {
        const jobs = try field(page, "jobs");
        if (jobs != .array or jobs.array.items.len > model.limits.test_github_items)
            return error.InvalidJobs;
        for (jobs.array.items) |job| {
            if (std.mem.eql(u8, name, try string(job, "name"))) return job;
        }
    }
    return error.UnknownGithubJob;
}

fn publishTree(c: archive.Client, root: []const u8, source: Source) !void {
    var dir = try std.Io.Dir.cwd().openDir(c.io, root, .{ .iterate = true });
    defer dir.close(c.io);
    var walker = try dir.walk(c.a);
    defer walker.deinit();
    var count: usize = 0;
    while (try walker.next(c.io)) |entry| {
        if (count >= model.limits.test_bundle_files) return error.TooManyFiles;
        count += 1;
        if (entry.kind != .file or !std.mem.eql(u8, entry.basename, "report.json")) continue;
        const relative = std.fs.path.dirname(entry.path) orelse return error.InvalidLayout;
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        var scoped = c;
        scoped.a = arena.allocator();
        const path = try std.fs.path.join(scoped.a, &.{ root, relative });
        var report = try store.load(scoped.a, c.io, path);
        if (!report.complete) try store.collect(scoped.a, c.io, path, &report);
        try model.validate(report);
        // Test workflows never authorize permanent release bundles, even for same-repo PRs.
        for (report.attachments) |attachment| {
            if (attachment.retention != .ordinary) return error.InvalidRetention;
        }
        if (!std.mem.eql(u8, report.repository, source.repository) or
            !std.mem.eql(u8, report.run, source.run_id) or
            !std.mem.eql(u8, report.attempt, source.attempt) or
            !std.mem.eql(u8, report.job, source.job)) return error.RunIdentityMismatch;
        const head_repo = try string(try field(source.run, "head_repository"), "full_name");
        report.provenance = .{
            .event = try string(source.run, "event"),
            .workflow = try string(source.run, "path"),
            .head_sha = try string(source.run, "head_sha"),
            .head_repository = head_repo,
            .head_branch = try string(source.run, "head_branch"),
            .fork = !std.mem.eql(u8, head_repo, source.repository),
            .conclusion = try string(source.run, "conclusion"),
            .artifact_id = source.artifact_id,
            .job_id = try number(source.github_job, "id"),
            .job_conclusion = try string(source.github_job, "conclusion"),
            .run_started_ms = source.run_started_ms,
        };
        try store.rekey(scoped.a, &report);
        try store.save(scoped.a, c.io, path, report);
        try archive.publish(scoped, path);
    }
}

fn json(c: archive.Client, path: []const u8, file: []const u8) !Value {
    var dir = try std.Io.Dir.cwd().openDir(c.io, path, .{});
    defer dir.close(c.io);
    return contracts.json.decodeValue(
        c.a,
        try store.read(c.a, c.io, dir, file, model.limits.test_report_bytes),
        .{ .max_bytes = model.limits.test_report_bytes },
    );
}

fn field(value: Value, name: []const u8) !Value {
    if (value != .object) return error.InvalidGithubData;
    return value.object.get(name) orelse error.MissingGithubField;
}

fn string(value: Value, name: []const u8) ![]const u8 {
    const result = try field(value, name);
    if (result != .string) return error.InvalidGithubData;
    return result.string;
}

fn number(value: Value, name: []const u8) !u64 {
    const result = try field(value, name);
    if (result != .integer) return error.InvalidGithubData;
    return std.math.cast(u64, result.integer) orelse error.InvalidGithubData;
}

pub fn extract(a: std.mem.Allocator, io: std.Io, source: []const u8, target: []const u8) !void {
    var budget: Budget = .{};
    return extractBounded(a, io, source, target, &budget);
}

fn extractBounded(
    a: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    target: []const u8,
    budget: *Budget,
) !void {
    const file = try std.Io.Dir.cwd().openFile(io, source, .{});
    defer file.close(io);
    const zip_size = (try file.stat(io)).size;
    if (zip_size > model.limits.test_zip_bytes) return error.ArtifactTooLarge;
    try budget.zip(zip_size);
    var buffer: [4096]u8 = undefined; // SAFETY: reader initializes its buffer.
    var reader = file.reader(io, &buffer);
    var iterator = try std.zip.Iterator.init(&reader);
    if (iterator.cd_record_count > model.limits.test_bundle_files) return error.TooManyFiles;
    var total: u64 = 0;
    try std.Io.Dir.cwd().createDirPath(io, target);
    var dir = try std.Io.Dir.cwd().openDir(io, target, .{});
    defer dir.close(io);
    while (try iterator.next()) |entry| {
        if (entry.uncompressed_size > model.limits.test_attachment_bytes)
            return error.AttachmentTooLarge;
        try budget.entry(entry.uncompressed_size);
        total += entry.uncompressed_size;
        if (total > model.limits.test_bundle_bytes) return error.ArtifactTooLarge;
        var name_buffer: [1024]u8 = undefined; // SAFETY: getFilename fills before returning.
        try reader.seekTo(entry.header_zip_offset);
        const header = try reader.interface.takeStruct(std.zip.CentralDirectoryFileHeader, .little);
        const kind = (header.external_file_attributes >> 16) & 0o170000;
        if (kind != 0 and kind != 0o100000 and kind != 0o040000) return error.InvalidArtifactKind;
        const name = try entry.getFilename(&reader, &name_buffer, .{});
        try safePath(name);
        if (std.mem.endsWith(u8, name, "/")) {
            try dir.createDirPath(io, name);
            continue;
        }
        const size = std.math.cast(usize, entry.uncompressed_size) orelse
            return error.AttachmentTooLarge;
        const bytes = try a.alloc(u8, size);
        defer a.free(bytes);
        var writer: std.Io.Writer = .fixed(bytes);
        try entry.extractTo(&reader, &writer);
        if (writer.end != bytes.len) return error.InvalidArtifactSize;
        if (std.hash.Crc32.hash(bytes) != entry.crc32) return error.InvalidArtifactChecksum;
        if (std.fs.path.dirname(name)) |parent| try dir.createDirPath(io, parent);
        const output = try dir.createFile(io, name, .{ .exclusive = true });
        defer output.close(io);
        try output.writeStreamingAll(io, bytes);
    }
}

test "N1-AC-20 artifact budgets apply across the complete workflow" {
    var budget: Budget = .{};
    try budget.zip(model.limits.test_workflow_zip_bytes - 1);
    try std.testing.expectError(error.WorkflowArchiveTooLarge, budget.zip(2));
    try budget.entry(model.limits.test_workflow_unpacked_bytes - 1);
    try std.testing.expectError(error.WorkflowArchiveTooLarge, budget.entry(2));
    budget.files = model.limits.test_workflow_files;
    try std.testing.expectError(error.WorkflowTooManyFiles, budget.entry(0));
}

fn safePath(path: []const u8) !void {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    var parts = std.mem.splitScalar(u8, trimmed, '/');
    var depth: usize = 0;
    while (parts.next()) |part| {
        depth += 1;
        if (depth > model.limits.test_bundle_depth or !model.segment(part))
            return error.InvalidArtifactPath;
    }
}

test "N1-AC-20 fork artifact paths cannot escape extraction" {
    for ([_][]const u8{ "../x", "/tmp/x", "a/../../x", "C:/x", "a\\x", "a//x" }) |path| {
        try std.testing.expectError(error.InvalidArtifactPath, safePath(path));
    }
    try safePath("e2e/run/report.json");
}

test "N1-AC-20 untrusted ZIP extraction accepts data and rejects links and traversal" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const source = try std.fs.path.join(a, &.{ root, "input.zip" });
    defer a.free(source);
    const target = try std.fs.path.join(a, &.{ root, "output" });
    defer a.free(target);
    // A stored regular file containing only "payload"; no downloaded code runs in this test.
    const hex =
        "504b03041400000000000000215c156a2c42070000000700000004000000646174617061796c6f61" ++
        "64504b010214031400000000000000215c156a2c4207000000070000000400000000000000000000" ++
        "00a4810000000064617461504b0506000000000100010032000000290000000000";
    var bytes: [113]u8 = undefined; // SAFETY: hexToBytes fills the fixture.
    const decoded = try std.fmt.hexToBytes(&bytes, hex);
    try std.testing.expectEqual(bytes.len, decoded.len);
    try tmp.dir.writeFile(io, .{ .sub_path = "input.zip", .data = &bytes });
    try extract(a, io, source, target);
    const payload = try tmp.dir.readFileAlloc(io, "output/data", a, .limited(16));
    defer a.free(payload);
    try std.testing.expectEqualStrings("payload", payload);
    // Central-directory Unix mode's file-type byte: regular -> symlink.
    bytes[82] = 0xa1;
    try tmp.dir.writeFile(io, .{ .sub_path = "input.zip", .data = &bytes });
    try std.testing.expectError(error.InvalidArtifactKind, extract(a, io, source, target));
    bytes[82] = 0x81;
    @memcpy(bytes[30..34], "../x");
    @memcpy(bytes[87..91], "../x");
    try tmp.dir.writeFile(io, .{ .sub_path = "input.zip", .data = &bytes });
    try std.testing.expectError(error.ZipBadFilename, extract(a, io, source, target));
}
