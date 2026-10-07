//! Host PlatformContract (N1-AC-14): the backend compiled for this OS, with every system
//! location redirected into a temp directory and system managers off, so the suite never
//! touches the real home, registry or service manager. vm-smoke runs the same binary on
//! Windows 11 and Ubuntu (zig-out/cross-tests/<target>/suite-conformance).

const evidence = @import("test_evidence");
const std = @import("std");
const builtin = @import("builtin");
const conformance = @import("conformance");
const platform = @import("platform");
const contracts = @import("contracts");

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

    fn join(f: *Fixture, part: []const u8) ![]const u8 {
        return std.fs.path.join(f.arena.allocator(), &.{ f.base, part });
    }

    fn env(f: *Fixture) !platform.Env {
        return .{
            .home = try f.join("home"),
            .local_app_data = try f.join("local-app-data"),
            .app_data = try f.join("app-data"),
            .program_files = try f.join("program-files"),
            .program_data = try f.join("program-data"),
            .xdg_data_home = try f.join("xdg-data"),
            .xdg_config_home = try f.join("xdg-config"),
            .xdg_cache_home = try f.join("xdg-cache"),
        };
    }
};

/// Integration kinds each host must implement without system managers.
fn required() conformance.Required {
    return switch (builtin.os.tag) {
        .macos => .{ .service = true },
        .linux => .{ .file_association = true, .service = true },
        // Associations, registration and services live only in the registry and SCM.
        else => .{},
    };
}

fn expectReport(report: conformance.Report, req: conformance.Required) !void {
    const always = [_]conformance.Case{
        .create_managed_file, .atomic_replace, .pointer_swap_recovery,
        .shortcut,            .free_space,     .integration_names,
    };
    for (always) |case| try std.testing.expectEqual(conformance.Verdict.pass, report.get(case));
    if (req.file_association) {
        try std.testing.expectEqual(conformance.Verdict.pass, report.get(.file_association));
    }
    if (req.service) try std.testing.expectEqual(conformance.Verdict.pass, report.get(.service));
}

fn runHost(scope: contracts.Scope) !void {
    const id = if (scope == .user) "host-user" else "host-machine";
    if (!try evidence.selected(id)) return error.SkipZigTest;
    var f: Fixture = try .init();
    defer f.deinit();
    var host: platform.Host = .init(std.testing.io, .{
        .env = try f.env(),
        .machine_root = try f.join("machine"),
        .system_managers = false,
    });
    const req = required();
    const subject: conformance.Subject = .{
        .platform = host.platform(),
        .base = try f.join("work"),
        .scope = scope,
        .required = req,
    };
    var report: conformance.Report = .{};
    var failed = false;
    for (std.enums.values(conformance.Case)) |case| {
        const started = evidence.now();
        try evidence.record(id, @tagName(case), .NOT_RUN, "InProgress", started);
        const verdict = conformance.runCase(
            std.testing.io,
            f.arena.allocator(),
            subject,
            case,
        ) catch |err| {
            failed = true;
            report.verdicts.set(case, .fail);
            try evidence.record(id, @tagName(case), .FAIL, @errorName(err), started);
            continue;
        };
        report.verdicts.set(case, verdict);
        const unsupported = verdict == .unsupported;
        try evidence.record(
            id,
            @tagName(case),
            if (unsupported) .NOT_RUN else .PASS,
            if (unsupported) "OptionalCapabilityUnsupported" else "",
            started,
        );
    }
    if (failed) return error.ConformanceFailed;
    try expectReport(report, req);
}

test "N1-AC-14 host PlatformContract, user scope" {
    try runHost(.user);
}

test "N1-AC-14 host PlatformContract, machine scope under a redirected system root" {
    try runHost(.machine);
}
