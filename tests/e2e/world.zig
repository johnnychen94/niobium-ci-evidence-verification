//! One temp directory per test: a publisher (keys, builds, repository) and a user whose HOME,
//! app-data and XDG directories all live inside it, so the real binaries never touch the
//! developer's home files. Windows also needs a disposable OS account for HKCU registration.
//! Every command and its exit code goes to `<evidence_dir>/<UTC>/<name>.txt`,
//! one `<UTC>` per test process.

const std = @import("std");
const builtin = @import("builtin");
const evidence = @import("test_evidence");
const options = @import("suite_options");

const io = std.testing.io;
const Dir = std.Io.Dir;
const windows = builtin.os.tag == .windows;

pub const product_id = "com.example.hello";

pub const Result = struct {
    code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

pub const Status = struct {
    version: []const u8,
    release_sequence: u64,
    root: []const u8,
    bootstrap: []const u8,
};

pub const World = struct {
    name: []const u8,
    tmp: std.testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    base: []const u8,
    env: std.process.Environ.Map,
    transcript: std.ArrayList(u8),
    invocation: u32 = 0,

    /// `w` must stay at a fixed address; `name` names the evidence file.
    pub fn init(w: *World, name: []const u8) !void {
        w.* = .{
            .name = name,
            .tmp = std.testing.tmpDir(.{}),
            .arena_state = .init(std.testing.allocator),
            .base = "",
            // SAFETY: assigned below once the arena exists.
            .env = undefined,
            .transcript = .empty,
        };
        const a = w.arena();
        w.base = try w.tmp.dir.realPathFileAlloc(io, ".", a);
        w.env = .init(a);
        const home = w.path("home");
        try w.env.put("HOME", home);
        try w.env.put("USERPROFILE", home);
        try w.env.put("LOCALAPPDATA", w.path("home/AppData/Local"));
        try w.env.put("APPDATA", w.path("home/AppData/Roaming"));
        try w.env.put("XDG_DATA_HOME", w.path("home/.local/share"));
        try w.env.put("XDG_CONFIG_HOME", w.path("home/.config"));
        try w.env.put("XDG_CACHE_HOME", w.path("home/.cache"));
        try w.env.put("TMPDIR", w.path("tmp"));
        try w.env.put("PATH", if (windows) "C:\\Windows\\System32" else "/usr/bin:/bin");
        if (windows) try w.env.put("SystemRoot", "C:\\Windows");
        for ([_][]const u8{ "home", "tmp" }) |sub| try w.tmp.dir.createDirPath(io, sub);
        try w.tmp.dir.writeFile(io, .{ .sub_path = "user-data.txt", .data = "owned by the app" });
    }

    pub fn deinit(w: *World) void {
        w.arena_state.deinit();
        w.tmp.cleanup();
    }

    pub fn arena(w: *World) std.mem.Allocator {
        return w.arena_state.allocator();
    }

    pub fn path(w: *World, sub: []const u8) []const u8 {
        return std.fs.path.join(w.arena(), &.{ w.base, sub }) catch @panic("OOM");
    }

    pub fn exec(w: *World, argv: []const []const u8) !Result {
        const a = w.arena();
        const result = try evidence.process.run(a, io, .{ .argv = argv, .env = &w.env });
        w.invocation += 1;
        const prefix = try std.fmt.allocPrint(a, "{s}-{d}", .{ w.name, w.invocation });
        try evidence.attachment(
            try std.fmt.allocPrint(a, "{s}.stdout.txt", .{prefix}),
            result.stdout,
        );
        try evidence.attachment(
            try std.fmt.allocPrint(a, "{s}.stderr.txt", .{prefix}),
            result.stderr,
        );
        try w.record(argv, result.code);
        try evidence.attachment(
            try std.fmt.allocPrint(a, "{s}.argv.json", .{prefix}),
            try std.json.Stringify.valueAlloc(
                a,
                .{ .argv = argv, .code = result.code, .reason = result.reason },
                .{},
            ),
        );
        try w.writeEvidence();
        if (result.reason.len > 0 and result.code == 255) return error.SubprocessInterrupted;
        return .{ .code = result.code, .stdout = result.stdout, .stderr = result.stderr };
    }

    /// Runs `argv` and fails the test, printing stderr, unless it exits with `expected`.
    pub fn expectExit(w: *World, expected: u8, argv: []const []const u8) !Result {
        const result = try w.exec(argv);
        if (result.code != expected) {
            std.debug.print("e2e: {s} exited {d}, expected {d}\n{s}\n", .{
                argv[0], result.code, expected, result.stderr,
            });
            return error.TestUnexpectedExitCode;
        }
        return result;
    }

    pub fn nbpack(w: *World, expected: u8, args: []const []const u8) !Result {
        return w.expectExit(expected, try w.command(options.nbpack_exe, args));
    }

    pub fn setup(w: *World, expected: u8, args: []const []const u8) !Result {
        return w.expectExit(expected, try w.command(options.setup_exe, args));
    }

    pub fn command(w: *World, exe: []const u8, args: []const []const u8) ![]const []const u8 {
        const all = try w.arena().alloc([]const u8, args.len + 1);
        all[0] = exe;
        @memcpy(all[1..], args);
        return all;
    }

    pub fn status(w: *World, extra: []const []const u8) !Status {
        const args = try std.mem.concat(w.arena(), []const u8, &.{
            &.{ "status", "--json", "--product", product_id, "--install-dir", w.path("managed") },
            extra,
        });
        const result = try w.setup(0, args);
        return std.json.parseFromSliceLeaky(Status, w.arena(), result.stdout, .{
            .ignore_unknown_fields = true,
        });
    }

    /// `file` is absolute or relative to the world's base.
    pub fn read(w: *World, file: []const u8) ![]const u8 {
        const full = if (std.fs.path.isAbsolute(file)) file else w.path(file);
        return Dir.cwd().readFileAlloc(io, full, w.arena(), .limited(1 << 20));
    }

    /// Lines the sample app's bootstrap appended (examples/hello/app/main.zig).
    pub fn bootstrapLog(w: *World) ![]const u8 {
        return w.read("home/.hello-bootstrap.log") catch |err| switch (err) {
            error.FileNotFound => "",
            else => err,
        };
    }

    fn record(w: *World, args: []const []const u8, code: u8) !void {
        const a = w.arena();
        for (args, 0..) |arg, index| {
            const shown = if (index == 0) std.fs.path.basename(arg) else arg;
            const scrubbed = try std.mem.replaceOwned(u8, a, shown, w.base, "$WORK");
            try w.transcript.appendSlice(a, scrubbed);
            try w.transcript.append(a, ' ');
        }
        try w.transcript.print(a, "=> {d}\n", .{code});
    }

    fn writeEvidence(w: *World) !void {
        try evidence.attachment(
            try std.fmt.allocPrint(w.arena(), "{s}.txt", .{w.name}),
            w.transcript.items,
        );
    }
};

/// The publisher side: `nbpack` over examples/hello, one build directory per release.
pub const Publisher = struct {
    w: *World,
    initialized: bool = false,

    pub fn keygen(p: *Publisher) !void {
        _ = try p.w.nbpack(0, &.{ "keygen", "--out", p.w.path("keys") });
    }

    /// Builds both components at `version` and publishes them as `sequence` on `channel`.
    pub fn release(p: *Publisher, version: []const u8, sequence: u64, channel: []const u8) !void {
        try p.publish(version, sequence, channel, 0);
    }

    /// `release` that expects `nbpack publish` to exit with `expected`.
    pub fn publish(
        p: *Publisher,
        version: []const u8,
        sequence: u64,
        channel: []const u8,
        expected: u8,
    ) !void {
        const w = p.w;
        const a = w.arena();
        const build = try std.fmt.allocPrint(a, "build-{d}", .{sequence});
        const runtime = try p.component(build, "runtime", version);
        const docs = try p.component(build, "docs", version);
        const args = try std.mem.concat(a, []const u8, &.{
            &.{ "publish", "--repo", w.path("repo"), "--keys", w.path("keys") },
            &.{
                "--product",
                try example(a, "product.json"),
                "--artifact",
                runtime,
                "--artifact",
                docs,
            },
            &.{ "--version", version, "--sequence", try std.fmt.allocPrint(a, "{d}", .{sequence}) },
            &.{ "--channel", channel, "--days", "365", "--timestamp-days", "365" },
            if (p.initialized) &.{} else &.{"--init"},
        });
        _ = try w.nbpack(expected, args);
        if (expected == 0) p.initialized = true;
        const runtime_bytes = try Dir.cwd().readFileAlloc(io, runtime, a, .limited(64 << 20));
        const docs_bytes = try w.read(docs);
        const hashes = try std.json.Stringify.valueAlloc(a, .{
            .version = version,
            .sequence = sequence,
            .runtime_sha256 = @as([]const u8, &evidence.model.digest(runtime_bytes)),
            .docs_sha256 = @as([]const u8, &evidence.model.digest(docs_bytes)),
        }, .{});
        try evidence.attachment(try std.fmt.allocPrint(a, "{s}-fixture-{d}-{d}.json", .{
            w.name, sequence, w.invocation,
        }), hashes);
    }

    fn component(
        p: *Publisher,
        build: []const u8,
        id: []const u8,
        version: []const u8,
    ) ![]const u8 {
        const w = p.w;
        const a = w.arena();
        const out = w.path(try std.fmt.allocPrint(a, "{s}/{s}.tar.zst", .{ build, id }));
        const runtime = std.mem.eql(u8, id, "runtime");
        const files = if (runtime) try p.runtimeFiles(build, version) else try example(
            a,
            "components/docs/files",
        );
        const source = if (windows and runtime) "component.windows.json" else "component.json";
        const source_path = try example(
            a,
            try std.fmt.allocPrint(a, "components/{s}/{s}", .{ id, source }),
        );
        _ = try w.nbpack(0, &.{
            "component", "build", "--source", source_path, "--files", files,
            "--version", version, "--out",    out,
        });
        return out;
    }

    /// `<build>/runtime/bin/hello[.exe]`: the sample app binary built by `zig build`.
    fn runtimeFiles(p: *Publisher, build: []const u8, version: []const u8) ![]const u8 {
        const w = p.w;
        const dir = w.path(try std.fmt.allocPrint(w.arena(), "{s}/runtime", .{build}));
        const bin = try std.fs.path.join(w.arena(), &.{ dir, "bin" });
        try Dir.cwd().createDirPath(io, bin);
        const name = if (windows) "hello.exe" else "hello";
        const dest = try std.fs.path.join(w.arena(), &.{ bin, name });
        try Dir.copyFile(Dir.cwd(), options.hello_exe, Dir.cwd(), dest, io, .{});
        try Dir.cwd().writeFile(io, .{
            .sub_path = try std.fs.path.join(w.arena(), &.{ bin, "release.txt" }),
            .data = version,
        });
        return dir;
    }

    pub fn trustRoot(p: *Publisher) []const u8 {
        return p.w.path("repo/metadata/1.root.json");
    }
};

/// A path under examples/hello; the suite and its children run with the repository as cwd.
fn example(a: std.mem.Allocator, sub: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ options.example_dir, sub });
}
