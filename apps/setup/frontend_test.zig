//! The CLI frontend against a directory repository on the real host platform, with every user
//! path redirected into a temp directory. Windows is skipped: registration writes HKCU.

const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts");
const portable = @import("portable");
const trust = @import("trust");
const cli = @import("cli.zig");
const frontend = @import("frontend.zig");

const io = std.testing.io;
const testing = portable.testing;

pub const World = struct {
    tmp: std.testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    environ: std.process.Environ.Map,
    base: []const u8,
    repo: []const u8,
    root_file: []const u8,
    install_dir: []const u8,
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,
    /// The product config compiled into setup.
    embedded_config: []const u8 = "{\"schema\":1,\"mode\":\"generic\"}",
    root_bytes: []const u8 = "",

    pub fn init(w: *World) !void {
        w.* = .{
            .tmp = std.testing.tmpDir(.{}),
            .arena_state = .init(std.testing.allocator),
            .environ = undefined, // SAFETY: set below before any use.
            .base = "",
            .repo = "",
            .root_file = "",
            .install_dir = "",
            .out = undefined, // SAFETY: set below before any use.
            .err = undefined, // SAFETY: set below before any use.
        };
        const a = w.arena_state.allocator();
        w.base = try w.tmp.dir.realPathFileAlloc(io, ".", a);
        w.repo = try w.path("repository");
        w.root_file = try w.path("root.json");
        w.install_dir = try w.path("root");
        w.environ = .init(a);
        try w.environ.put("HOME", try w.path("home"));
        try w.environ.put("PATH", "/usr/bin:/bin");
        try w.environ.put("XDG_DATA_HOME", try w.path("data"));
        try w.environ.put("XDG_CONFIG_HOME", try w.path("config"));
        try w.environ.put("XDG_CACHE_HOME", try w.path("cache"));
        w.out = .init(a);
        w.err = .init(a);
        const files = try a.dupe(testing.File, &.{
            .{ .path = "bin/hello", .data = "#!/bin/sh\nexit 3\n", .executable = true },
        });
        const published = try testing.publish(io, a, .{
            .sequence = 1,
            .version = "1.0.0",
            .components = try a.dupe(testing.Component, &.{.{
                .id = "runtime",
                .files = files,
                .entrypoints = &.{.{ .name = "main", .path = "bin/hello" }},
            }}),
            .platform = contracts.Platform.current() orelse return error.SkipZigTest,
        });
        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, w.repo, .{});
        defer dir.close(io);
        for (published.repo.embedded.files) |file| {
            if (std.fs.path.dirname(file.path)) |parent| try dir.createDirPath(io, parent);
            try dir.writeFile(io, .{ .sub_path = file.path, .data = file.bytes });
        }
        w.root_bytes = published.root_bytes;
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = w.root_file,
            .data = published.root_bytes,
        });
    }

    pub fn deinit(w: *World) void {
        w.arena_state.deinit();
        w.tmp.cleanup();
    }

    pub fn path(w: *World, name: []const u8) ![]const u8 {
        return std.fs.path.join(w.arena_state.allocator(), &.{ w.base, name });
    }

    /// What `setup` runs with: this world's environment, output buffers and config.
    pub fn process(w: *World) frontend.Process {
        return .{
            .io = io,
            .gpa = std.testing.allocator,
            .arena = w.arena_state.allocator(),
            .environ = &w.environ,
            .self_exe = null,
            .stdout = &w.out.writer,
            .stderr = &w.err.writer,
            .embedded_config = w.embedded_config,
            .now = trust.testing.now,
        };
    }

    /// Runs `setup <argv…>` and returns its exit code; output is in `out` / `err`.
    pub fn setup(w: *World, argv: []const []const u8) !u8 {
        w.out.clearRetainingCapacity();
        w.err.clearRetainingCapacity();
        const command = try cli.parse(w.arena_state.allocator(), argv);
        var p = w.process();
        return frontend.execute(&p, command);
    }

    pub fn stdout(w: *World) []const u8 {
        return w.out.written();
    }
};

test "N1-AC-09 setup install, status, update, run, uninstall exit codes and JSON events" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const id = testing.product_id;
    const source = [_][]const u8{
        "--product", id, "--repo", w.repo, "--trust-root", w.root_file, "--json",
    };
    const where = [_][]const u8{ "--install-dir", w.install_dir };

    try std.testing.expectEqual(@as(u8, 0), try w.setup(&(.{"install"} ++ source ++ where)));
    try std.testing.expect(std.mem.find(u8, w.stdout(), "\"phase\":\"complete\"") != null);
    const exe = try w.path("root/current/runtime/bin/hello");
    try std.Io.Dir.cwd().access(io, exe, .{});

    const status = [_][]const u8{ "status", "--product", id, "--json" } ++ where;
    try std.testing.expectEqual(@as(u8, 0), try w.setup(&status));
    try std.testing.expect(std.mem.find(u8, w.stdout(), "\"version\":\"1.0.0\"") != null);

    try std.testing.expectEqual(@as(u8, 0), try w.setup(&(.{"update"} ++ source ++ where)));

    const run = .{ "run", id ++ ":runtime.main" } ++ source ++ .{ "--", "x" };
    try std.testing.expectEqual(@as(u8, 3), try w.setup(&run));

    const uninstall = [_][]const u8{ "uninstall", "--product", id, "--json" } ++ where;
    try std.testing.expectEqual(@as(u8, 0), try w.setup(&uninstall));
    try std.testing.expectEqual(@as(u8, 12), try w.setup(&status));
    try std.testing.expect(std.mem.find(u8, w.stdout(), "\"exit_code\":12") != null);

    const no_repo = [_][]const u8{ "install", "--product", id, "--json" };
    try std.testing.expectEqual(@as(u8, 2), try w.setup(&no_repo));
    try std.testing.expect(
        std.mem.find(u8, w.stdout(), "\"code\":\"usage.missing_repository\"") != null,
    );
    const no_product = [_][]const u8{ "install", "--repo", w.repo };
    try std.testing.expectEqual(@as(u8, 2), try w.setup(&no_product));
    try std.testing.expect(std.mem.find(u8, w.err.written(), "UsageMissingProduct") != null);
}
