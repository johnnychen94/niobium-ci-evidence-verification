const std = @import("std");
const contracts = @import("contracts");
const platform = @import("platform");
const executor = @import("root.zig");

const plan = contracts.plan;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    base: []const u8,

    fn init() !Fixture {
        var f: Fixture = .{
            .tmp = std.testing.tmpDir(.{}),
            .arena = .init(std.testing.allocator),
            .base = "",
        };
        f.base = try f.tmp.dir.realPathFileAlloc(std.testing.io, ".", f.arena.allocator());
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.arena.deinit();
        f.tmp.cleanup();
    }

    fn join(f: *Fixture, parts: []const []const u8) ![]const u8 {
        var all: std.ArrayList([]const u8) = .empty;
        try all.append(f.arena.allocator(), f.base);
        try all.appendSlice(f.arena.allocator(), parts);
        return std.fs.path.join(f.arena.allocator(), all.items);
    }
};

fn state() contracts.installation.Installation {
    return .{
        .product_id = "com.example.hello",
        .product_name = "Hello",
        .scope = .machine,
        .channel = .stable,
        .release_sequence = 1,
        .app_version = "1.0.0",
        .active_tx = 1,
        .installer_version = "0.1.0",
        .components = &.{"runtime"},
        .manifest_sha256 = "00",
    };
}

test "rolling back ops that never ran is a no-op" {
    var f: Fixture = try .init();
    defer f.deinit();
    const io = std.testing.io;
    var v: platform.Virtual = .init(io, try f.join(&.{"system"}));
    const shortcut: plan.Integration = .{
        .kind = .shortcut,
        .id = "Hello",
        .label = "Hello",
        .target = "runtime/bin/hello",
    };
    const p: plan.Plan = .{
        .tx_id = "tx-1",
        .tx_seq = 1,
        .kind = .install,
        .scope = .user,
        .root = try f.join(&.{"root"}),
        .staging = try f.join(&.{ "root", "staging", "tx-1" }),
        .ops = &.{},
        .state = state(),
    };
    var e: executor.Executor = .init(io, f.arena.allocator(), v.platform(), p);
    const ops = [_]plan.Op{
        .{ .place_release = .{ .tx = 1 } },
        .{ .place_maintainer = .{ .source = "/nowhere", .tx = 1 } },
        .{ .prepare_integration = shortcut },
        .{ .swap_current = .{ .tx = 1, .previous = null } },
    };
    for (ops) |op| try e.rollback(op);
    try std.testing.expectError(error.ExecutorInvalidPlan, e.rollback(.{ .write_state = .{} }));
}

test "machine scope copies the staged tree and keeps executable bits" {
    var f: Fixture = try .init();
    defer f.deinit();
    const io = std.testing.io;
    const staging = try f.join(&.{ "cache", "staging", "tx-1" });
    const bin = try f.join(&.{ "cache", "staging", "tx-1", "runtime", "bin" });
    try std.Io.Dir.cwd().createDirPath(io, bin);
    const hello = try f.join(&.{ "cache", "staging", "tx-1", "runtime", "bin", "hello" });
    try std.Io.Dir.cwd().writeFile(
        io,
        .{ .sub_path = hello, .data = "hi", .flags = .{ .permissions = .executable_file } },
    );
    var v: platform.Virtual = .init(io, try f.join(&.{"system"}));
    const p: plan.Plan = .{
        .tx_id = "tx-1",
        .tx_seq = 1,
        .kind = .install,
        .scope = .machine,
        .root = try f.join(&.{"root"}),
        .staging = staging,
        .ops = &.{},
        .state = state(),
    };
    var e: executor.Executor = .init(io, f.arena.allocator(), v.platform(), p);
    try e.apply(.{ .place_release = .{ .tx = 1 } });
    try e.apply(.{ .swap_current = .{ .tx = 1, .previous = null } });
    const placed = try f.join(&.{ "root", "current", "runtime", "bin", "hello" });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, placed, f.arena.allocator(), .limited(16));
    try std.testing.expectEqualStrings("hi", bytes);
    if (std.Io.File.Permissions.has_executable_bit) {
        const stat = try std.Io.Dir.cwd().statFile(io, placed, .{});
        try std.testing.expect(stat.permissions.toMode() & 0o100 != 0);
    }
    try e.rollback(.{ .swap_current = .{ .tx = 1, .previous = null } });
    try e.rollback(.{ .place_release = .{ .tx = 1 } });
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, placed, .{}));
}
