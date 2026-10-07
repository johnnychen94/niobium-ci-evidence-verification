//! Windows registry integrations (docs/spec/platform-contract-v1.md#windows): file associations
//! (ProgID `<product>.<ext>` plus `.<ext>\OpenWithProgids`) and the Uninstall registration.
//! Keys carry `NiobiumManaged`; foreign ones are refused.

const std = @import("std");
const contracts = @import("contracts");
const api = @import("api.zig");
const host = @import("host.zig");
const names = @import("names.zig");
const util = @import("windows_util.zig");

const Error = api.Error;
const Allocator = std.mem.Allocator;
const u32Of = util.u32Of;
const wideZ = util.wideZ;
const quoted = util.quoted;

const managed_value = "NiobiumManaged";

const HKEY = *opaque {};
const KEY_READ: u32 = 0x20019;
const KEY_WRITE: u32 = 0x20006;
const KEY_WOW64_64KEY: u32 = 0x0100;
const REG_SZ: u32 = 1;
const REG_DWORD: u32 = 4;
const RRF_RT_REG_SZ: u32 = 0x2;
const ERROR_FILE_NOT_FOUND: i32 = 2;
const ERROR_ACCESS_DENIED: i32 = 5;
const ERROR_MORE_DATA: i32 = 234;

extern "advapi32" fn RegCreateKeyExW(
    key: HKEY,
    sub_key: [*:0]const u16,
    reserved: u32,
    class: ?[*:0]const u16,
    options: u32,
    sam: u32,
    security: ?*anyopaque,
    result: *HKEY,
    disposition: ?*u32,
) callconv(.winapi) i32;
extern "advapi32" fn RegSetValueExW(
    key: HKEY,
    name: ?[*:0]const u16,
    reserved: u32,
    kind: u32,
    data: [*]const u8,
    len: u32,
) callconv(.winapi) i32;
extern "advapi32" fn RegGetValueW(
    key: HKEY,
    sub_key: ?[*:0]const u16,
    name: ?[*:0]const u16,
    flags: u32,
    kind: ?*u32,
    data: ?*anyopaque,
    len: ?*u32,
) callconv(.winapi) i32;
extern "advapi32" fn RegDeleteTreeW(key: HKEY, sub_key: ?[*:0]const u16) callconv(.winapi) i32;
extern "advapi32" fn RegDeleteKeyValueW(
    key: HKEY,
    sub_key: ?[*:0]const u16,
    name: ?[*:0]const u16,
) callconv(.winapi) i32;
extern "advapi32" fn RegCloseKey(key: HKEY) callconv(.winapi) i32;

const Hive = enum {
    HKCU,
    HKLM,

    fn of(scope: contracts.Scope) Hive {
        return if (scope == .user) .HKCU else .HKLM;
    }

    fn handle(hive: Hive) HKEY {
        // Winreg.h casts through signed LONG before ULONG_PTR, including on 64-bit hosts.
        const value: isize = if (hive == .HKCU) -0x7fff_ffff else -0x7fff_fffe;
        return @ptrFromInt(@as(usize, @bitCast(value)));
    }

    /// `HKCU\<key>` / `HKLM\<key>` as recorded in installation.json.
    fn parse(location: []const u8) Error!struct { hive: Hive, key: []const u8 } {
        inline for (.{ Hive.HKCU, Hive.HKLM }) |hive| {
            const prefix = @tagName(hive) ++ "\\";
            if (std.mem.startsWith(u8, location, prefix)) {
                return .{ .hive = hive, .key = location[prefix.len..] };
            }
        }
        return error.PlatformIntegrationFailed;
    }
};

test "N1-AC-14 predefined registry handles match the Windows SDK signed LONG conversion" {
    const high: usize = if (@sizeOf(usize) == 8) 0xffff_ffff_0000_0000 else 0;
    try std.testing.expectEqual(high | 0x80000001, @intFromPtr(Hive.HKCU.handle()));
    try std.testing.expectEqual(high | 0x80000002, @intFromPtr(Hive.HKLM.handle()));
}

fn regError(rc: i32) Error {
    return if (rc == ERROR_ACCESS_DENIED) error.FsAccessDenied else error.PlatformIntegrationFailed;
}

const Value = union(enum) { string: []const u8, dword: u32 };

fn setValue(
    arena: Allocator,
    hive: Hive,
    key: []const u8,
    name: ?[]const u8,
    value: Value,
) Error!void {
    // SAFETY: written by RegCreateKeyExW on success.
    var handle: HKEY = undefined;
    const sam = KEY_WRITE | KEY_WOW64_64KEY;
    const rc = RegCreateKeyExW(
        hive.handle(),
        try wideZ(arena, key),
        0,
        null,
        0,
        sam,
        null,
        &handle,
        null,
    );
    if (rc != 0) return regError(rc);
    // lint-allow(no-discard-call): closing a key cannot be meaningfully handled.
    defer _ = RegCloseKey(handle);
    const value_name = if (name) |n| (try wideZ(arena, n)).ptr else null;
    const set = switch (value) {
        .string => |text| blk: {
            const data = try wideZ(arena, text);
            const bytes = std.mem.sliceAsBytes(data.ptr[0 .. data.len + 1]);
            break :blk RegSetValueExW(
                handle,
                value_name,
                0,
                REG_SZ,
                bytes.ptr,
                try u32Of(bytes.len),
            );
        },
        .dword => |number| blk: {
            const bytes = std.mem.asBytes(&number);
            break :blk RegSetValueExW(handle, value_name, 0, REG_DWORD, bytes.ptr, 4);
        },
    };
    if (set != 0) return regError(set);
}

fn getString(arena: Allocator, hive: Hive, key: []const u8, name: ?[]const u8) Error!?[]const u8 {
    const key_w = try wideZ(arena, key);
    const name_w = if (name) |n| (try wideZ(arena, n)).ptr else null;
    var len: u32 = 0;
    var rc = RegGetValueW(hive.handle(), key_w, name_w, RRF_RT_REG_SZ, null, null, &len);
    if (rc == ERROR_FILE_NOT_FOUND) return null;
    if (rc != 0 and rc != ERROR_MORE_DATA) return regError(rc);
    const units = try arena.alloc(u16, len / 2 + 1);
    var size: u32 = try u32Of(units.len * 2);
    rc = RegGetValueW(hive.handle(), key_w, name_w, RRF_RT_REG_SZ, null, units.ptr, &size);
    if (rc == ERROR_FILE_NOT_FOUND) return null;
    if (rc != 0) return regError(rc);
    const text = std.mem.sliceTo(units, 0);
    return std.unicode.wtf16LeToWtf8Alloc(arena, text) catch error.OutOfMemory;
}

fn deleteTree(arena: Allocator, hive: Hive, key: []const u8) Error!void {
    const rc = RegDeleteTreeW(hive.handle(), try wideZ(arena, key));
    if (rc != 0 and rc != ERROR_FILE_NOT_FOUND) return regError(rc);
}

fn deleteValue(arena: Allocator, hive: Hive, key: []const u8, name: ?[]const u8) Error!void {
    const name_w = if (name) |n| (try wideZ(arena, n)).ptr else null;
    const rc = RegDeleteKeyValueW(hive.handle(), try wideZ(arena, key), name_w);
    if (rc != 0 and rc != ERROR_FILE_NOT_FOUND) return regError(rc);
}

fn owned(arena: Allocator, hive: Hive, key: []const u8) Error!bool {
    return try getString(arena, hive, key, managed_value) != null;
}

pub fn progId(arena: Allocator, product_id: []const u8, ext: []const u8) Error![]const u8 {
    return names.token(try std.fmt.allocPrint(arena, "{s}.{s}", .{ product_id, ext }));
}

pub fn activateAssociation(
    arena: Allocator,
    request: *const api.IntegrationRequest,
) Error![]const u8 {
    const i = request.integration;
    const hive: Hive = .of(request.scope);
    const ext = try names.extension(i.id);
    const prog = try progId(arena, try names.token(request.product_id), ext);
    const exe = try quoted(arena, try host.executable(arena, '\\', request.root, i.target));
    const prog_key = try std.fmt.allocPrint(arena, "Software\\Classes\\{s}", .{prog});
    const ext_key = try std.fmt.allocPrint(arena, "Software\\Classes\\.{s}", .{ext});
    try setValue(arena, hive, prog_key, null, .{ .string = i.label });
    try setValue(arena, hive, prog_key, managed_value, .{ .string = request.product_id });
    const icon = try std.fmt.allocPrint(arena, "{s},0", .{exe});
    const icon_key = try std.fmt.allocPrint(arena, "{s}\\DefaultIcon", .{prog_key});
    try setValue(arena, hive, icon_key, null, .{ .string = icon });
    const open = try std.fmt.allocPrint(arena, "{s}\\shell\\open\\command", .{prog_key});
    try setValue(
        arena,
        hive,
        open,
        null,
        .{ .string = try std.fmt.allocPrint(arena, "{s} \"%1\"", .{exe}) },
    );
    const with = try std.fmt.allocPrint(arena, "{s}\\OpenWithProgids", .{ext_key});
    try setValue(arena, hive, with, prog, .{ .string = "" });
    const current = try getString(arena, hive, ext_key, null);
    if (current == null or current.?.len == 0 or std.mem.eql(u8, current.?, prog)) {
        try setValue(arena, hive, ext_key, null, .{ .string = prog });
    }
    return std.fmt.allocPrint(arena, "{t}\\{s}", .{ hive, prog_key });
}

pub fn removeAssociation(
    arena: Allocator,
    installed: contracts.installation.Integration,
) Error!void {
    const where = try Hive.parse(installed.location);
    if (!try owned(arena, where.hive, where.key)) {
        if (try getString(arena, where.hive, where.key, null) == null) return;
        return error.PlatformIntegrationFailed;
    }
    const prog = std.fs.path.basenameWindows(where.key);
    const ext = try names.extension(installed.id);
    const ext_key = try std.fmt.allocPrint(arena, "Software\\Classes\\.{s}", .{ext});
    const with = try std.fmt.allocPrint(arena, "{s}\\OpenWithProgids", .{ext_key});
    try deleteValue(arena, where.hive, with, prog);
    if (try getString(arena, where.hive, ext_key, null)) |current| {
        if (std.mem.eql(u8, current, prog)) try deleteValue(arena, where.hive, ext_key, null);
    }
    try deleteTree(arena, where.hive, where.key);
}

const uninstall_key = "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\";

pub fn activateRegistration(
    arena: Allocator,
    request: *const api.IntegrationRequest,
) Error![]const u8 {
    const hive: Hive = .of(request.scope);
    const key = try std.fmt.allocPrint(
        arena,
        uninstall_key ++ "{s}",
        .{try names.token(request.product_id)},
    );
    if (!try owned(arena, hive, key) and try getString(arena, hive, key, "DisplayName") != null) {
        return error.PlatformIntegrationFailed;
    }
    const target = try arena.dupe(u8, try names.target(request.integration.target));
    std.mem.replaceScalar(u8, target, '/', '\\');
    const maintainer_path = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ request.root, target });
    const maintainer = try quoted(arena, maintainer_path);
    const args = try std.fmt.allocPrint(
        arena,
        "{s} uninstall --product {s} --scope {t}",
        .{ maintainer, request.product_id, request.scope },
    );
    try setValue(arena, hive, key, "DisplayName", .{ .string = request.product_name });
    try setValue(arena, hive, key, "InstallLocation", .{ .string = request.root });
    try setValue(arena, hive, key, "UninstallString", .{ .string = args });
    const quiet = try std.fmt.allocPrint(arena, "{s} --silent", .{args});
    try setValue(arena, hive, key, "QuietUninstallString", .{ .string = quiet });
    try setValue(arena, hive, key, "DisplayIcon", .{ .string = maintainer });
    try setValue(arena, hive, key, "NoModify", .{ .dword = 1 });
    try setValue(arena, hive, key, "NoRepair", .{ .dword = 1 });
    try setValue(arena, hive, key, managed_value, .{ .string = request.product_id });
    return std.fmt.allocPrint(arena, "{t}\\{s}", .{ hive, key });
}

pub fn removeRegistration(
    arena: Allocator,
    installed: contracts.installation.Integration,
) Error!void {
    const where = try Hive.parse(installed.location);
    if (!try owned(arena, where.hive, where.key)) {
        if (try getString(arena, where.hive, where.key, "DisplayName") == null) return;
        return error.PlatformIntegrationFailed;
    }
    try deleteTree(arena, where.hive, where.key);
}
