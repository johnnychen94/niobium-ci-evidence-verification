//! Test-only module: incremental case records and attachments, never part of product libraries.
const std = @import("std");
pub const model = @import("model.zig");
pub const process = @import("process.zig");

pub fn selected(id: []const u8) !bool {
    var env = try std.testing.environ.createMap(std.testing.allocator);
    defer env.deinit();
    const filter = env.get("NIOBIUM_TEST_CASE") orelse return true;
    return filter.len == 0 or std.mem.eql(u8, id, filter);
}

pub fn record(
    id: []const u8,
    contract: []const u8,
    verdict: model.Verdict,
    reason: []const u8,
    started_ms: i64,
) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try std.testing.environ.createMap(a);
    defer env.deinit();
    const dir = env.get("NIOBIUM_EVIDENCE_DIR") orelse return;
    const spec = model.catalog.find(id) orelse return error.UnknownCase;
    if (!model.segment(contract)) return error.InvalidContract;
    const case: model.Case = .{
        .id = id,
        .contract = contract,
        .acceptance = spec.acceptance,
        .scope = if (std.mem.eql(u8, id, "host-machine")) "redirected-machine" else "user",
        .verdict = verdict,
        .reason = reason,
        .started_ms = started_ms,
        .finished_ms = now(),
    };
    const file = try std.fmt.allocPrint(a, "{s}/{s}.{s}.case.json", .{ dir, id, contract });
    const bytes = try std.json.Stringify.valueAlloc(a, case, .{});
    try atomicWrite(a, std.testing.io, file, bytes);
}

pub fn attachment(file: []const u8, bytes: []const u8) !void {
    if (!model.segment(file)) return error.InvalidAttachment;
    if (bytes.len > model.limits.test_attachment_bytes) return error.AttachmentTooLarge;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try std.testing.environ.createMap(a);
    defer env.deinit();
    const dir = env.get("NIOBIUM_EVIDENCE_DIR") orelse return;
    const path = try std.fs.path.join(a, &.{ dir, file });
    try atomicWrite(a, std.testing.io, path, bytes);
}

pub fn atomicWrite(a: std.mem.Allocator, io: std.Io, file: []const u8, bytes: []const u8) !void {
    const temp = try std.fmt.allocPrint(a, "{s}.tmp", .{file});
    defer a.free(temp);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temp, .data = bytes });
    try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), file, io);
}

pub fn now() i64 {
    return std.Io.Clock.real.now(std.testing.io).toMilliseconds();
}

pub fn run(comptime id: []const u8, function: anytype) !void {
    if (!try selected(id)) return error.SkipZigTest;
    const started = now();
    try record(id, "lifecycle-v1", .NOT_RUN, "InProgress", started);
    function() catch |err| {
        try record(id, "lifecycle-v1", .FAIL, @errorName(err), started);
        return err;
    };
    try record(id, "lifecycle-v1", .PASS, "", started);
}
