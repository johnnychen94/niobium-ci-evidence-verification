//! `zig build vm-smoke [-- --start] [-- --vm <name>]` (docs/runbooks/vm-smoke.md): runs the
//! examples/hello offline bundle of each VM target in its Parallels guest as the logged-in user:
//! install, update, repair, uninstall, then a console screenshot. A VM that is not running is
//! BLOCKED unless `--start` allows booting or resuming it. Evidence: `<evidence>/<UTC>/`.

const std = @import("std");
const guest = @import("guest.zig");
const serve = @import("serve.zig");

const Dir = std.Io.Dir;
const max_output = 1 << 20;
const tools_attempts = 60;
const tools_interval_seconds = 5;

const Bundle = struct { target: []const u8, path: []const u8 };

const Args = struct {
    prlctl: []const u8 = "prlctl",
    evidence: []const u8 = ".evidence/vm-smoke",
    bundles: []const Bundle = &.{},
    start: bool = false,
    only: ?[]const u8 = null,
};

const Outcome = union(enum) {
    pass,
    fail: []const u8,
    blocked: []const u8,
};

const Run = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    args: Args,
    /// `<evidence>/<UTC>`.
    out: []const u8,
    /// Host address on the Parallels shared network, if there is one.
    host: ?[]const u8,
    stamp: []const u8,
    transcript: std.ArrayList(u8) = .empty,

    fn prl(r: *Run, args: []const []const u8) !Result {
        return r.command(try std.mem.concat(r.arena, []const u8, &.{ &.{r.args.prlctl}, args }));
    }

    /// `argv` in the guest as the logged-in user (Parallels Tools).
    fn exec(r: *Run, vm: guest.Vm, argv: []const []const u8) !Result {
        return r.prl(try std.mem.concat(r.arena, []const u8, &.{
            &.{ "exec", vm.name, "--current-user" },
            argv,
        }));
    }

    fn command(r: *Run, argv: []const []const u8) !Result {
        const result = try std.process.run(r.arena, r.io, .{
            .argv = argv,
            .stdout_limit = .limited(max_output),
            .stderr_limit = .limited(max_output),
        });
        const code: u8 = switch (result.term) {
            .exited => |c| c,
            else => 255,
        };
        try r.transcript.appendSlice(r.arena, "$");
        for (argv[1..]) |arg| try r.transcript.print(r.arena, " {s}", .{arg});
        try r.transcript.print(
            r.arena,
            "\n{s}{s}=> {d}\n\n",
            .{ result.stdout, result.stderr, code },
        );
        return .{ .code = code, .stdout = result.stdout };
    }

    fn note(r: *Run, text: []const u8) !void {
        try r.transcript.print(r.arena, "# {s}\n", .{text});
    }
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = parseArgs(arena, try init.minimal.args.toSlice(arena)) catch |err| {
        std.debug.print("vm-smoke: {t}\nusage: vm-smoke [--start] [--vm <name>] " ++
            "[--prlctl <path>] [--evidence <dir>] [--bundle <target> <dir>]...\n", .{err});
        return 2;
    };
    var stamp_buffer: [32]u8 = undefined; // SAFETY: written by writeUtc before use.
    var stamp_writer: std.Io.Writer = .fixed(&stamp_buffer);
    try writeUtc(&stamp_writer, std.Io.Clock.real.now(io).toSeconds());
    const stamp = stamp_writer.buffered();
    var r: Run = .{
        .io = io,
        .arena = arena,
        .args = args,
        .out = try std.fs.path.join(arena, &.{ args.evidence, stamp }),
        .host = try hostAddress(io, arena, args.prlctl),
        .stamp = stamp,
    };
    try Dir.cwd().createDirPath(io, r.out);
    var summary: std.ArrayList(u8) = .empty;
    var failed = false;
    for (guest.vms) |vm| {
        if (r.args.only) |only| if (!std.mem.eql(u8, only, vm.name)) continue;
        r.transcript = .empty;
        const outcome = smoke(&r, vm) catch |err| Outcome{ .fail = @errorName(err) };
        const line = switch (outcome) {
            .pass => try std.fmt.allocPrint(arena, "{s}: PASS\n", .{vm.name}),
            .fail => |why| try std.fmt.allocPrint(arena, "{s}: FAIL ({s})\n", .{ vm.name, why }),
            .blocked => |why| try std.fmt.allocPrint(
                arena,
                "{s}: BLOCKED ({s})\n",
                .{ vm.name, why },
            ),
        };
        failed = failed or outcome == .fail;
        try summary.appendSlice(arena, line);
        std.debug.print("vm-smoke: {s}", .{line});
        try writeEvidence(&r, try slug(arena, vm.name), "transcript.txt", r.transcript.items);
    }
    try writeEvidence(&r, "", "summary.txt", summary.items);
    std.debug.print("vm-smoke: evidence in {s}\n", .{r.out});
    return if (failed) 1 else 0;
}

fn parseArgs(arena: std.mem.Allocator, argv: []const []const u8) !Args {
    var args: Args = .{};
    var bundles: std.ArrayList(Bundle) = .empty;
    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        const rest = argv.len - index - 1;
        if (std.mem.eql(u8, arg, "--start")) {
            args.start = true;
        } else if (std.mem.eql(u8, arg, "--prlctl") and rest >= 1) {
            index += 1;
            args.prlctl = argv[index];
        } else if (std.mem.eql(u8, arg, "--evidence") and rest >= 1) {
            index += 1;
            args.evidence = argv[index];
        } else if (std.mem.eql(u8, arg, "--vm") and rest >= 1) {
            index += 1;
            args.only = argv[index];
        } else if (std.mem.eql(u8, arg, "--bundle") and rest >= 2) {
            try bundles.append(arena, .{ .target = argv[index + 1], .path = argv[index + 2] });
            index += 2;
        } else {
            return error.UsageVmSmoke;
        }
    }
    args.bundles = bundles.items;
    return args;
}

fn smoke(r: *Run, vm: guest.Vm) !Outcome {
    const bundle = for (r.args.bundles) |b| {
        if (std.mem.eql(u8, b.target, vm.target)) break b.path;
    } else return .{ .blocked = "no bundle for its target" };
    const status = try r.prl(&.{ "status", vm.name });
    if (status.code != 0) return .{ .blocked = "VM is not registered in Parallels" };
    const state = guest.parseState(status.stdout);
    if (state != .running) {
        if (!r.args.start) return .{
            .blocked = try std.fmt.allocPrint(
                r.arena,
                "VM is {t}; rerun with -- --start",
                .{state},
            ),
        };
        const verb = if (state == .stopped) "start" else "resume";
        if ((try r.prl(&.{ verb, vm.name })).code != 0) return .{
            .blocked = "prlctl could not start it",
        };
        if (!try waitForTools(r, vm)) return .{
            .blocked = "Parallels Tools did not answer in 300 s",
        };
    }
    const host = r.host orelse return .{ .blocked = "no Parallels shared network on the host" };
    const root = try guest.scratch(r.arena, vm.os, r.stamp);
    const setup = try copyBundle(r, vm, bundle, host, root) orelse return .{
        .fail = "download failed",
    };
    for ([_][]const []const u8{
        &.{ "install", "--scope", "user" },
        &.{"update"},
        &.{"repair"},
        &.{"uninstall"},
    }) |verb| {
        const argv = try std.mem.concat(
            r.arena,
            []const u8,
            &.{ &.{setup}, verb, &.{ "--silent", "--json" } },
        );
        const result = try r.exec(vm, argv);
        if (result.code != 0) return .{
            .fail = try std.fmt.allocPrint(r.arena, "{s} exited {d}", .{ verb[0], result.code }),
        };
    }
    const shot_dir = try std.fs.path.join(r.arena, &.{ r.out, try slug(r.arena, vm.name) });
    try Dir.cwd().createDirPath(r.io, shot_dir);
    const shot = try std.fs.path.join(r.arena, &.{ shot_dir, "screen.png" });
    const capture = try r.prl(&.{ "capture", vm.name, "--file", shot });
    if (capture.code != 0) try r.note("screenshot failed (advisory)");
    return .pass;
}

/// Downloads every bundle file into `root`; the guest path of setup, or null on a failed copy.
fn copyBundle(
    r: *Run,
    vm: guest.Vm,
    bundle: []const u8,
    host: []const u8,
    root: []const u8,
) !?[]const u8 {
    var dir = try Dir.cwd().openDir(r.io, bundle, .{ .iterate = true });
    defer dir.close(r.io);
    var server: serve.Server = undefined; // SAFETY: initialized by start.
    try server.start(r.io, host, dir);
    defer server.shutdown();
    var setup: ?[]const u8 = null;
    var walker = try dir.walk(r.arena);
    defer walker.deinit();
    while (try walker.next(r.io)) |entry| {
        if (entry.kind != .file) continue;
        const rel = try std.mem.replaceOwned(u8, r.arena, entry.path, "\\", "/");
        const dest = try guest.join(r.arena, vm.os, root, rel);
        const fetched = try r.exec(
            vm,
            try guest.fetch(r.arena, vm.os, try server.url(r.arena, rel), dest),
        );
        if (fetched.code != 0) return null;
        if (std.mem.eql(u8, rel, "setup") or std.mem.eql(u8, rel, "setup.exe")) setup = dest;
    }
    const path = setup orelse return null;
    if (vm.os == .linux and (try r.exec(vm, &.{ "chmod", "+x", path })).code != 0) return null;
    return path;
}

fn waitForTools(r: *Run, vm: guest.Vm) !bool {
    const probe: []const []const u8 = switch (vm.os) {
        .linux => &.{"true"},
        .windows => &.{ "cmd.exe", "/c", "exit 0" },
    };
    for (0..tools_attempts) |_| {
        if ((try r.exec(vm, probe)).code == 0) return true;
        try r.io.sleep(.fromSeconds(tools_interval_seconds), .awake);
    }
    return false;
}

const Result = struct { code: u8, stdout: []const u8 };

fn hostAddress(io: std.Io, arena: std.mem.Allocator, prlctl: []const u8) !?[]const u8 {
    const dir = std.fs.path.dirname(prlctl) orelse ".";
    const prlsrvctl = try std.fs.path.join(arena, &.{ dir, "prlsrvctl" });
    const result = std.process.run(arena, io, .{
        .argv = &.{ prlsrvctl, "net", "info", "Shared" },
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    }) catch return null;
    if (!result.term.success()) return null;
    return guest.parseHostAddress(result.stdout);
}

fn writeEvidence(r: *Run, sub: []const u8, name: []const u8, data: []const u8) !void {
    const dir = try std.fs.path.join(r.arena, &.{ r.out, sub });
    try Dir.cwd().createDirPath(r.io, dir);
    const path = try std.fs.path.join(r.arena, &.{ dir, name });
    try Dir.cwd().writeFile(r.io, .{ .sub_path = path, .data = data });
}

/// `Windows 11` -> `windows-11`.
fn slug(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, name.len);
    for (name, out) |c, *o| o.* = if (std.ascii.isAlphanumeric(
        c,
    ) or c == '.') std.ascii.toLower(c) else '-';
    return out;
}

/// `YYYYMMDDTHHMMSSZ`, as in libs/core/crash.zig.
fn writeUtc(writer: *std.Io.Writer, unix_seconds: i64) std.Io.Writer.Error!void {
    const seconds: u64 = std.math.cast(u64, unix_seconds) orelse 0;
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const day = epoch.getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    const clock = epoch.getDaySeconds();
    try writer.print("{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        day.year,                month_day.month.numeric(),  month_day.day_index + 1,
        clock.getHoursIntoDay(), clock.getMinutesIntoHour(), clock.getSecondsIntoMinute(),
    });
}

test {
    _ = guest;
    _ = serve;
}

test "arguments and slugs" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try parseArgs(
        a,
        &.{ "vm-smoke", "--start", "--bundle", "aarch64-linux", "zig-out/vm/a" },
    );
    try std.testing.expect(args.start);
    try std.testing.expectEqualStrings("zig-out/vm/a", args.bundles[0].path);
    try std.testing.expectError(error.UsageVmSmoke, parseArgs(a, &.{ "vm-smoke", "--bogus" }));
    try std.testing.expectEqualStrings("ubuntu-24.04.3-arm64", try slug(a, "Ubuntu 24.04.3 ARM64"));
}
