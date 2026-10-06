//! Platform capability interface (docs/spec/platform-contract-v1.md). Only mutations go through
//! it: reads of install roots are unprivileged and use std.Io directly. Every method maps onto
//! the closed privilege IPC op set (docs/spec/ipc-v1.md), so the privilege broker is just another
//! implementation. Paths are absolute; callers build them from validated relative parts.

const std = @import("std");
const contracts = @import("contracts");

pub const Error = error{
    FsNoSpace,
    FsAccessDenied,
    FsSharingViolation,
    FsNotFound,
    FsIo,
    CapabilityUnsupported,
    PlatformIntegrationFailed,
    /// VirtualPlatform kill point: the simulated process is dead; do not clean up.
    PlatformKilled,
    PrivilegeHelperLost,
    Canceled,
    OutOfMemory,
};

pub const Os = enum {
    macos,
    windows,
    linux,

    pub fn of(platform: contracts.Platform) Os {
        return switch (platform) {
            .@"macos-aarch64", .@"macos-x86_64" => .macos,
            .@"windows-x86_64", .@"windows-aarch64" => .windows,
            .@"linux-x86_64", .@"linux-aarch64" => .linux,
        };
    }

    pub fn separator(os: Os) u8 {
        return if (os == .windows) '\\' else '/';
    }
};

/// Process environment values the framework derives paths from; read once by `apps/*` and
/// overridden in tests so nothing touches the real home directory.
pub const Env = struct {
    /// `HOME` (POSIX) or `USERPROFILE` (Windows).
    home: ?[]const u8 = null,
    local_app_data: ?[]const u8 = null,
    /// Roaming `%APPDATA%` (Start Menu shortcuts).
    app_data: ?[]const u8 = null,
    program_files: ?[]const u8 = null,
    program_data: ?[]const u8 = null,
    xdg_data_home: ?[]const u8 = null,
    xdg_config_home: ?[]const u8 = null,
    xdg_cache_home: ?[]const u8 = null,
};

pub const IntegrationRequest = struct {
    integration: contracts.plan.Integration,
    product_id: []const u8,
    product_name: []const u8,
    scope: contracts.Scope,
    /// Absolute install root; executables resolve through `<root>/current/<target>`.
    root: []const u8,
    tx: u64,
};

pub const VTable = struct {
    createDirPath: *const fn (*anyopaque, []const u8) Error!void,
    /// Atomic replace (temp + fsync + rename).
    writeFile: *const fn (*anyopaque, []const u8, []const u8, bool) Error!void,
    /// Durable append (journal records).
    appendFile: *const fn (*anyopaque, []const u8, []const u8) Error!void,
    /// Atomic replace of `target` with the bytes of `source`.
    copyFile: *const fn (*anyopaque, []const u8, []const u8, bool) Error!void,
    rename: *const fn (*anyopaque, []const u8, []const u8) Error!void,
    /// Missing paths are not an error.
    deleteFile: *const fn (*anyopaque, []const u8) Error!void,
    deleteTree: *const fn (*anyopaque, []const u8) Error!void,
    /// Atomically point `link` at `target` (relative to the link's directory).
    setPointer: *const fn (*anyopaque, []const u8, []const u8) Error!void,
    deletePointer: *const fn (*anyopaque, []const u8) Error!void,
    prepareIntegration: *const fn (*anyopaque, *const IntegrationRequest) Error!void,
    discardIntegration: *const fn (*anyopaque, *const IntegrationRequest) Error!void,
    /// Idempotent; returns the platform location recorded in installation.json.
    activateIntegration: *const fn (
        *anyopaque,
        std.mem.Allocator,
        *const IntegrationRequest,
    ) Error![]const u8,
    removeIntegration: *const fn (*anyopaque, contracts.installation.Integration) Error!void,
    /// Bytes available on the volume of `path` (or its nearest existing ancestor).
    freeSpace: *const fn (*anyopaque, []const u8) Error!u64,
    now: *const fn (*anyopaque) i64,
};

pub const Platform = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub fn createDirPath(p: Platform, path: []const u8) Error!void {
        return p.vtable.createDirPath(p.ptr, path);
    }

    pub fn writeFile(
        p: Platform,
        path: []const u8,
        bytes: []const u8,
        executable: bool,
    ) Error!void {
        return p.vtable.writeFile(p.ptr, path, bytes, executable);
    }

    pub fn appendFile(p: Platform, path: []const u8, bytes: []const u8) Error!void {
        return p.vtable.appendFile(p.ptr, path, bytes);
    }

    pub fn copyFile(
        p: Platform,
        source: []const u8,
        target: []const u8,
        executable: bool,
    ) Error!void {
        return p.vtable.copyFile(p.ptr, source, target, executable);
    }

    pub fn rename(p: Platform, from: []const u8, to: []const u8) Error!void {
        return p.vtable.rename(p.ptr, from, to);
    }

    pub fn deleteFile(p: Platform, path: []const u8) Error!void {
        return p.vtable.deleteFile(p.ptr, path);
    }

    pub fn deleteTree(p: Platform, path: []const u8) Error!void {
        return p.vtable.deleteTree(p.ptr, path);
    }

    pub fn setPointer(p: Platform, link: []const u8, target: []const u8) Error!void {
        return p.vtable.setPointer(p.ptr, link, target);
    }

    pub fn deletePointer(p: Platform, link: []const u8) Error!void {
        return p.vtable.deletePointer(p.ptr, link);
    }

    pub fn prepareIntegration(p: Platform, request: *const IntegrationRequest) Error!void {
        return p.vtable.prepareIntegration(p.ptr, request);
    }

    pub fn discardIntegration(p: Platform, request: *const IntegrationRequest) Error!void {
        return p.vtable.discardIntegration(p.ptr, request);
    }

    pub fn activateIntegration(
        p: Platform,
        arena: std.mem.Allocator,
        request: *const IntegrationRequest,
    ) Error![]const u8 {
        return p.vtable.activateIntegration(p.ptr, arena, request);
    }

    pub fn removeIntegration(
        p: Platform,
        installed: contracts.installation.Integration,
    ) Error!void {
        return p.vtable.removeIntegration(p.ptr, installed);
    }

    pub fn freeSpace(p: Platform, path: []const u8) Error!u64 {
        return p.vtable.freeSpace(p.ptr, path);
    }

    pub fn now(p: Platform) i64 {
        return p.vtable.now(p.ptr);
    }
};

/// Maps std filesystem errors onto the platform error set.
// lint-allow(no-anyerror-pub): adapter that accepts every std filesystem error set.
pub fn mapFs(err: anyerror) Error {
    return switch (err) {
        error.NoSpaceLeft, error.DiskQuota => error.FsNoSpace,
        error.AccessDenied,
        error.PermissionDenied,
        error.ReadOnlyFileSystem,
        => error.FsAccessDenied,
        error.FileBusy, error.SharingViolation, error.DeviceBusy => error.FsSharingViolation,
        error.FileNotFound => error.FsNotFound,
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.FsIo,
    };
}
