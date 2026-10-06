//! Linux host integrations (docs/spec/platform-contract-v1.md#linux), freedesktop layout:
//! - shortcut: `<data>/applications/<product>.<slug>.desktop`;
//! - file association: shared-mime-info package `<data>/mime/packages/<product>-<ext>.xml` plus
//!   a hidden handler `<data>/applications/<product>.assoc-<ext>.desktop` with `MimeType=`;
//! - service: systemd unit `<config>/systemd/user/` (user) or `/etc/systemd/system/` (machine);
//! - registration: CapabilityUnsupported (installation.json is the registration).
//! `<data>` is `$XDG_DATA_HOME` (default `~/.local/share`) or `/usr/local/share` for machine.

const std = @import("std");
const contracts = @import("contracts");
const api = @import("api.zig");
const command = @import("command.zig");
const files = @import("files.zig");
const host = @import("host.zig");
const names = @import("names.zig");

const Error = api.Error;
const Allocator = std.mem.Allocator;

/// A file the integration owns; associations own two.
const Pair = struct { primary: files.Spec, mime: ?files.Spec = null };

fn dataDir(
    h: *const host.Host,
    arena: Allocator,
    scope: contracts.Scope,
    leaf: []const []const u8,
) Error![]const u8 {
    return switch (scope) {
        .user => {
            const base = h.options.env.xdg_data_home orelse
                try h.userPath(arena, &.{ ".local", "share" });
            return host.joinAbsolute(arena, base, leaf);
        },
        .machine => try host.joinAbsolute(
            arena,
            try h.systemPath(arena, &.{ "usr", "local", "share" }),
            leaf,
        ),
    };
}

fn unitPath(
    h: *const host.Host,
    arena: Allocator,
    scope: contracts.Scope,
    unit: []const u8,
) Error![]const u8 {
    return switch (scope) {
        .user => {
            const base = h.options.env.xdg_config_home orelse
                try h.userPath(arena, &.{".config"});
            return host.joinAbsolute(arena, base, &.{ "systemd", "user", unit });
        },
        .machine => try h.systemPath(arena, &.{ "etc", "systemd", "system", unit }),
    };
}

pub fn machineDirs(h: *const host.Host, arena: Allocator) Error![]const []const u8 {
    return arena.dupe([]const u8, &.{
        try dataDir(h, arena, .machine, &.{"applications"}),
        try dataDir(h, arena, .machine, &.{ "mime", "packages" }),
        try h.systemPath(arena, &.{ "etc", "systemd", "system" }),
    });
}

/// Lowercase alphanumerics; every other run of bytes becomes one `-`.
pub fn slug(arena: Allocator, text: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try out.append(arena, std.ascii.toLower(c));
        } else if (out.items.len > 0 and out.items[out.items.len - 1] != '-') {
            try out.append(arena, '-');
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') out.items.len -= 1;
    return names.token(out.items);
}

fn mimeType(arena: Allocator, product_id: []const u8, ext: []const u8) Error![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "application/x-{s}-{s}",
        .{ try slug(arena, product_id), ext },
    );
}

fn pair(h: *const host.Host, arena: Allocator, request: *const api.IntegrationRequest) Error!Pair {
    const i = request.integration;
    const product = try names.token(request.product_id);
    const exe = try host.executable(arena, '/', request.root, i.target);
    switch (i.kind) {
        .shortcut => {
            const file = try std.fmt.allocPrint(
                arena,
                "{s}.{s}.desktop",
                .{ product, try slug(arena, try names.segment(i.id)) },
            );
            return .{ .primary = .{
                .final = try dataDir(h, arena, request.scope, &.{ "applications", file }),
                .body = .{ .content = try desktopEntry(arena, i.label, exe, null) },
            } };
        },
        .file_association => {
            const ext = try names.extension(i.id);
            const mime = try mimeType(arena, product, ext);
            const file = try std.fmt.allocPrint(arena, "{s}.assoc-{s}.desktop", .{ product, ext });
            const xml = try std.fmt.allocPrint(arena, "{s}-{s}.xml", .{ product, ext });
            return .{
                .primary = .{
                    .final = try dataDir(h, arena, request.scope, &.{ "applications", file }),
                    .body = .{ .content = try desktopEntry(arena, i.label, exe, mime) },
                },
                .mime = .{
                    .final = try dataDir(h, arena, request.scope, &.{ "mime", "packages", xml }),
                    .body = .{ .content = try mimePackage(arena, mime, i.label, ext) },
                },
            };
        },
        .service => {
            const unit = try std.fmt.allocPrint(
                arena,
                "{s}-{s}.service",
                .{ product, try names.token(i.id) },
            );
            return .{ .primary = .{
                .final = try unitPath(h, arena, request.scope, unit),
                .body = .{ .content = try systemdUnit(arena, i.label, exe, request.scope) },
            } };
        },
        .registration => return error.CapabilityUnsupported,
    }
}

fn checkValue(text: []const u8) Error!void {
    for (text) |c| if (c < 0x20 or c == 0x7f) return error.PlatformIntegrationFailed;
}

/// Desktop Entry `Exec=` quoting: the path is double-quoted, and the characters the spec
/// reserves inside quotes are refused rather than escaped.
fn checkExec(exe: []const u8) Error!void {
    try checkValue(exe);
    if (std.mem.findAny(u8, exe, "\"`$\\%") != null) return error.PlatformIntegrationFailed;
}

pub fn desktopEntry(
    arena: Allocator,
    label: []const u8,
    exe: []const u8,
    mime: ?[]const u8,
) Error![]const u8 {
    try checkValue(label);
    try checkExec(exe);
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll(
        "[Desktop Entry]\nType=Application\nVersion=1.5\nName=",
    ) catch return error.OutOfMemory;
    for (label) |c| {
        const escaped: []const u8 = if (c == '\\') "\\\\" else &.{c};
        w.writeAll(escaped) catch return error.OutOfMemory;
    }
    if (mime) |m| {
        w.print(
            "\nExec=\"{s}\" %f\nNoDisplay=true\nMimeType={s};\n",
            .{ exe, m },
        ) catch return error.OutOfMemory;
    } else {
        w.print("\nExec=\"{s}\"\n", .{exe}) catch return error.OutOfMemory;
    }
    w.print("Terminal=false\nX-Niobium={s}\n", .{files.marker}) catch return error.OutOfMemory;
    return out.written();
}

pub fn mimePackage(
    arena: Allocator,
    mime: []const u8,
    label: []const u8,
    ext: []const u8,
) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.print(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!-- {s} -->
        \\<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
        \\  <mime-type type="{s}">
        \\    <comment>
    , .{ files.marker, mime }) catch return error.OutOfMemory;
    try files.xmlText(w, label);
    w.print(
        \\</comment>
        \\    <glob pattern="*.{s}"/>
        \\  </mime-type>
        \\</mime-info>
        \\
    , .{ext}) catch return error.OutOfMemory;
    return out.written();
}

pub fn systemdUnit(
    arena: Allocator,
    label: []const u8,
    exe: []const u8,
    scope: contracts.Scope,
) Error![]const u8 {
    try checkValue(label);
    try checkExec(exe);
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.print("# {s}\n[Unit]\nDescription=", .{files.marker}) catch return error.OutOfMemory;
    for (label) |c| {
        if (c == '%') w.writeAll(
            "%%",
        ) catch return error.OutOfMemory else w.writeByte(c) catch return error.OutOfMemory;
    }
    w.print(
        "\n\n[Service]\nType=simple\nExecStart=\"{s}\"\n\n[Install]\nWantedBy={s}\n",
        .{ exe, if (scope == .user) "default.target" else "multi-user.target" },
    ) catch return error.OutOfMemory;
    return out.written();
}

pub fn prepare(
    h: *const host.Host,
    arena: Allocator,
    request: *const api.IntegrationRequest,
) Error!void {
    const p = try pair(h, arena, request);
    try files.prepare(h.local, p.primary, request.tx);
    if (p.mime) |m| try files.prepare(h.local, m, request.tx);
}

pub fn discard(
    h: *const host.Host,
    arena: Allocator,
    request: *const api.IntegrationRequest,
) Error!void {
    const p = try pair(h, arena, request);
    try files.discard(h.local, p.primary.final, request.tx);
    if (p.mime) |m| try files.discard(h.local, m.final, request.tx);
}

fn systemctl(
    h: *const host.Host,
    arena: Allocator,
    scope: contracts.Scope,
    args: []const []const u8,
) Error!command.Outcome {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, "systemctl");
    try argv.append(arena, if (scope == .user) "--user" else "--system");
    try argv.appendSlice(arena, args);
    return command.run(h.local.io, arena, argv.items);
}

fn refresh(
    h: *const host.Host,
    arena: Allocator,
    scope: contracts.Scope,
    kind: contracts.installation.IntegrationKind,
) Error!void {
    if (!h.options.system_managers) return;
    switch (kind) {
        // Cache refreshes are advisory: desktops rescan these directories on their own.
        .shortcut, .file_association => {
            const apps = try dataDir(h, arena, scope, &.{"applications"});
            // lint-allow(no-discard-call): update-desktop-database is optional on many desktops.
            _ = try command.run(h.local.io, arena, &.{ "update-desktop-database", apps });
            if (kind == .file_association) {
                const mime = try dataDir(h, arena, scope, &.{"mime"});
                // lint-allow(no-discard-call): shared-mime-info may be absent on minimal systems.
                _ = try command.run(h.local.io, arena, &.{ "update-mime-database", mime });
            }
        },
        .service => if (try systemctl(h, arena, scope, &.{"daemon-reload"}) == .failed) {
            return error.PlatformIntegrationFailed;
        },
        .registration => {},
    }
}

pub fn activate(
    h: *const host.Host,
    arena: Allocator,
    request: *const api.IntegrationRequest,
) Error![]const u8 {
    const p = try pair(h, arena, request);
    if (p.mime) |m| try files.activate(h.local, m, request.tx);
    try files.activate(h.local, p.primary, request.tx);
    const i = request.integration;
    try refresh(h, arena, request.scope, i.kind);
    if (i.kind == .service and h.options.system_managers and i.start == .auto) {
        const unit = std.fs.path.basename(p.primary.final);
        if (try systemctl(h, arena, request.scope, &.{ "enable", "--now", unit }) == .failed) {
            return error.PlatformIntegrationFailed;
        }
    }
    return arena.dupe(u8, p.primary.final);
}

/// `<data>/applications/<product>.assoc-<ext>.desktop` →
/// `<data>/mime/packages/<product>-<ext>.xml`.
fn mimeSibling(arena: Allocator, location: []const u8) Error![]const u8 {
    const apps = std.fs.path.dirname(location) orelse return error.PlatformIntegrationFailed;
    const data = std.fs.path.dirname(apps) orelse return error.PlatformIntegrationFailed;
    const stem = std.fs.path.stem(location);
    const at = std.mem.findLast(u8, stem, ".assoc-") orelse return error.PlatformIntegrationFailed;
    const xml = try std.fmt.allocPrint(
        arena,
        "{s}-{s}.xml",
        .{ stem[0..at], stem[at + ".assoc-".len ..] },
    );
    return host.joinAbsolute(arena, data, &.{ "mime", "packages", xml });
}

pub fn remove(
    h: *const host.Host,
    arena: Allocator,
    installed: contracts.installation.Integration,
) Error!void {
    const scope: contracts.Scope = if (h.isSystem(installed.location)) .machine else .user;
    switch (installed.kind) {
        .shortcut => {},
        .file_association => try files.remove(
            h.local,
            try mimeSibling(arena, installed.location),
            files.marker,
        ),
        .service => if (h.options.system_managers) {
            const unit = std.fs.path.basename(installed.location);
            // lint-allow(no-discard-call): a unit that was never enabled needs no disable.
            _ = try systemctl(h, arena, scope, &.{ "disable", "--now", unit });
        },
        .registration => return error.CapabilityUnsupported,
    }
    try files.remove(h.local, installed.location, files.marker);
    try refresh(h, arena, scope, installed.kind);
}

test "freedesktop renderers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("hello-world-2", try slug(a, "Hello, World 2!"));
    const entry = try desktopEntry(a, "Hello", "/opt/x/current/bin/hello", "application/x-a-hello");
    try std.testing.expect(
        std.mem.find(u8, entry, "Exec=\"/opt/x/current/bin/hello\" %f\n") != null,
    );
    try std.testing.expect(std.mem.find(u8, entry, "MimeType=application/x-a-hello;\n") != null);
    try std.testing.expectError(
        error.PlatformIntegrationFailed,
        desktopEntry(a, "x", "/a$b", null),
    );
    try std.testing.expectError(
        error.PlatformIntegrationFailed,
        desktopEntry(a, "x\n", "/a", null),
    );
    const unit = try systemdUnit(a, "100% agent", "/opt/x/current/agent", .machine);
    try std.testing.expect(std.mem.find(u8, unit, "Description=100%% agent\n") != null);
    try std.testing.expect(std.mem.find(u8, unit, "WantedBy=multi-user.target\n") != null);
    const xml = try mimePackage(a, "application/x-a-hello", "Hello <doc>", "hello");
    try std.testing.expect(std.mem.find(u8, xml, "Hello &lt;doc&gt;") != null);
    try std.testing.expectEqualStrings(
        "/d/mime/packages/com.example.hello-hello.xml",
        try mimeSibling(a, "/d/applications/com.example.hello.assoc-hello.desktop"),
    );
}
