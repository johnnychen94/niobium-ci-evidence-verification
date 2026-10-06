//! Windows host integrations (docs/spec/platform-contract-v1.md#windows):
//! - shortcut: MS-SHLLINK `.lnk` under `Start Menu\Programs` (roaming `%APPDATA%` for user,
//!   `%ProgramData%` for machine), written by hand so no COM/shell32 is needed;
//! - file association: ProgID `<product>.<ext>` under `Software\Classes` plus
//!   `.<ext>\OpenWithProgids`; the extension default is only claimed when unset or ours;
//! - service: SCM, machine scope only;
//! - registration: `Software\Microsoft\Windows\CurrentVersion\Uninstall\<product>`;
//! - `current` pointer: a directory junction (no symlink privilege needed), swapped with two
//!   renames. A crash between them leaves no `current`; rollback or roll-forward re-runs the
//!   swap, which tolerates the missing link.
//! Registry and SCM entries carry `NiobiumManaged`/the product prefix; foreign ones are refused.

const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts");
const api = @import("api.zig");
const files = @import("files.zig");
const host = @import("host.zig");
const names = @import("names.zig");
const registry = @import("windows_registry.zig");
const service = @import("windows_service.zig");
const util = @import("windows_util.zig");

const Error = api.Error;
const Allocator = std.mem.Allocator;
const windows = std.os.windows;
const u32Of = util.u32Of;
const wideOf = util.wideOf;
const wideZ = util.wideZ;

/// `.lnk` ownership: the target resolves through the managed `current` junction.
const lnk_owner = "\\current\\";
const programs = [_][]const u8{ "Microsoft", "Windows", "Start Menu", "Programs" };

// ---------------------------------------------------------------- MS-SHLLINK

const link_clsid = [16]u8{ 0x01, 0x14, 0x02, 0, 0, 0, 0, 0, 0xC0, 0, 0, 0, 0, 0, 0, 0x46 };
const has_link_info: u32 = 0x02;
const has_name: u32 = 0x04;
const has_working_dir: u32 = 0x10;
const has_icon_location: u32 = 0x40;
const is_unicode: u32 = 0x80;

fn put32(w: *std.Io.Writer, value: u32) Error!void {
    w.writeInt(u32, value, .little) catch return error.OutOfMemory;
}

fn put16(w: *std.Io.Writer, value: u16) Error!void {
    w.writeInt(u16, value, .little) catch return error.OutOfMemory;
}

fn stringData(w: *std.Io.Writer, arena: Allocator, text: []const u8) Error!void {
    const units = try wideOf(arena, text);
    try put16(w, std.math.cast(u16, units.len) orelse return error.PlatformIntegrationFailed);
    for (units) |u| try put16(w, u);
}

/// Minimal shell link: LinkInfo with a local base path (ANSI fallback + Unicode), a name,
/// working directory and icon. Explorer resolves the target from LinkInfo.
pub fn shellLink(
    arena: Allocator,
    exe: []const u8,
    working_dir: []const u8,
    label: []const u8,
) Error![]const u8 {
    for (label) |c| if (c < 0x20) return error.PlatformIntegrationFailed;
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    // ShellLinkHeader (0x4C bytes).
    try put32(w, 0x4C);
    w.writeAll(&link_clsid) catch return error.OutOfMemory;
    try put32(w, has_link_info | has_name | has_working_dir | has_icon_location | is_unicode);
    try put32(w, 0x20); // FILE_ATTRIBUTE_ARCHIVE
    w.splatByteAll(0, 24) catch return error.OutOfMemory; // creation/access/write times
    try put32(w, 0); // file size
    try put32(w, 0); // icon index
    try put32(w, 1); // SW_SHOWNORMAL
    try put16(w, 0); // hotkey
    w.splatByteAll(0, 10) catch return error.OutOfMemory; // reserved

    // LinkInfo with the optional Unicode offsets (header size 0x24).
    const ansi = try arena.dupe(u8, exe);
    for (ansi) |*c| if (c.* >= 0x80) {
        c.* = '_';
    };
    const wide = try wideOf(arena, exe);
    const header: u32 = 0x24;
    const volume_len: u32 = 17;
    const base = header + volume_len;
    const suffix = base + try u32Of(ansi.len + 1);
    const base_unicode = suffix + 1;
    const suffix_unicode = base_unicode + try u32Of((wide.len + 1) * 2);
    const total = suffix_unicode + 2;
    try put32(w, total);
    try put32(w, header);
    try put32(w, 0x1); // VolumeIDAndLocalBasePath
    try put32(w, header); // VolumeIDOffset
    try put32(w, base);
    try put32(w, 0); // CommonNetworkRelativeLinkOffset
    try put32(w, suffix);
    try put32(w, base_unicode);
    try put32(w, suffix_unicode);
    // VolumeID: DRIVE_FIXED, no serial, empty label.
    try put32(w, volume_len);
    try put32(w, 3);
    try put32(w, 0);
    try put32(w, 0x10);
    w.writeByte(0) catch return error.OutOfMemory;
    w.writeAll(ansi) catch return error.OutOfMemory;
    w.writeByte(0) catch return error.OutOfMemory;
    w.writeByte(0) catch return error.OutOfMemory; // CommonPathSuffix ""
    for (wide) |u| try put16(w, u);
    try put16(w, 0);
    try put16(w, 0); // CommonPathSuffixUnicode ""

    try stringData(w, arena, label);
    try stringData(w, arena, working_dir);
    try stringData(w, arena, exe);
    try put32(w, 0); // TerminalBlock
    return out.written();
}

// ---------------------------------------------------------------- shortcuts (file-backed)

fn shortcutSpec(
    h: *const host.Host,
    arena: Allocator,
    request: *const api.IntegrationRequest,
) Error!files.Spec {
    const i = request.integration;
    const base = switch (request.scope) {
        .user => h.options.env.app_data orelse return error.PlatformIntegrationFailed,
        .machine => h.options.env.program_data orelse return error.PlatformIntegrationFailed,
    };
    const file = try std.fmt.allocPrint(arena, "{s}.lnk", .{try names.segment(i.id)});
    const final = try host.joinAbsolute(arena, base, &(programs ++ [_][]const u8{file}));
    const working = try host.executable(arena, '\\', request.root, "");
    const exe = try host.executable(arena, '\\', request.root, i.target);
    return .{
        .final = final,
        .body = .{ .content = try shellLink(arena, exe, working, i.label) },
        .owner = lnk_owner,
    };
}

pub fn machineDirs(h: *const host.Host, arena: Allocator) Error![]const []const u8 {
    const data = h.options.env.program_data orelse return error.PlatformIntegrationFailed;
    return arena.dupe([]const u8, &.{try host.joinAbsolute(arena, data, &programs)});
}

// ---------------------------------------------------------------- junction pointer

extern "kernel32" fn CreateFileW(
    name: [*:0]const u16,
    access: u32,
    share: u32,
    security: ?*anyopaque,
    disposition: u32,
    flags: u32,
    template: ?*anyopaque,
) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn DeviceIoControl(
    handle: windows.HANDLE,
    code: u32,
    in: ?*const anyopaque,
    in_len: u32,
    out: ?*anyopaque,
    out_len: u32,
    returned: ?*u32,
    overlapped: ?*anyopaque,
) callconv(.winapi) c_int;

const FSCTL_SET_REPARSE_POINT: u32 = 0x000900A4;
const IO_REPARSE_TAG_MOUNT_POINT: u32 = 0xA0000003;

/// REPARSE_DATA_BUFFER for a mount point: `\??\<abs>` substitute name, `<abs>` print name.
pub fn junctionData(arena: Allocator, absolute: []const u8) Error![]const u8 {
    const print = try wideOf(arena, absolute);
    const substitute = try wideOf(arena, try std.fmt.allocPrint(arena, "\\??\\{s}", .{absolute}));
    const names_len = (substitute.len + 1 + print.len + 1) * 2;
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try put32(w, IO_REPARSE_TAG_MOUNT_POINT);
    try put16(w, std.math.cast(u16, 8 + names_len) orelse return error.PlatformIntegrationFailed);
    try put16(w, 0);
    try put16(w, 0);
    try put16(
        w,
        std.math.cast(u16, substitute.len * 2) orelse return error.PlatformIntegrationFailed,
    );
    try put16(
        w,
        std.math.cast(u16, (substitute.len + 1) * 2) orelse return error.PlatformIntegrationFailed,
    );
    try put16(w, std.math.cast(u16, print.len * 2) orelse return error.PlatformIntegrationFailed);
    for (substitute) |u| try put16(w, u);
    try put16(w, 0);
    for (print) |u| try put16(w, u);
    try put16(w, 0);
    return out.written();
}

fn makeJunction(arena: Allocator, path: []const u8, absolute: []const u8) Error!void {
    const data = try junctionData(arena, absolute);
    const prefixed = try wideZ(arena, try std.fmt.allocPrint(arena, "\\\\?\\{s}", .{path}));
    const generic_write: u32 = 0x40000000;
    const open_existing: u32 = 3;
    const backup_semantics: u32 = 0x02000000;
    const open_reparse_point: u32 = 0x00200000;
    const handle = CreateFileW(
        prefixed,
        generic_write,
        0,
        null,
        open_existing,
        backup_semantics | open_reparse_point,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) return util.lastError();
    defer windows.CloseHandle(handle);
    var returned: u32 = 0;
    const ok = DeviceIoControl(
        handle,
        FSCTL_SET_REPARSE_POINT,
        data.ptr,
        try u32Of(data.len),
        null,
        0,
        &returned,
        null,
    );
    if (ok == 0) return util.lastError();
}

fn deleteDirIfAny(io: std.Io, path: []const u8) Error!void {
    std.Io.Dir.cwd().deleteDir(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return api.mapFs(err),
    };
}

pub fn setPointer(
    h: *const host.Host,
    arena: Allocator,
    link: []const u8,
    target: []const u8,
) Error!void {
    const io = h.local.io;
    const dir = std.fs.path.dirnameWindows(link) orelse return error.FsIo;
    const relative = try arena.dupe(u8, target);
    std.mem.replaceScalar(u8, relative, '/', '\\');
    const absolute = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ dir, relative });
    const next = try std.fmt.allocPrint(arena, "{s}.next", .{link});
    const old = try std.fmt.allocPrint(arena, "{s}.old", .{link});
    try deleteDirIfAny(io, next);
    try h.local.createDirPath(next);
    try makeJunction(arena, next, absolute);
    try deleteDirIfAny(io, old);
    h.local.rename(link, old) catch |err| switch (err) {
        error.FsNotFound => {},
        else => return err,
    };
    try h.local.rename(next, link);
    try deleteDirIfAny(io, old);
}

// ---------------------------------------------------------------- dispatch

pub fn prepare(
    h: *const host.Host,
    arena: Allocator,
    request: *const api.IntegrationRequest,
) Error!void {
    switch (request.integration.kind) {
        .shortcut => return files.prepare(h.local, try shortcutSpec(h, arena, request), request.tx),
        // Registry and SCM entries are written at activation; validate names now.
        .file_association => {
            const prog = try registry.progId(
                arena,
                try names.token(request.product_id),
                try names.extension(request.integration.id),
            );
            std.debug.assert(prog.len > 0);
            if (!h.options.system_managers) return error.CapabilityUnsupported;
        },
        .registration => {
            const target = try names.target(request.integration.target);
            std.debug.assert(target.len > 0);
            if (!h.options.system_managers) return error.CapabilityUnsupported;
        },
        .service => {
            if (request.scope != .machine or !h.options.system_managers) {
                return error.CapabilityUnsupported;
            }
            const name = try service.serviceName(arena, request.product_id, request.integration.id);
            std.debug.assert(name.len > 0);
        },
    }
}

pub fn discard(
    h: *const host.Host,
    arena: Allocator,
    request: *const api.IntegrationRequest,
) Error!void {
    if (request.integration.kind != .shortcut) return;
    return files.discard(h.local, (try shortcutSpec(h, arena, request)).final, request.tx);
}

pub fn activate(
    h: *const host.Host,
    arena: Allocator,
    request: *const api.IntegrationRequest,
) Error![]const u8 {
    if (request.integration.kind == .shortcut) {
        const s = try shortcutSpec(h, arena, request);
        try files.activate(h.local, s, request.tx);
        return arena.dupe(u8, s.final);
    }
    if (!h.options.system_managers) return error.CapabilityUnsupported;
    if (builtin.os.tag != .windows) return error.CapabilityUnsupported;
    return switch (request.integration.kind) {
        .file_association => registry.activateAssociation(arena, request),
        .registration => registry.activateRegistration(arena, request),
        .service => service.activateService(arena, request),
        .shortcut => unreachable,
    };
}

pub fn remove(
    h: *const host.Host,
    arena: Allocator,
    installed: contracts.installation.Integration,
) Error!void {
    if (installed.kind == .shortcut) return files.remove(h.local, installed.location, lnk_owner);
    if (!h.options.system_managers) return error.CapabilityUnsupported;
    if (builtin.os.tag != .windows) return error.CapabilityUnsupported;
    return switch (installed.kind) {
        .file_association => registry.removeAssociation(arena, installed),
        .registration => registry.removeRegistration(arena, installed),
        .service => service.removeService(arena, installed),
        .shortcut => unreachable,
    };
}

test "shell link layout" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const exe = "C:\\Users\\a\\AppData\\Local\\Programs\\hello\\current\\bin\\hello.exe";
    const working = "C:\\Users\\a\\AppData\\Local\\Programs\\hello\\current";
    const bytes = try shellLink(a, exe, working, "Hello");
    try std.testing.expectEqual(@as(u32, 0x4C), std.mem.readInt(u32, bytes[0..4], .little));
    try std.testing.expectEqualSlices(u8, &link_clsid, bytes[4..20]);
    const info_size = std.mem.readInt(u32, bytes[0x4C..][0..4], .little);
    try std.testing.expectEqual(@as(u32, 0x24), std.mem.readInt(u32, bytes[0x50..][0..4], .little));
    const ansi_at = 0x4C + std.mem.readInt(u32, bytes[0x4C + 16 ..][0..4], .little);
    try std.testing.expectEqualStrings(exe, std.mem.sliceTo(bytes[ansi_at..], 0));
    try std.testing.expectEqual(
        @as(u32, 0),
        std.mem.readInt(u32, bytes[bytes.len - 4 ..][0..4], .little),
    );
    try std.testing.expect(info_size < bytes.len);
    var probe: [64]u8 = undefined; // SAFETY: only probe[0 .. lnk_owner.len * 2] is read.
    for (lnk_owner, 0..) |c, i| {
        probe[i * 2] = c;
        probe[i * 2 + 1] = 0;
    }
    try std.testing.expect(std.mem.find(u8, bytes, probe[0 .. lnk_owner.len * 2]) != null);
}

test "junction reparse buffer" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const data = try junctionData(arena.allocator(), "C:\\p\\versions\\2");
    try std.testing.expectEqual(
        IO_REPARSE_TAG_MOUNT_POINT,
        std.mem.readInt(u32, data[0..4], .little),
    );
    const length = std.mem.readInt(u16, data[4..6], .little);
    try std.testing.expectEqual(data.len - 8, length);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, data[8..10], .little));
}
