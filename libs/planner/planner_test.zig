const std = @import("std");
const contracts = @import("contracts");
const manifest = @import("manifest");
const planner = @import("root.zig");

const plan = contracts.plan;

const digest = "sha256:" ++ "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

const manifest_json =
    \\{"schema":1,"min_installer":"0.1.0",
    \\ "product":{"id":"com.example.hello","name":"Hello","publisher":"Example","version":"1.2.0",
    \\   "release_sequence":3},
    \\ "install":{"default_scope":"user","allowed_scopes":["user","machine"]},
    \\ "components":[{"id":"runtime","title":"Runtime","required":true,
    \\   "artifacts":{"macos-aarch64":"
++ digest ++
    \\"}}],
    \\ "integrations":{
    \\   "shortcuts":[{"name":"Hello","entrypoint":"runtime.main"}],
    \\   "file_associations":[{"extension":".hello","entrypoint":"runtime.main",
    \\     "description":"Hello"}],
    \\   "services":[{"id":"hello-agent","entrypoint":"runtime.agent","start":"auto"}]},
    \\ "bootstrap":{"entrypoint":"runtime.main","protocol":1}}
;

const component_json =
    \\{"schema":1,"id":"runtime","version":"1.2.0","platform":"macos-aarch64",
    \\ "entrypoints":{"main":{"path":"bin/hello","bootstrap":true},
    \\   "agent":{"path":"bin/hello-agent"}},
    \\ "executables":["bin/hello","bin/hello-agent"]}
;

const Fixture = struct {
    desired: planner.Desired,

    fn init(arena: std.mem.Allocator) !Fixture {
        const limits: contracts.Limits = .{};
        const m = try manifest.parse(arena, manifest_json, "0.1.0", limits);
        const meta = try manifest.parseComponent(arena, component_json, .@"macos-aarch64", limits);
        const metas = try arena.dupe(manifest.ComponentMeta, &.{meta});
        return .{ .desired = .{
            .manifest = m,
            .manifest_sha256 = "1111111111111111111111111111111111111111111111111111111111111111",
            .metas = metas,
            .channel = .stable,
            .scope = .user,
            .installer_version = "0.1.0",
        } };
    }

    fn context(os: planner.paths.Os, scope: contracts.Scope, tx: u64) planner.Context {
        return .{
            .tx_seq = tx,
            .tx_id = "tx-fixture",
            .root = "/root",
            .staging = "/root/staging/tx",
            .os = os,
            .support = .default(os, scope),
            .maintainer_source = "/tmp/setup",
        };
    }
};

fn tags(arena: std.mem.Allocator, p: plan.Plan) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (p.ops) |op| {
        try out.appendSlice(arena, @tagName(op));
        switch (op) {
            .prepare_integration, .activate_integration => |i| {
                try out.print(arena, "({t})", .{i.kind});
            },
            .remove_integration => |i| try out.print(arena, "({s})", .{i.id}),
            .swap_current => |s| try out.print(arena, "({d}<-{?d})", .{ s.tx, s.previous }),
            .remove_release => |r| try out.print(arena, "({d})", .{r.tx}),
            else => {},
        }
        try out.append(arena, ' ');
    }
    return out.items;
}

test "N1-AC-05 install on macOS: stages in order, associations left to the bundle" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.init(a);
    const p = try planner.install(a, Fixture.context(.macos, .user, 1), f.desired);
    try std.testing.expectEqualStrings(
        "place_release place_maintainer prepare_integration(shortcut) " ++
            "prepare_integration(service) swap_current(1<-null) activate_integration(shortcut) " ++
            "activate_integration(service) activate_maintainer write_state ",
        try tags(a, p),
    );
    const state = p.state.?;
    try std.testing.expectEqual(@as(u64, 1), state.active_tx);
    try std.testing.expectEqual(contracts.installation.BootstrapState.pending, state.bootstrap);
    try std.testing.expectEqualStrings("runtime/bin/hello", state.bootstrap_target.?);
    try std.testing.expectEqualStrings("runtime", state.components[0]);
    try std.testing.expectEqualStrings("runtime/bin/hello", p.ops[2].prepare_integration.target);
    try std.testing.expect(!p.ops[2].prepare_integration.privileged);
}

test "install on Windows machine scope: associations, services and registration, privileged" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    f.desired.scope = .machine;
    const p = try planner.install(a, Fixture.context(.windows, .machine, 1), f.desired);
    var kinds: [4]usize = @splat(0);
    for (p.ops) |op| switch (op) {
        .prepare_integration => |i| {
            kinds[@backingInt(i.kind)] += 1;
            try std.testing.expect(i.privileged);
            if (i.kind == .registration) {
                try std.testing.expectEqualStrings("maintainer\\setup.exe", i.target);
            }
        },
        else => {},
    };
    try std.testing.expectEqualSlices(usize, &.{ 1, 1, 1, 1 }, &kinds);
}

test "N1-AC-05 update replaces the release, removes stale integrations, keeps one commit point" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.init(a);
    const first = try planner.install(a, Fixture.context(.linux, .user, 1), f.desired);
    var current = first.state.?;
    current.integrations = &.{
        .{ .kind = .shortcut, .id = "Hello", .location = "/x/Hello.desktop" },
        .{ .kind = .shortcut, .id = "Old", .location = "/x/Old.desktop" },
    };
    var ctx = Fixture.context(.linux, .user, 2);
    ctx.current = current;
    ctx.maintainer_source = null;
    const p = try planner.update(a, .update, ctx, f.desired);
    try std.testing.expectEqualStrings(
        "place_release prepare_integration(shortcut) prepare_integration(file_association) " ++
            "prepare_integration(service) swap_current(2<-1) remove_integration(Old) " ++
            "activate_integration(shortcut) activate_integration(file_association) " ++
            "activate_integration(service) write_state remove_release(1) ",
        try tags(a, p),
    );
    try std.testing.expectEqual(@as(?usize, 4), p.commitIndex());
    const repair = try planner.update(a, .repair, ctx, f.desired);
    try std.testing.expectEqual(contracts.journal.TxKind.repair, repair.kind);
}

test "update and install preconditions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    var ctx = Fixture.context(.linux, .user, 2);
    try std.testing.expectError(error.NotInstalled, planner.update(a, .update, ctx, f.desired));
    try std.testing.expectError(error.NotInstalled, planner.uninstall(a, ctx));
    const first = try planner.install(a, Fixture.context(.linux, .user, 1), f.desired);
    ctx.current = first.state.?;
    try std.testing.expectError(error.PlanAlreadyInstalled, planner.install(a, ctx, f.desired));
    var other = ctx.current.?;
    other.product_id = "com.example.other";
    ctx.current = other;
    try std.testing.expectError(
        error.PlanProductMismatch,
        planner.update(a, .update, ctx, f.desired),
    );
    ctx.current = first.state.?;
    f.desired.scope = .machine;
    try std.testing.expectError(error.PlanScopeChange, planner.update(a, .update, ctx, f.desired));
}

test "N1-AC-05 uninstall removes current first, then integrations, then the release and root" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.init(a);
    const first = try planner.install(a, Fixture.context(.linux, .user, 5), f.desired);
    var ctx = Fixture.context(.linux, .user, 6);
    var current = first.state.?;
    current.integrations = &.{.{ .kind = .shortcut, .id = "Hello", .location = "/x" }};
    ctx.current = current;
    const p = try planner.uninstall(a, ctx);
    try std.testing.expectEqualStrings(
        "remove_current remove_integration(Hello) remove_release(5) remove_root ",
        try tags(a, p),
    );
    try std.testing.expect(p.state == null);
}

test "missing entrypoints and duplicate integrations are rejected" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    var meta = f.desired.metas[0];
    meta.entrypoints = .{};
    f.desired.metas = &.{meta};
    try std.testing.expectError(
        error.ComponentMissingEntrypoint,
        planner.install(a, Fixture.context(.linux, .user, 1), f.desired),
    );
    f = try Fixture.init(a);
    var m = f.desired.manifest;
    m.integrations.shortcuts = &.{
        .{ .name = "Hello", .entrypoint = "runtime.main" },
        .{ .name = "hello", .entrypoint = "runtime.main" },
    };
    f.desired.manifest = m;
    try std.testing.expectError(
        error.PlanDuplicateIntegration,
        planner.install(a, Fixture.context(.linux, .user, 1), f.desired),
    );
}

test "plans survive the journal round trip and re-check" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.init(a);
    const p = try planner.install(a, Fixture.context(.macos, .user, 1), f.desired);
    const back = try plan.decode(a, try plan.encode(a, p));
    try planner.check(back);
    try std.testing.expectEqualStrings(try tags(a, p), try tags(a, back));
    var broken = back;
    var reordered = try a.dupe(plan.Op, back.ops);
    std.mem.swap(plan.Op, &reordered[0], &reordered[reordered.len - 1]);
    broken.ops = reordered;
    try std.testing.expectError(error.PlanInvalid, planner.check(broken));
}

fn planUnderAllocator(gpa: std.mem.Allocator) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.init(a);
    const p = try planner.install(a, Fixture.context(.windows, .user, 1), f.desired);
    const bytes = try plan.encode(a, p);
    std.debug.assert(bytes.len > 0);
}

test "planner handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, planUnderAllocator, .{});
}
