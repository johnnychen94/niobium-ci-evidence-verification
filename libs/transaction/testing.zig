//! Test world for transaction, sim and engine tests: a temp base with `root/` (install root),
//! `system/` (VirtualPlatform integrations) and a fake running setup binary. `snapshot` renders
//! everything observable as canonical text, so "Active is OLD or NEW" is a string comparison.

const std = @import("std");
const contracts = @import("contracts");
const planner = @import("planner");
const platform = @import("platform");
const transaction = @import("root.zig");

pub const product_id = "com.example.hello";
const fake_digest = "abababababababababababababababababababababababababababababababab";

pub fn manifestJson(arena: std.mem.Allocator, sequence: u64, version: []const u8) ![]const u8 {
    return arena.print(
        \\{{"schema":1,"min_installer":"0.1.0",
        \\"product":{{"id":"{s}","name":"Hello","publisher":"Example","version":"{s}",
        \\"release_sequence":{d}}},
        \\"install":{{"default_scope":"user","allowed_scopes":["user"]}},
        \\"components":[{{"id":"runtime","title":"Runtime","required":true,
        \\"artifacts":{{"macos-aarch64":"sha256:{s}"}}}}],
        \\"integrations":{{"shortcuts":[{{"name":"Hello","entrypoint":"runtime.main"}}],
        \\"file_associations":[{{"extension":".hello","entrypoint":"runtime.main",
        \\"description":"Hello document"}}],
        \\"services":[{{"id":"hello-agent","entrypoint":"runtime.agent","start":"auto"}}]}}}}
    , .{ product_id, version, sequence, fake_digest });
}

pub const component_json =
    \\{"schema":1,"id":"runtime","version":"1.0.0","platform":"macos-aarch64",
    \\"entrypoints":{"main":{"path":"bin/hello"},"agent":{"path":"bin/hello-agent"}},
    \\"executables":["bin/hello","bin/hello-agent"]}
;

pub const World = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    base: []const u8,
    root: []const u8,
    system: []const u8,
    setup_binary: []const u8,

    pub fn init(io: std.Io, arena: std.mem.Allocator, base: []const u8) !World {
        const w: World = .{
            .io = io,
            .arena = arena,
            .base = base,
            .root = try std.fs.path.join(arena, &.{ base, "root" }),
            .system = try std.fs.path.join(arena, &.{ base, "system" }),
            .setup_binary = try std.fs.path.join(arena, &.{ base, "setup-bin" }),
        };
        try std.Io.Dir.cwd().createDirPath(io, w.system);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = w.setup_binary, .data = "setup" });
        return w;
    }

    pub fn staging(w: World, tx: u64) ![]const u8 {
        return std.fs.path.join(
            w.arena,
            &.{ w.root, "staging", try w.arena.print("tx-{d}", .{tx}) },
        );
    }

    /// Lay out an extracted release as the engine would before planning.
    pub fn stage(w: World, tx: u64, version: []const u8) !void {
        const dir = try w.staging(tx);
        const bin = try std.fs.path.join(w.arena, &.{ dir, "runtime", "bin" });
        try std.Io.Dir.cwd().createDirPath(w.io, bin);
        const hello = try std.fs.path.join(w.arena, &.{ bin, "hello" });
        const agent = try std.fs.path.join(w.arena, &.{ bin, "hello-agent" });
        try std.Io.Dir.cwd().writeFile(
            w.io,
            .{ .sub_path = hello, .data = try w.arena.print("hello {s}", .{version}) },
        );
        try std.Io.Dir.cwd().writeFile(w.io, .{ .sub_path = agent, .data = "agent" });
    }

    pub fn desired(w: World, sequence: u64, version: []const u8) !planner.Desired {
        const limits: contracts.Limits = .{};
        const json = contracts.json;
        const m = try json.decode(contracts.manifest.Manifest, w.arena, try manifestJson(
            w.arena,
            sequence,
            version,
        ), .{
            .max_bytes = limits.manifest_bytes,
            .max_schema = 1,
        });
        const meta = try json.decode(contracts.manifest.ComponentMeta, w.arena, component_json, .{
            .max_bytes = limits.manifest_bytes,
            .max_schema = 1,
        });
        return .{
            .manifest = m,
            .manifest_sha256 = fake_digest,
            .metas = try w.arena.dupe(contracts.manifest.ComponentMeta, &.{meta}),
            .channel = .stable,
            .scope = .user,
            .installer_version = "0.1.0",
        };
    }

    pub fn context(
        w: World,
        tx: u64,
        installed: ?contracts.installation.Installation,
    ) !planner.Context {
        return .{
            .tx_seq = tx,
            .tx_id = try w.arena.print("tx-{d}-test", .{tx}),
            .root = w.root,
            .staging = try w.staging(tx),
            .os = planner.paths.Os.of(contracts.Platform.current().?),
            .support = .{ .shortcuts = true, .file_associations = true, .services = true },
            .current = installed,
            .maintainer_source = w.setup_binary,
        };
    }

    pub fn current(w: World) !?contracts.installation.Installation {
        const path = try std.fs.path.join(w.arena, &.{ w.root, "installation.json" });
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            w.io,
            path,
            w.arena,
            .limited(1 << 20),
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        return try contracts.installation.decodeInstallation(w.arena, bytes);
    }

    /// Canonical text of everything observable under `root/` (staging excluded: transient by
    /// design) and `system/`. Empty directories are ignored; absolute paths are normalized.
    pub fn snapshot(w: World) ![]const u8 {
        var lines: std.ArrayList([]const u8) = .empty;
        try w.collect(&lines, "root", w.root);
        try w.collect(&lines, "system", w.system);
        std.mem.sortUnstable([]const u8, lines.items, {}, lessThan);
        return std.mem.join(w.arena, "\n", lines.items);
    }

    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }

    fn collect(
        w: World,
        lines: *std.ArrayList([]const u8),
        label: []const u8,
        path: []const u8,
    ) !void {
        var dir = std.Io.Dir.cwd().openDir(
            w.io,
            path,
            .{ .iterate = true },
        ) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(w.io);
        var walker = try dir.walk(w.arena);
        defer walker.deinit();
        while (try walker.next(w.io)) |entry| {
            if (std.mem.startsWith(u8, entry.path, "staging")) continue;
            const name = try w.arena.print("{s}/{s}", .{ label, entry.path });
            if (@import("builtin").os.tag == .windows) std.mem.replaceScalar(u8, name, '\\', '/');
            switch (entry.kind) {
                .sym_link => {
                    var buffer: [std.fs.max_path_bytes]u8 = undefined; // SAFETY: readLink fills.
                    const len = try dir.readLink(w.io, entry.path, &buffer);
                    if (@import("builtin").os.tag == .windows)
                        std.mem.replaceScalar(u8, buffer[0..len], '\\', '/');
                    try lines.append(
                        w.arena,
                        try w.arena.print("{s} -> {s}", .{ name, buffer[0..len] }),
                    );
                },
                .file => {
                    const bytes = try dir.readFileAlloc(
                        w.io,
                        entry.path,
                        w.arena,
                        .limited(1 << 20),
                    );
                    const escaped_base = try std.json.Stringify.valueAlloc(w.arena, w.base, .{});
                    const escaped = try std.mem.replaceOwned(
                        u8,
                        w.arena,
                        bytes,
                        escaped_base[1 .. escaped_base.len - 1],
                        "<base>",
                    );
                    const normalized = try std.mem.replaceOwned(
                        u8,
                        w.arena,
                        escaped,
                        w.base,
                        "<base>",
                    );
                    try lines.append(
                        w.arena,
                        try w.arena.print("{s} = {s}", .{ name, normalized }),
                    );
                },
                else => {},
            }
        }
    }
};

pub const Scenario = enum { install, update, uninstall };

pub fn runClean(w: World, the_plan: contracts.plan.Plan) !void {
    var v: platform.Virtual = .init(w.io, w.system);
    var t = try transaction.Transaction.begin(w.io, w.arena, v.platform(), the_plan, .{});
    try t.runAll();
}

/// Bring a world to the scenario's OLD state on a fault-free platform.
pub fn prepareOld(w: World, scenario: Scenario) !void {
    if (scenario == .install) return;
    try w.stage(1, "1.0.0");
    const first = try planner.install(w.arena, try w.context(1, null), try w.desired(1, "1.0.0"));
    try runClean(w, first);
}

pub fn planFor(w: World, scenario: Scenario) !contracts.plan.Plan {
    switch (scenario) {
        .install => {
            try w.stage(1, "1.0.0");
            return planner.install(w.arena, try w.context(1, null), try w.desired(1, "1.0.0"));
        },
        .update => {
            try w.stage(2, "2.0.0");
            const ctx = try w.context(2, try w.current());
            return planner.update(w.arena, .update, ctx, try w.desired(2, "2.0.0"));
        },
        .uninstall => return planner.uninstall(w.arena, try w.context(2, try w.current())),
    }
}
