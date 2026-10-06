//! Size gate: each shipping `setup` is at most --limit bytes and grows at most 5% over
//! tools/size-gate/baseline.zon. `--write` (zig build size-gate -- --write) rewrites the baseline.

const std = @import("std");
const repo = @import("repo");

pub const growth_percent = 5;

pub const Entry = struct {
    name: []const u8,
    bytes: u64,
};

const Baseline = struct {
    targets: []const Entry = &.{},
};

pub fn command(arena: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var baseline_path: ?[]const u8 = null;
    var limit: ?u64 = null;
    var write = false;
    var pairs: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--write")) {
            write = true;
        } else if (std.mem.eql(u8, arg, "--baseline") and index + 1 < args.len) {
            index += 1;
            baseline_path = args[index];
        } else if (std.mem.eql(u8, arg, "--limit") and index + 1 < args.len) {
            index += 1;
            limit = try std.fmt.parseInt(u64, args[index], 10);
        } else {
            try pairs.append(arena, arg);
        }
    }
    if (pairs.items.len % 2 != 0) return error.UsageSize;
    const path = baseline_path orelse return error.UsageSize;
    var measured: std.ArrayList(Entry) = .empty;
    var cursor: usize = 0;
    while (cursor < pairs.items.len) : (cursor += 2) {
        const stat = try std.Io.Dir.cwd().statFile(io, pairs.items[cursor + 1], .{});
        try measured.append(arena, .{ .name = pairs.items[cursor], .bytes = stat.size });
        std.debug.print("size-gate: {s} setup = {d} bytes\n", .{ pairs.items[cursor], stat.size });
    }
    if (write) return writeBaseline(arena, io, path, measured.items);
    const baseline = try load(arena, io, path);
    var report: repo.Report = .{ .arena = arena, .tool = "size-gate" };
    try evaluate(&report, limit orelse return error.UsageSize, baseline.targets, measured.items);
    try report.finish(io);
}

pub fn evaluate(
    report: *repo.Report,
    limit: u64,
    baseline: []const Entry,
    measured: []const Entry,
) !void {
    for (measured) |entry| {
        if (entry.bytes > limit) {
            try report.add("{s}: {d} bytes > limit {d}", .{ entry.name, entry.bytes, limit });
        }
        const base = find(baseline, entry.name) orelse {
            try report.add("{s}: no size baseline (zig build size-gate -- --write)", .{entry.name});
            continue;
        };
        const allowed = base.bytes + base.bytes * growth_percent / 100;
        if (entry.bytes > allowed) {
            try report.add("{s}: {d} bytes grew over {d}% from baseline {d}", .{
                entry.name, entry.bytes, growth_percent, base.bytes,
            });
        }
    }
}

fn find(entries: []const Entry, name: []const u8) ?Entry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

fn load(arena: std.mem.Allocator, io: std.Io, path: []const u8) !Baseline {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 10)) catch |err| {
        if (err == error.FileNotFound) return .{};
        return err;
    };
    var diagnostics: std.zon.parse.Diagnostics = undefined; // SAFETY: filled by fromSlice.
    return std.zon.parse.fromSlice(Baseline, .{
        .gpa = arena,
        .arena = arena,
        .source = try arena.dupeSentinel(u8, data, 0),
        .diagnostics = &diagnostics,
    });
}

fn writeBaseline(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    entries: []const Entry,
) !void {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("// ReleaseSafe setup sizes. Growth over 5% fails `zig build size-gate`.\n");
    try w.writeAll(
        "// Rewrite with `zig build size-gate -- --write` in the commit that explains it.\n",
    );
    try w.writeAll(".{\n    .targets = .{\n");
    for (entries) |entry| {
        try w.print(
            "        .{{ .name = \"{s}\", .bytes = {d} }},\n",
            .{ entry.name, entry.bytes },
        );
    }
    try w.writeAll("    },\n}\n");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}

test "size gate enforces limit and growth" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var report: repo.Report = .{ .arena = arena_state.allocator(), .tool = "test" };
    try evaluate(&report, 1000, &.{.{ .name = "a", .bytes = 100 }}, &.{
        .{ .name = "a", .bytes = 106 },
        .{ .name = "b", .bytes = 2000 },
    });
    try std.testing.expectEqual(@as(usize, 3), report.findings.items.len);
}
