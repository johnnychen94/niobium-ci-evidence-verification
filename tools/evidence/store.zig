const std = @import("std");
const model = @import("model.zig");
const records = @import("records.zig");
const contracts = @import("contracts");

pub fn save(a: std.mem.Allocator, io: std.Io, dir: []const u8, report: model.Report) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, report, .{ .whitespace = .indent_2 });
    if (bytes.len > model.limits.test_report_bytes) return error.ReportTooLarge;
    try records.atomicWrite(a, io, try std.fs.path.join(a, &.{ dir, "report.json" }), bytes);
}

pub fn read(
    a: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    file: []const u8,
    limit: u32,
) ![]const u8 {
    if (!model.segment(file)) return error.InvalidAttachment;
    const stat = try dir.statFile(io, file, .{ .follow_symlinks = false });
    if (stat.kind != .file or stat.size > limit) return error.InvalidAttachment;
    return dir.readFileAlloc(io, file, a, .limited(limit));
}

pub fn load(a: std.mem.Allocator, io: std.Io, path: []const u8) !model.Report {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    const report = try model.decode(
        a,
        try read(a, io, dir, "report.json", model.limits.test_report_bytes),
    );
    for (report.attachments) |attachment| {
        const bytes = try read(a, io, dir, attachment.file, model.limits.test_attachment_bytes);
        defer a.free(bytes);
        if (bytes.len != attachment.size) return error.EvidenceSizeMismatch;
        if (!std.mem.eql(u8, &model.digest(bytes), attachment.sha256))
            return error.EvidenceDigestMismatch;
        const expected = try model.evidenceKey(a, report, attachment.file, attachment.retention);
        if (!std.mem.eql(u8, expected, attachment.key)) {
            const legacy = try model.legacyEvidenceKey(
                a,
                report,
                attachment.file,
                attachment.retention,
            );
            if (!std.mem.eql(u8, legacy, attachment.key)) return error.EvidenceKeyMismatch;
        }
    }
    for (report.cases) |case| {
        const file = try std.fmt.allocPrint(a, "{s}.{s}.case.json", .{ case.id, case.contract });
        var found = false;
        for (report.attachments) |attachment| {
            if (!std.mem.eql(u8, file, attachment.file)) continue;
            found = true;
            const bytes = try read(a, io, dir, file, model.limits.test_report_bytes);
            const fragment = try contracts.json.decode(model.Case, a, bytes, .{
                .max_bytes = model.limits.test_report_bytes,
            });
            const expected = try std.json.Stringify.valueAlloc(a, case, .{});
            const actual = try std.json.Stringify.valueAlloc(a, fragment, .{});
            if (!std.mem.eql(u8, expected, actual)) return error.CaseEvidenceMismatch;
        }
        if (!found) return error.MissingCaseEvidence;
    }
    if (report.complete) {
        for ([_][]const u8{ "stdout.txt", "stderr.txt" }) |name| {
            var found = false;
            for (report.attachments) |attachment| {
                if (std.mem.eql(u8, name, attachment.file)) found = true;
            }
            if (!found) return error.MissingEvidence;
        }
    }
    return report;
}

/// Rebase validated saved evidence onto the source month before publishing it.
pub fn rekey(a: std.mem.Allocator, report: *model.Report) !void {
    const attachments = try a.dupe(model.Attachment, report.attachments);
    for (attachments) |*attachment| attachment.key = try model.evidenceKey(
        a,
        report.*,
        attachment.file,
        attachment.retention,
    );
    report.attachments = attachments;
}

pub fn collect(a: std.mem.Allocator, io: std.Io, path: []const u8, r: *model.Report) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, "report.json")) continue;
        if (std.mem.endsWith(u8, entry.name, ".tmp") and !r.complete) continue;
        if (names.items.len >= model.limits.test_attachments) return error.TooManyAttachments;
        if (entry.kind != .file) return error.InvalidAttachment;
        try names.append(a, try a.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    var cases: std.ArrayList(model.Case) = .empty;
    var attachments: std.ArrayList(model.Attachment) = .empty;
    for (names.items) |name| {
        const bytes = try read(a, io, dir, name, model.limits.test_attachment_bytes);
        defer a.free(bytes);
        if (std.mem.endsWith(u8, name, ".case.json")) {
            const case = try contracts.json.decode(model.Case, a, bytes, .{
                .max_bytes = model.limits.test_report_bytes,
            });
            if (cases.items.len >= model.limits.test_cases) return error.TooManyCases;
            try cases.append(a, case);
        }
        try attachments.append(a, .{
            .file = name,
            .key = try model.objectKey(a, r.*, name),
            .size = bytes.len,
            .sha256 = try a.dupe(u8, &model.digest(bytes)),
            .retention = .ordinary,
        });
    }
    r.cases = cases.items;
    r.attachments = attachments.items;
}

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
