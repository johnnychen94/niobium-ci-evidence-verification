//! PlatformContract suite (docs/spec/platform-contract-v1.md#contract-tests), shared by every
//! backend. A backend is "supported" only when every required case passes; optional integration
//! kinds may answer CapabilityUnsupported, which is recorded, never silently skipped.

const std = @import("std");
const contracts = @import("contracts");
const platform = @import("platform");

const Platform = platform.Platform;
const Dir = std.Io.Dir;

pub const Case = enum {
    create_managed_file,
    atomic_replace,
    pointer_swap_recovery,
    shortcut,
    file_association,
    service,
    registration,
    free_space,
    integration_names,
};

pub const Verdict = enum { pass, unsupported, not_run };

pub const Report = struct {
    verdicts: std.EnumArray(Case, Verdict) = .initFill(.not_run),

    pub fn get(r: *const Report, case: Case) Verdict {
        return r.verdicts.get(case);
    }
};

/// Integration kinds a backend must implement for the subject's scope; others may be
/// unsupported.
pub const Required = struct {
    shortcut: bool = true,
    file_association: bool = false,
    service: bool = false,
    registration: bool = false,
};

pub const Subject = struct {
    platform: Platform,
    /// Absolute scratch directory the suite owns; it is emptied by the caller.
    base: []const u8,
    scope: contracts.Scope = .user,
    required: Required = .{},
};

pub const Failure = error{ContractViolated} || platform.Error;

fn violated(case: Case, comptime what: []const u8) error{ContractViolated} {
    std.log.warn("PlatformContract {t}: " ++ what, .{case});
    return error.ContractViolated;
}

const Suite = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    subject: Subject,
    report: Report = .{},

    fn path(s: *Suite, parts: []const []const u8) Failure![]const u8 {
        const all = try s.arena.alloc([]const u8, parts.len + 1);
        all[0] = s.subject.base;
        @memcpy(all[1..], parts);
        return std.fs.path.join(s.arena, all);
    }

    fn read(s: *Suite, file: []const u8) ?[]const u8 {
        return Dir.cwd().readFileAlloc(s.io, file, s.arena, .limited(1 << 20)) catch null;
    }

    fn exists(s: *Suite, file: []const u8) bool {
        Dir.cwd().access(s.io, file, .{}) catch return false;
        return true;
    }

    fn createManagedFile(s: *Suite) Failure!void {
        const p = s.subject.platform;
        const dir = try s.path(&.{ "managed", "nested" });
        try p.createDirPath(dir);
        try p.createDirPath(dir);
        const file = try s.path(&.{ "managed", "nested", "tool" });
        try p.writeFile(file, "#!/bin/sh\n", true);
        const bytes = s.read(file) orelse return violated(.create_managed_file, "file missing");
        if (!std.mem.eql(u8, bytes, "#!/bin/sh\n")) return violated(.create_managed_file, "bytes");
        if (comptime std.Io.File.Permissions.has_executable_bit) {
            const stat = Dir.cwd().statFile(s.io, file, .{}) catch
                return violated(.create_managed_file, "stat");
            if (stat.permissions.toMode() & 0o100 == 0) {
                return violated(.create_managed_file, "executable bit not set");
            }
        }
        const copy = try s.path(&.{ "managed", "copy" });
        try p.copyFile(file, copy, false);
        if (!std.mem.eql(u8, s.read(copy) orelse "", "#!/bin/sh\n")) {
            return violated(.create_managed_file, "copy");
        }
        try p.deleteTree(try s.path(&.{"managed"}));
        if (s.exists(file)) return violated(.create_managed_file, "deleteTree left files");
        try p.deleteFile(file);
    }

    fn atomicReplace(s: *Suite) Failure!void {
        const p = s.subject.platform;
        const dir = try s.path(&.{"atomic"});
        try p.createDirPath(dir);
        const file = try s.path(&.{ "atomic", "state.json" });
        try p.writeFile(file, "old", false);
        try p.writeFile(file, "new", false);
        if (!std.mem.eql(u8, s.read(file) orelse "", "new")) {
            return violated(.atomic_replace, "replace not visible");
        }
        try p.appendFile(file, "+tail");
        if (!std.mem.eql(u8, s.read(file) orelse "", "new+tail")) {
            return violated(.atomic_replace, "append");
        }
        var handle = Dir.cwd().openDir(s.io, dir, .{ .iterate = true }) catch
            return violated(.atomic_replace, "open dir");
        defer handle.close(s.io);
        var it = handle.iterate();
        var count: usize = 0;
        while (it.next(s.io) catch return violated(.atomic_replace, "iterate")) |_| count += 1;
        if (count != 1) return violated(.atomic_replace, "temp files left behind");
        const moved = try s.path(&.{ "atomic", "moved.json" });
        try p.rename(file, moved);
        if (s.exists(file) or !s.exists(moved)) return violated(.atomic_replace, "rename");
        try p.deleteTree(dir);
    }

    /// Leftovers of an interrupted swap (`current.next`, `current.old`) must not block the
    /// next swap, and readers always resolve a complete release.
    fn pointerSwap(s: *Suite) Failure!void {
        const p = s.subject.platform;
        for ([_][]const u8{ "1", "2", "3" }) |n| {
            try p.createDirPath(try s.path(&.{ "swap", "versions", n }));
            try p.writeFile(try s.path(&.{ "swap", "versions", n, "marker" }), n, false);
        }
        const link = try s.path(&.{ "swap", "current" });
        const marker = try s.path(&.{ "swap", "current", "marker" });
        try p.setPointer(link, "versions/1");
        if (!std.mem.eql(u8, s.read(marker) orelse "", "1")) {
            return violated(.pointer_swap_recovery, "first pointer");
        }
        try p.setPointer(link, "versions/2");
        if (!std.mem.eql(u8, s.read(marker) orelse "", "2")) {
            return violated(.pointer_swap_recovery, "swap");
        }
        // Interrupted swaps: a stale `.next` pointer and a stale `.old` directory.
        try p.setPointer(try s.path(&.{ "swap", "current.next" }), "versions/1");
        try p.createDirPath(try s.path(&.{ "swap", "current.old" }));
        try p.setPointer(link, "versions/3");
        if (!std.mem.eql(u8, s.read(marker) orelse "", "3")) {
            return violated(.pointer_swap_recovery, "swap over leftovers");
        }
        try p.deletePointer(link);
        try p.deletePointer(link);
        if (s.exists(marker)) return violated(.pointer_swap_recovery, "deletePointer");
        if (!s.exists(try s.path(&.{ "swap", "versions", "3", "marker" }))) {
            return violated(.pointer_swap_recovery, "deletePointer followed the link");
        }
        try p.deletePointer(try s.path(&.{ "swap", "current.next" }));
        try p.deleteTree(try s.path(&.{ "swap", "current.old" }));
        try p.deleteTree(try s.path(&.{"swap"}));
    }

    fn release(s: *Suite) Failure![]const u8 {
        const p = s.subject.platform;
        const root = try s.path(&.{"product"});
        try p.createDirPath(try s.path(&.{ "product", "versions", "1", "app", "bin" }));
        try p.writeFile(
            try s.path(&.{ "product", "versions", "1", "app", "bin", "hello" }),
            "x",
            true,
        );
        try p.setPointer(try s.path(&.{ "product", "current" }), "versions/1");
        return root;
    }

    fn request(
        s: *Suite,
        root: []const u8,
        kind: contracts.installation.IntegrationKind,
        id: []const u8,
        tx: u64,
    ) platform.api.IntegrationRequest {
        return .{
            .integration = .{
                .kind = kind,
                .id = id,
                .label = "Niobium Contract",
                .target = if (kind == .registration) "maintainer/setup" else "app/bin/hello",
                .start = if (kind == .service) .manual else null,
                .privileged = s.subject.scope == .machine,
            },
            .product_id = "dev.niobium.contract",
            .product_name = "Niobium Contract",
            .scope = s.subject.scope,
            .root = root,
            .tx = tx,
        };
    }

    /// prepare → discard leaves nothing; prepare → activate (twice, idempotent) → remove (twice).
    fn integration(
        s: *Suite,
        case: Case,
        kind: contracts.installation.IntegrationKind,
        id: []const u8,
        required: bool,
    ) Failure!Verdict {
        const p = s.subject.platform;
        const root = try s.release();
        const first = s.request(root, kind, id, 1);
        p.prepareIntegration(&first) catch |err| switch (err) {
            error.CapabilityUnsupported => {
                if (required) return violated(case, "required capability unsupported");
                return .unsupported;
            },
            else => return err,
        };
        try p.discardIntegration(&first);
        const second = s.request(root, kind, id, 2);
        try p.prepareIntegration(&second);
        const location = p.activateIntegration(s.arena, &second) catch |err| switch (err) {
            error.CapabilityUnsupported => {
                if (required) return violated(case, "required capability unsupported");
                try p.discardIntegration(&second);
                return .unsupported;
            },
            else => return err,
        };
        const again = try p.activateIntegration(s.arena, &second);
        if (!std.mem.eql(u8, location, again)) return violated(case, "activate not idempotent");
        const file_backed = std.fs.path.isAbsolute(location);
        if (file_backed and !s.exists(location)) return violated(case, "location missing");
        // An update re-activates the same id from a newer transaction over the live entry.
        const third = s.request(root, kind, id, 3);
        try p.prepareIntegration(&third);
        if (!std.mem.eql(u8, location, try p.activateIntegration(s.arena, &third))) {
            return violated(case, "location changed across transactions");
        }
        const installed: contracts.installation.Integration = .{
            .kind = kind,
            .id = id,
            .location = location,
        };
        try p.removeIntegration(installed);
        try p.removeIntegration(installed);
        if (file_backed and s.exists(location)) return violated(case, "remove left the entry");
        if (file_backed) try s.noTemps(case, location);
        try p.deleteTree(root);
        return .pass;
    }

    /// No `*.nb-tx-*` / `*.tx-*` temp siblings survive activation or discard.
    fn noTemps(s: *Suite, case: Case, location: []const u8) Failure!void {
        const dir = std.fs.path.dirname(location) orelse return;
        var handle = Dir.cwd().openDir(s.io, dir, .{ .iterate = true }) catch return;
        defer handle.close(s.io);
        var it = handle.iterate();
        while (it.next(s.io) catch return violated(case, "iterate")) |entry| {
            const temp = std.mem.find(u8, entry.name, ".tx-") != null or
                std.mem.find(u8, entry.name, ".nb-tx-") != null;
            if (temp) {
                return violated(case, "prepared temp left behind");
            }
        }
    }

    fn freeSpace(s: *Suite) Failure!void {
        const bytes = try s.subject.platform.freeSpace(try s.path(&.{ "not", "created", "yet" }));
        if (bytes == 0) return violated(.free_space, "zero bytes free on the scratch volume");
    }

    fn integrationNames(s: *Suite) Failure!void {
        const p = s.subject.platform;
        const root = try s.release();
        const bad_ids = [_][]const u8{ "../escape", "a/b", "a\\b", "..", "" };
        for (bad_ids) |id| {
            const r = s.request(root, .shortcut, id, 9);
            if (p.prepareIntegration(&r)) |_| {
                return violated(.integration_names, "escaping id accepted");
            } else |err| switch (err) {
                error.PlatformIntegrationFailed => {},
                else => return err,
            }
        }
        var bad_target = s.request(root, .shortcut, "Hello", 9);
        bad_target.integration.target = "../../etc/passwd";
        if (p.prepareIntegration(&bad_target)) |_| {
            // Virtual stores targets opaquely; host backends must refuse traversal.
            try p.discardIntegration(&bad_target);
        } else |err| switch (err) {
            error.PlatformIntegrationFailed => {},
            else => return err,
        }
        try p.deleteTree(root);
    }
};

pub fn run(io: std.Io, arena: std.mem.Allocator, subject: Subject) Failure!Report {
    var s: Suite = .{ .io = io, .arena = arena, .subject = subject };
    const r = &s.report.verdicts;
    try s.createManagedFile();
    r.set(.create_managed_file, .pass);
    try s.atomicReplace();
    r.set(.atomic_replace, .pass);
    try s.pointerSwap();
    r.set(.pointer_swap_recovery, .pass);
    const req = subject.required;
    r.set(.shortcut, try s.integration(.shortcut, .shortcut, "Niobium Contract", req.shortcut));
    r.set(
        .file_association,
        try s.integration(.file_association, .file_association, "nbcontract", req.file_association),
    );
    r.set(.service, try s.integration(.service, .service, "agent", req.service));
    r.set(
        .registration,
        try s.integration(.registration, .registration, "dev.niobium.contract", req.registration),
    );
    try s.freeSpace();
    r.set(.free_space, .pass);
    try s.integrationNames();
    r.set(.integration_names, .pass);
    return s.report;
}

test "PlatformContract: VirtualPlatform passes every case" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    try tmp.dir.createDirPath(io, "system");
    var v: platform.Virtual = .init(io, try std.fs.path.join(a, &.{ base, "system" }));
    const report = try run(io, a, .{
        .platform = v.platform(),
        .base = try std.fs.path.join(a, &.{ base, "work" }),
        .required = .{ .file_association = true, .service = true, .registration = true },
    });
    for (std.enums.values(Case)) |case| {
        try std.testing.expectEqual(Verdict.pass, report.get(case));
    }
}
