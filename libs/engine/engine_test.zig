const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts");
const core = @import("core");
const platform = @import("platform");
const repository = @import("repository");
const transaction = @import("transaction");
const trust = @import("trust");
const portable = @import("portable");
const engine = @import("root.zig");

const testing = portable.testing;
const io = std.testing.io;
const Phase = contracts.events.Phase;

/// Bootstrap scripts need /bin/sh; on Windows the releases ship without a bootstrap.
const can_bootstrap = builtin.os.tag != .windows;

const Recorder = struct {
    arena: std.mem.Allocator,
    phases: std.ArrayList(Phase) = .empty,
    last_exit: ?u8 = null,

    fn sink(r: *Recorder) engine.Sink {
        return .bind(Recorder, r, record);
    }

    fn record(r: *Recorder, event: engine.events.Event) void {
        const items = r.phases.items;
        if (items.len == 0 or items[items.len - 1] != event.phase) {
            r.phases.append(r.arena, event.phase) catch return;
        }
        if (event.exit_code) |code| r.last_exit = code;
    }

    fn saw(r: *const Recorder, phase: Phase) bool {
        return std.mem.findScalar(Phase, r.phases.items, phase) != null;
    }
};

const World = struct {
    tmp: std.testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    base: []const u8,
    root: []const u8,
    cache: []const u8,
    system: []const u8,
    setup: []const u8,
    calls: []const u8,
    flag: []const u8,
    virtual: platform.Virtual,
    recorder: Recorder,
    published: testing.Repo,
    cancel: std.atomic.Value(bool) = .init(false),

    fn init(w: *World) !void {
        w.tmp = std.testing.tmpDir(.{});
        w.arena_state = .init(std.testing.allocator);
        const a = w.arena_state.allocator();
        w.base = try w.tmp.dir.realPathFileAlloc(io, ".", a);
        w.root = try w.path("root");
        w.cache = try w.path("cache");
        w.system = try w.path("system");
        w.setup = try w.path("setup-bin");
        w.calls = try w.path("bootstrap-calls");
        w.flag = try w.path("bootstrap-ok");
        try std.Io.Dir.cwd().createDirPath(io, w.system);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = w.setup, .data = "setup" });
        w.virtual = .init(io, w.system);
        w.recorder = .{ .arena = a };
    }

    fn deinit(w: *World) void {
        w.arena_state.deinit();
        w.tmp.cleanup();
    }

    fn arena(w: *World) std.mem.Allocator {
        return w.arena_state.allocator();
    }

    fn path(w: *World, name: []const u8) ![]const u8 {
        return std.fs.path.join(w.arena(), &.{ w.base, name });
    }

    /// Appends each request line to `calls`; succeeds only while `flag` exists when `gated`.
    fn bootScript(w: *World, gated: bool) ![]const u8 {
        const gate = if (gated) try w.arena().print("[ -f '{s}' ] || exit 1\n", .{w.flag}) else "";
        return w.arena().print(
            "#!/bin/sh\nread -r line\necho \"$line\" >> '{s}'\n{s}" ++
                "echo '{{\"protocol\":1,\"status\":\"ok\"}}'\n",
            .{ w.calls, gate },
        );
    }

    fn release(w: *World, sequence: u64, version: []const u8, gated: bool) !testing.Release {
        const a = w.arena();
        var files: std.ArrayList(testing.File) = .empty;
        var entries: std.ArrayList(testing.Entry) = .empty;
        try files.append(a, .{
            .path = "bin/hello",
            .data = try a.print("hello {s}", .{version}),
            .executable = true,
        });
        try files.append(a, .{ .path = "share/readme.txt", .data = "readme" });
        try entries.append(a, .{ .name = "main", .path = "bin/hello" });
        if (can_bootstrap) {
            try files.append(a, .{
                .path = "bin/boot",
                .data = try w.bootScript(gated),
                .executable = true,
            });
            try entries.append(a, .{ .name = "boot", .path = "bin/boot", .bootstrap = true });
        }
        const components = try a.dupe(testing.Component, &.{.{
            .id = "runtime",
            .files = files.items,
            .entrypoints = entries.items,
        }});
        return .{
            .sequence = sequence,
            .version = version,
            .components = components,
            .shortcuts = &.{.{ .name = "Hello", .entrypoint = "runtime.main" }},
            .bootstrap = if (can_bootstrap) "runtime.boot" else null,
            .allowed_scopes = &.{ .user, .machine },
        };
    }

    fn publish(w: *World, sequence: u64, version: []const u8) !void {
        w.published = try testing.publish(io, w.arena(), try w.release(sequence, version, false));
    }

    fn options(w: *World) engine.Options {
        return .{
            .io = io,
            .gpa = std.testing.allocator,
            .platform = w.virtual.platform(),
            .repository = &w.published.repo,
            .root_bytes = w.published.root_bytes,
            .product_id = testing.product_id,
            .install_dir = w.root,
            .work_dir = w.cache,
            .target_platform = testing.platform,
            .installer_version = "0.1.0",
            .maintainer_source = w.setup,
            .sink = w.recorder.sink(),
            .now = trust.testing.now,
            .cancel = &w.cancel,
        };
    }

    fn run(w: *World, kind: engine.Kind) engine.Error!engine.Report {
        return w.runWith(kind, w.options());
    }

    fn runWith(w: *World, kind: engine.Kind, opts: engine.Options) engine.Error!engine.Report {
        w.recorder.phases.clearRetainingCapacity();
        var e: engine.Engine = .init(opts);
        defer e.deinit();
        const report = try e.run(kind);
        return .{
            .outcome = report.outcome,
            .scope = report.scope,
            .root = report.root,
            .product_version = try w.arena().dupe(u8, report.product_version),
            .release_sequence = report.release_sequence,
            .bootstrap = report.bootstrap,
        };
    }

    fn read(w: *World, relative: []const u8) ![]const u8 {
        const full = try std.fs.path.join(w.arena(), &.{ w.root, relative });
        return std.Io.Dir.cwd().readFileAlloc(io, full, w.arena(), .limited(1 << 20));
    }

    fn installed(w: *World) !contracts.installation.Installation {
        return contracts.installation.decodeInstallation(
            w.arena(),
            try w.read("installation.json"),
        );
    }

    fn callsContain(w: *World, needle: []const u8) bool {
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            io,
            w.calls,
            w.arena(),
            .limited(1 << 20),
        ) catch
            return false;
        return std.mem.find(u8, bytes, needle) != null;
    }

    fn exists(w: *World, full: []const u8) bool {
        _ = w;
        std.Io.Dir.cwd().access(io, full, .{}) catch return false;
        return true;
    }

    /// Files left anywhere under `dir`.
    fn countFiles(w: *World, dir_path: []const u8) !usize {
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return 0;
        defer dir.close(io);
        var walker = try dir.walk(w.arena());
        defer walker.deinit();
        var count: usize = 0;
        while (try walker.next(io)) |entry| {
            if (entry.kind != .directory) count += 1;
        }
        return count;
    }
};

test "N1-UJ-01 user-scope install calls the app bootstrap" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try w.publish(1, "1.0.0");
    const report = try w.run(.install);
    try std.testing.expectEqual(engine.Outcome.installed, report.outcome);
    try std.testing.expectEqual(core.ExitCode.ok, report.exitCode());
    try std.testing.expectEqualStrings("hello 1.0.0", try w.read("current/runtime/bin/hello"));
    const state = try w.installed();
    try std.testing.expectEqual(@as(u64, 1), state.release_sequence);
    const integrations: usize = if (builtin.os.tag == .windows) 2 else 1;
    try std.testing.expectEqual(integrations, state.integrations.len);
    try std.testing.expectEqual(
        contracts.installation.IntegrationKind.shortcut,
        state.integrations[0].kind,
    );
    if (builtin.os.tag == .windows)
        try std.testing.expectEqual(
            contracts.installation.IntegrationKind.registration,
            state.integrations[1].kind,
        );
    try std.testing.expect(
        w.exists(try std.fs.path.join(w.arena(), &.{ w.root, "trust", "state.json" })),
    );
    try std.testing.expect(w.exists(try std.fs.path.join(w.arena(), &.{ w.root, "maintainer" })));
    try std.testing.expect(
        !w.exists(try std.fs.path.join(w.arena(), &.{ w.root, "journal", "tx-1.jsonl" })),
    );
    if (can_bootstrap) {
        try std.testing.expectEqual(contracts.installation.BootstrapState.done, state.bootstrap);
        try std.testing.expect(w.callsContain("\"operation\":\"activate\""));
        try std.testing.expect(w.callsContain("\"from_version\":null"));
        try std.testing.expect(w.recorder.saw(.bootstrap));
    }
    const order = [_]Phase{
        .recover, .discover, .resolve, .download, .execute, .commit, .complete,
    };
    for (order) |phase| try std.testing.expect(w.recorder.saw(phase));
}

test "N1-UJ-03 N1-UJ-04 update, incident rollback release, up to date, rollback refused" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try w.publish(1, "1.1.0");
    _ = try w.run(.install);
    try w.publish(2, "1.2.0");
    const update = try w.run(.update);
    try std.testing.expectEqual(engine.Outcome.updated, update.outcome);
    try std.testing.expectEqualStrings("hello 1.2.0", try w.read("current/runtime/bin/hello"));
    // Incident rollback: a higher release_sequence carrying an older app_version.
    try w.publish(3, "1.1.0");
    const rollback = try w.run(.update);
    try std.testing.expectEqualStrings("1.1.0", rollback.product_version);
    try std.testing.expectEqualStrings("hello 1.1.0", try w.read("current/runtime/bin/hello"));
    try std.testing.expectEqual(@as(u64, 3), (try w.installed()).active_tx);
    const again = try w.run(.update);
    try std.testing.expectEqual(engine.Outcome.up_to_date, again.outcome);
    // A replayed older repository is a trust failure, not a downgrade.
    try w.publish(2, "1.2.0");
    if (w.run(.update)) |_| return error.TestExpectedError else |err| {
        try std.testing.expectEqual(core.ExitCode.trust, core.exit_code.fromError(err));
    }
    try std.testing.expectEqual(@as(?u8, 4), w.recorder.last_exit);
    if (can_bootstrap) try std.testing.expect(w.callsContain("\"from_version\":\"1.2.0\""));
}

test "N1-UJ-05 repair restores deleted and tampered files" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try w.publish(1, "1.0.0");
    _ = try w.run(.install);
    const hello = try std.fs.path.join(
        w.arena(),
        &.{ w.root, "current", "runtime", "bin", "hello" },
    );
    const readme = try std.fs.path.join(
        w.arena(),
        &.{ w.root, "current", "runtime", "share", "readme.txt" },
    );
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = hello, .data = "tampered" });
    try std.Io.Dir.cwd().deleteFile(io, readme);
    const report = try w.run(.repair);
    try std.testing.expectEqual(engine.Outcome.repaired, report.outcome);
    try std.testing.expectEqualStrings("hello 1.0.0", try w.read("current/runtime/bin/hello"));
    try std.testing.expectEqualStrings("readme", try w.read("current/runtime/share/readme.txt"));
}

test "N1-UJ-06 uninstall removes the root and every integration" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try w.publish(1, "1.0.0");
    _ = try w.run(.install);
    try std.testing.expect(try w.countFiles(w.system) > 0);
    const report = try w.run(.uninstall);
    try std.testing.expectEqual(engine.Outcome.uninstalled, report.outcome);
    try std.testing.expect(!w.exists(w.root));
    try std.testing.expectEqual(@as(usize, 0), try w.countFiles(w.system));
    if (can_bootstrap) try std.testing.expect(w.callsContain("\"operation\":\"deactivate\""));
    try std.testing.expectError(error.NotInstalled, w.run(.uninstall));
    try std.testing.expectEqual(@as(?u8, 12), w.recorder.last_exit);
}

test "N1-UJ-07 offline bundle installs from a directory repository" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try w.publish(1, "1.0.0");
    const bundle = try w.path("bundle/repository");
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, bundle, .{});
    defer dir.close(io);
    for (w.published.repo.embedded.files) |file| {
        if (std.fs.path.dirname(file.path)) |parent| try dir.createDirPath(io, parent);
        try dir.writeFile(io, .{ .sub_path = file.path, .data = file.bytes });
    }
    const offline: repository.Repository = .{ .directory = .{ .io = io, .dir = dir } };
    var options = w.options();
    options.repository = &offline;
    const report = try w.runWith(.install, options);
    try std.testing.expectEqual(engine.Outcome.installed, report.outcome);
    try std.testing.expectEqualStrings("hello 1.0.0", try w.read("current/runtime/bin/hello"));
}

test "a failed bootstrap keeps the new release and is retried later" {
    if (!can_bootstrap) return error.SkipZigTest;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    w.published = try testing.publish(io, w.arena(), try w.release(1, "1.0.0", true));
    const report = try w.run(.install);
    try std.testing.expectEqual(contracts.installation.BootstrapState.pending, report.bootstrap);
    try std.testing.expectEqual(core.ExitCode.bootstrap_pending, report.exitCode());
    try std.testing.expectEqualStrings("hello 1.0.0", try w.read("current/runtime/bin/hello"));
    try std.testing.expectEqual(
        contracts.installation.BootstrapState.pending,
        (try w.installed()).bootstrap,
    );
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = w.flag, .data = "" });
    const retry = try w.run(.update);
    try std.testing.expectEqual(engine.Outcome.up_to_date, retry.outcome);
    try std.testing.expectEqual(contracts.installation.BootstrapState.done, retry.bootstrap);
    try std.testing.expectEqual(
        contracts.installation.BootstrapState.done,
        (try w.installed()).bootstrap,
    );
}

test "machine scope goes through the elevator" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try w.publish(1, "1.0.0");
    var options = w.options();
    options.scope = .machine;
    try std.testing.expectError(error.PrivilegeUnavailable, w.runWith(.install, options));
    try std.testing.expectEqual(@as(?u8, 7), w.recorder.last_exit);
    try std.testing.expect(!w.exists(w.root));
    options.elevator = .{ .direct = w.virtual.platform() };
    const report = try w.runWith(.install, options);
    try std.testing.expectEqual(contracts.Scope.machine, report.scope);
    try std.testing.expectEqual(contracts.Scope.machine, (try w.installed()).scope);
    try std.testing.expectEqualStrings("hello 1.0.0", try w.read("current/runtime/bin/hello"));
    const staging = try std.fs.path.join(w.arena(), &.{ w.cache, "staging", "tx-1" });
    try std.testing.expect(!w.exists(staging));
}

test "failures leave nothing behind and map to stable exit codes" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try w.publish(1, "1.0.0");
    try std.testing.expectError(error.NotInstalled, w.run(.update));

    const tampered_files = try w.arena().dupe(
        repository.embedded.File,
        w.published.repo.embedded.files,
    );
    const artifact_path = try trust.publish.targetPath(w.arena(), w.published.artifacts[0]);
    for (tampered_files) |*file| {
        if (!std.mem.eql(u8, file.path, artifact_path)) continue;
        const bytes = try w.arena().dupe(u8, file.bytes);
        bytes[bytes.len - 1] ^= 0xff;
        file.bytes = bytes;
    }
    const tampered: repository.Repository = .{ .embedded = .{ .io = io, .files = tampered_files } };
    var options = w.options();
    options.repository = &tampered;
    try std.testing.expectError(error.HashMismatch, w.runWith(.install, options));
    try std.testing.expectEqual(@as(?u8, 4), w.recorder.last_exit);
    try std.testing.expect(
        !w.exists(try std.fs.path.join(w.arena(), &.{ w.root, "installation.json" })),
    );

    w.virtual.free_bytes = 16;
    try std.testing.expectError(error.FsNoSpace, w.run(.install));
    try std.testing.expectEqual(@as(?u8, 6), w.recorder.last_exit);
    w.virtual.free_bytes = null;

    w.cancel.store(true, .release);
    try std.testing.expectError(error.Canceled, w.run(.install));
    try std.testing.expectEqual(@as(?u8, 9), w.recorder.last_exit);
    w.cancel.store(false, .release);

    var e: engine.Engine = .init(w.options());
    defer e.deinit();
    try std.testing.expectError(error.UsageStepOrder, e.fetch());

    const lock_path = try std.fs.path.join(w.arena(), &.{ w.cache, "lock" });
    const held = try transaction.Lock.acquire(io, lock_path);
    defer held.release(io);
    try std.testing.expectError(error.TransactionBusy, w.run(.install));
    try std.testing.expectEqual(@as(?u8, 10), w.recorder.last_exit);
}

test "a crash mid-commit is recovered before the next run" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try w.publish(1, "1.0.0");
    w.virtual.faults = .init(7, .{ .fault_per_mille = 0, .kill_at = 3 });
    try std.testing.expectError(error.PlatformKilled, w.run(.install));
    try std.testing.expect(w.exists(try std.fs.path.join(w.arena(), &.{ w.root, "journal" })));
    w.virtual = .init(io, w.system);
    const report = try w.run(.install);
    try std.testing.expectEqual(engine.Outcome.installed, report.outcome);
    try std.testing.expectEqualStrings("hello 1.0.0", try w.read("current/runtime/bin/hello"));
}
