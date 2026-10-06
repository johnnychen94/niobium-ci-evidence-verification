//! The window's flow against the CLI on the same world (frontend_test.World): the controller's
//! start becomes the command the CLI parses, and running it installs the same thing.

const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts");
const portable = @import("portable");
const screens = @import("ui_screens");
const backend = @import("ui_backend");
const cli = @import("cli.zig");
const frontend = @import("frontend.zig");
const gui = @import("gui.zig");
const World = @import("frontend_test.zig").World;

const io = std.testing.io;

fn branded(w: *World) !void {
    w.embedded_config = try contracts.installation.encode(w.arena_state.allocator(), .{
        .schema = 1,
        .mode = .branded,
        .product_id = portable.testing.product_id,
        .repository = w.repo,
        .trust_root = w.root_bytes,
        .branding = .{ .product_name = "Hello" },
    });
}

fn noWake(_: *anyopaque) void {}

/// Window setup up to the first screen, as `gui.run` does it.
fn controller(w: *World, p: *frontend.Process) !screens.Controller {
    const s = try frontend.settings(p, .{ .verb = .gui });
    return gui.controllerFor(w.arena_state.allocator(), &s, try frontend.survey(p, s));
}

/// The start command the controller returns for `intents`.
fn startAfter(c: *screens.Controller, intents: []const @import("ui_core").input.Intent) !gui.Start {
    for (intents) |intent| {
        if (c.handle(intent)) |command| return command.start;
    }
    return error.TestNoStart;
}

/// Runs a window start on this thread, the way the worker does, and returns the exit code.
fn runStart(w: *World, p: *frontend.Process, start: gui.Start) !u8 {
    var worker: gui.Worker = .{ .process = p };
    var mailbox: backend.host.Mailbox = .{
        .io = io,
        .waker = .{ .context = w, .wake_fn = noWake },
    };
    const code = worker.transact(p, gui.commandFor(start), &mailbox);
    try std.testing.expect(mailbox.finished != null);
    return code;
}

fn statusJson(w: *World, dir: []const u8) ![]const u8 {
    const id = portable.testing.product_id;
    const argv = [_][]const u8{ "status", "--product", id, "--json", "--install-dir", dir };
    try std.testing.expectEqual(@as(u8, 0), try w.setup(&argv));
    return w.arena_state.allocator().dupe(u8, w.stdout());
}

test "N1-INV-07 the window and the command line build and run the same transaction" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try branded(&w);
    var p = w.process();
    const a = w.arena_state.allocator();

    var picked = try controller(&w, &p);
    try std.testing.expect(picked.handle(.{ .action = .next }) == null);
    try picked.folderChosen(w.install_dir);
    const elsewhere = try startAfter(&picked, &.{
        .{ .select = .{ .id = "scope", .index = 1 } },
        .{ .action = .install },
    });
    const elsewhere_argv = [_][]const u8{
        "install", "--scope", "machine", "--install-dir", w.install_dir,
    };
    try std.testing.expectEqualDeep(try cli.parse(a, &elsewhere_argv), gui.commandFor(elsewhere));

    var c = try controller(&w, &p);
    try std.testing.expectEqual(contracts.ui.Operation.install, c.vm.operation);
    const root = c.defaults.user_location;
    try std.testing.expectEqualStrings(root, c.vm.location);
    const install = try startAfter(&c, &.{ .{ .action = .next }, .{ .action = .install } });
    const install_argv = [_][]const u8{ "install", "--scope", "user" };
    try std.testing.expectEqualDeep(try cli.parse(a, &install_argv), gui.commandFor(install));
    try std.testing.expectEqual(@as(u8, 0), try runStart(&w, &p, install));
    const by_window = try statusJson(&w, root);

    var again = try controller(&w, &p);
    try std.testing.expectEqual(contracts.ui.Operation.update, again.vm.operation);
    try std.testing.expect(!again.vm.location_editable);
    const update = try startAfter(&again, &.{.{ .action = .install }});
    const update_argv = [_][]const u8{ "update", "--scope", "user", "--install-dir", root };
    try std.testing.expectEqualDeep(try cli.parse(a, &update_argv), gui.commandFor(update));
    try std.testing.expectEqual(@as(u8, 0), try runStart(&w, &p, update));

    try std.testing.expectEqual(@as(u8, 0), try w.setup(&.{"uninstall"}));
    try std.testing.expectEqual(@as(u8, 0), try w.setup(&install_argv));
    try std.testing.expectEqualStrings(by_window, try statusJson(&w, root));
    const exe = try std.fs.path.join(a, &.{ root, "current/runtime/bin/hello" });
    try std.Io.Dir.cwd().access(io, exe, .{});
}

test "a window start that fails reports the error name and the category's message" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try branded(&w);
    w.embedded_config = try std.mem.replaceOwned(
        u8,
        w.arena_state.allocator(),
        w.embedded_config,
        w.repo,
        "/nonexistent/niobium-repo",
    );
    var p = w.process();
    var worker: gui.Worker = .{ .process = &p };
    var mailbox: backend.host.Mailbox = .{
        .io = io,
        .waker = .{ .context = &w, .wake_fn = noWake },
    };
    const start: gui.Start = .{
        .operation = .install,
        .scope = .user,
        .install_dir = w.install_dir,
    };
    const code = worker.transact(&p, gui.commandFor(start), &mailbox);
    try std.testing.expect(code != 0);
    const finished = mailbox.finished.?;
    try std.testing.expect(finished.kind == .failed);
    try std.testing.expect(finished.code.len > 0);
    try std.testing.expect(finished.message.len > 0);
}
