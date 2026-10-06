//! Windows services through the SCM (docs/spec/platform-contract-v1.md#windows), machine scope
//! only. Names are `<product>.<id>`; locations are recorded as `scm:<name>`.

const std = @import("std");
const contracts = @import("contracts");
const api = @import("api.zig");
const host = @import("host.zig");
const names = @import("names.zig");
const util = @import("windows_util.zig");

const Error = api.Error;
const Allocator = std.mem.Allocator;
const windows = std.os.windows;
const wideZ = util.wideZ;
const quoted = util.quoted;
const scmError = util.lastError;

const SC_HANDLE = *opaque {};
const SC_MANAGER_CONNECT: u32 = 0x1;
const SC_MANAGER_CREATE_SERVICE: u32 = 0x2;
const SERVICE_ALL_ACCESS: u32 = 0xF01FF;
const SERVICE_WIN32_OWN_PROCESS: u32 = 0x10;
const SERVICE_AUTO_START: u32 = 2;
const SERVICE_DEMAND_START: u32 = 3;
const SERVICE_ERROR_NORMAL: u32 = 1;
const SERVICE_CONTROL_STOP: u32 = 1;
const ServiceStatus = extern struct { words: [7]u32 = @splat(0) };

extern "advapi32" fn OpenSCManagerW(
    machine: ?[*:0]const u16,
    db: ?[*:0]const u16,
    access: u32,
) callconv(.winapi) ?SC_HANDLE;
extern "advapi32" fn CreateServiceW(
    scm: SC_HANDLE,
    name: [*:0]const u16,
    display: [*:0]const u16,
    access: u32,
    kind: u32,
    start: u32,
    error_control: u32,
    path: [*:0]const u16,
    group: ?[*:0]const u16,
    tag: ?*u32,
    dependencies: ?[*:0]const u16,
    user: ?[*:0]const u16,
    password: ?[*:0]const u16,
) callconv(.winapi) ?SC_HANDLE;
extern "advapi32" fn OpenServiceW(
    scm: SC_HANDLE,
    name: [*:0]const u16,
    access: u32,
) callconv(.winapi) ?SC_HANDLE;
extern "advapi32" fn ChangeServiceConfigW(
    service: SC_HANDLE,
    kind: u32,
    start: u32,
    error_control: u32,
    path: ?[*:0]const u16,
    group: ?[*:0]const u16,
    tag: ?*u32,
    dependencies: ?[*:0]const u16,
    user: ?[*:0]const u16,
    password: ?[*:0]const u16,
    display: ?[*:0]const u16,
) callconv(.winapi) c_int;
extern "advapi32" fn StartServiceW(
    service: SC_HANDLE,
    argc: u32,
    argv: ?*anyopaque,
) callconv(.winapi) c_int;
extern "advapi32" fn ControlService(
    service: SC_HANDLE,
    control: u32,
    status: *ServiceStatus,
) callconv(.winapi) c_int;
extern "advapi32" fn DeleteService(service: SC_HANDLE) callconv(.winapi) c_int;
extern "advapi32" fn CloseServiceHandle(handle: SC_HANDLE) callconv(.winapi) c_int;

pub fn serviceName(arena: Allocator, product_id: []const u8, id: []const u8) Error![]const u8 {
    return names.token(try std.fmt.allocPrint(arena, "{s}.{s}", .{ product_id, id }));
}

fn openManager() Error!SC_HANDLE {
    return OpenSCManagerW(
        null,
        null,
        SC_MANAGER_CONNECT | SC_MANAGER_CREATE_SERVICE,
    ) orelse scmError();
}

pub fn activateService(arena: Allocator, request: *const api.IntegrationRequest) Error![]const u8 {
    if (request.scope != .machine) return error.CapabilityUnsupported;
    const i = request.integration;
    const name = try serviceName(arena, request.product_id, i.id);
    const name_w = try wideZ(arena, name);
    const display_w = try wideZ(arena, i.label);
    const exe = try host.executable(arena, '\\', request.root, i.target);
    const path_w = try wideZ(arena, try quoted(arena, exe));
    const start: u32 = if (i.start == .auto) SERVICE_AUTO_START else SERVICE_DEMAND_START;
    const scm = try openManager();
    // lint-allow(no-discard-call): closing an SCM handle cannot be meaningfully handled.
    defer _ = CloseServiceHandle(scm);
    const service = CreateServiceW(
        scm,
        name_w,
        display_w,
        SERVICE_ALL_ACCESS,
        SERVICE_WIN32_OWN_PROCESS,
        start,
        SERVICE_ERROR_NORMAL,
        path_w,
        null,
        null,
        null,
        null,
        null,
    ) orelse blk: {
        if (windows.GetLastError() != .SERVICE_EXISTS) return scmError();
        const existing = OpenServiceW(scm, name_w, SERVICE_ALL_ACCESS) orelse return scmError();
        const changed = ChangeServiceConfigW(
            existing,
            SERVICE_WIN32_OWN_PROCESS,
            start,
            SERVICE_ERROR_NORMAL,
            path_w,
            null,
            null,
            null,
            null,
            null,
            display_w,
        );
        if (changed == 0) {
            // lint-allow(no-discard-call): the change error is the one reported.
            _ = CloseServiceHandle(existing);
            return scmError();
        }
        break :blk existing;
    };
    // lint-allow(no-discard-call): closing a service handle cannot be meaningfully handled.
    defer _ = CloseServiceHandle(service);
    if (i.start == .auto and StartServiceW(service, 0, null) == 0) {
        if (windows.GetLastError() != .SERVICE_ALREADY_RUNNING) return scmError();
    }
    return std.fmt.allocPrint(arena, "scm:{s}", .{name});
}

pub fn removeService(arena: Allocator, installed: contracts.installation.Integration) Error!void {
    if (!std.mem.startsWith(u8, installed.location, "scm:")) return error.PlatformIntegrationFailed;
    const name = try names.token(installed.location["scm:".len..]);
    const scm = try openManager();
    // lint-allow(no-discard-call): closing an SCM handle cannot be meaningfully handled.
    defer _ = CloseServiceHandle(scm);
    const service = OpenServiceW(scm, try wideZ(arena, name), SERVICE_ALL_ACCESS) orelse {
        if (windows.GetLastError() == .SERVICE_DOES_NOT_EXIST) return;
        return scmError();
    };
    // lint-allow(no-discard-call): closing a service handle cannot be meaningfully handled.
    defer _ = CloseServiceHandle(service);
    var status: ServiceStatus = .{};
    // lint-allow(no-discard-call): a stopped service rejects STOP; deletion proceeds regardless.
    _ = ControlService(service, SERVICE_CONTROL_STOP, &status);
    if (DeleteService(service) == 0 and windows.GetLastError() != .SERVICE_MARKED_FOR_DELETE) {
        return scmError();
    }
}
