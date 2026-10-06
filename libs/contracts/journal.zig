//! Transaction journal records (docs/architecture/transaction-model.md). One JSON object per line;
//! a truncated final line counts as not written.

const std = @import("std");
const json = @import("json.zig");
const limits = @import("limits.zig");

pub const TxKind = enum { install, update, repair, uninstall };

pub const Record = union(enum) {
    begin: Begin,
    op_done: u32,
    op_undone: u32,
    ready_to_commit,
    commit,
    bootstrap_started,
    bootstrap_done: bool,
    finalized,
    rolled_back,

    pub const Begin = struct {
        tx: []const u8,
        seq: u64,
        kind: TxKind,
        /// Active release sequence before the transaction; null for a first install.
        from: ?u64 = null,
    };
};

const Tag = std.meta.Tag(Record);

const Line = struct {
    r: Tag,
    tx: ?[]const u8 = null,
    seq: ?u64 = null,
    kind: ?TxKind = null,
    from: ?u64 = null,
    i: ?u32 = null,
    ok: ?bool = null,
};

pub const ParseError = json.DecodeError || error{JournalBadRecord};

pub fn parse(arena: std.mem.Allocator, line: []const u8) ParseError!Record {
    const parsed = try json.decode(
        Line,
        arena,
        line,
        .{ .max_bytes = limits.default.journal_record_bytes },
    );
    return switch (parsed.r) {
        .begin => .{ .begin = .{
            .tx = parsed.tx orelse return error.JournalBadRecord,
            .seq = parsed.seq orelse return error.JournalBadRecord,
            .kind = parsed.kind orelse return error.JournalBadRecord,
            .from = parsed.from,
        } },
        .op_done => .{ .op_done = parsed.i orelse return error.JournalBadRecord },
        .op_undone => .{ .op_undone = parsed.i orelse return error.JournalBadRecord },
        .bootstrap_done => .{ .bootstrap_done = parsed.ok orelse return error.JournalBadRecord },
        inline .ready_to_commit, .commit, .bootstrap_started, .finalized, .rolled_back => |tag| tag,
    };
}

/// One line including the trailing newline.
pub fn write(writer: *std.Io.Writer, record: Record) std.Io.Writer.Error!void {
    try writer.print("{{\"r\":\"{s}\"", .{@tagName(record)});
    switch (record) {
        .begin => |begin| {
            try writer.writeAll(",\"tx\":");
            try std.json.Stringify.encodeJsonString(begin.tx, .{}, writer);
            try writer.print(",\"seq\":{d},\"kind\":\"{s}\"", .{ begin.seq, @tagName(begin.kind) });
            if (begin.from) |from| try writer.print(",\"from\":{d}", .{from});
        },
        .op_done, .op_undone => |index| try writer.print(",\"i\":{d}", .{index}),
        .bootstrap_done => |ok| try writer.print(",\"ok\":{}", .{ok}),
        .ready_to_commit, .commit, .bootstrap_started, .finalized, .rolled_back => {},
    }
    try writer.writeAll("}\n");
}

/// Parse a whole journal. Stops at the first line without a newline terminator (torn write).
pub fn parseAll(
    arena: std.mem.Allocator,
    bytes: []const u8,
    max_records: u32,
) ParseError![]const Record {
    var records: std.ArrayList(Record) = .empty;
    var rest = bytes;
    while (std.mem.findScalar(u8, rest, '\n')) |end| {
        if (records.items.len >= max_records) return error.JournalBadRecord;
        try records.append(arena, try parse(arena, rest[0..end]));
        rest = rest[end + 1 ..];
    }
    return records.items;
}

test "N1-AC-06 journal records round trip and torn tail is ignored" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    const records = [_]Record{
        .{ .begin = .{ .tx = "tx-3-ab", .seq = 3, .kind = .update, .from = 2 } },
        .{ .op_done = 0 },
        .ready_to_commit,
        .commit,
        .{ .bootstrap_done = true },
        .finalized,
    };
    for (records) |record| try write(&out.writer, record);
    try out.writer.writeAll("{\"r\":\"op_d");
    const parsed = try parseAll(arena.allocator(), out.written(), 100);
    try std.testing.expectEqual(records.len, parsed.len);
    try std.testing.expectEqualStrings("tx-3-ab", parsed[0].begin.tx);
    try std.testing.expectEqual(@as(?u64, 2), parsed[0].begin.from);
    try std.testing.expectEqual(true, parsed[4].bootstrap_done);
}
