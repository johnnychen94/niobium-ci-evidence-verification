//! Host platform backend: Local filesystem mutations plus the native integrations of the OS
//! the binary was compiled for (macos.zig, linux.zig, windows.zig). All system locations derive
//! from injected `Options`, so the PlatformContract suite runs it inside a temp directory.

const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts");
const api = @import("api.zig");
const local = @import("local.zig");
const names = @import("names.zig");

const Error = api.Error;
const Allocator = std.mem.Allocator;

const native = switch (builtin.os.tag) {
    .macos => @import("macos.zig"),
    .windows => @import("windows.zig"),
    else => @import("linux.zig"),
};

pub const Options = struct {
    env: api.Env,
    /// Prefix for machine-scope system directories (`/Applications`, `/etc/systemd/system`,
    /// `/usr/local/share`). Empty in production; a temp directory in contract tests.
    machine_root: []const u8 = "",
    /// Talk to system managers (launchctl, systemctl, desktop caches, the Windows registry and
    /// SCM). Off in contract tests: file-backed integrations are still written, and
    /// integrations that exist only inside a system manager report CapabilityUnsupported.
    system_managers: bool = true,
};

/// Scratch space for vtable calls that do not receive an arena (paths and small file bodies).
const scratch_bytes = 64 * 1024;

pub const Host = struct {
    local: local.Local,
    options: Options,

    pub fn init(io: std.Io, options: Options) Host {
        return .{ .local = .{ .io = io }, .options = options };
    }

    pub fn platform(h: *Host) api.Platform {
        return .{ .ptr = h, .vtable = &vtable };
    }

    /// `<home>/<parts…>`; integrations without a home directory cannot be placed.
    pub fn userPath(h: *const Host, arena: Allocator, parts: []const []const u8) Error![]const u8 {
        const home = h.options.env.home orelse return error.PlatformIntegrationFailed;
        return joinAbsolute(arena, home, parts);
    }

    /// `<machine_root>/<parts…>`, i.e. `/<parts…>` in production (POSIX).
    pub fn systemPath(
        h: *const Host,
        arena: Allocator,
        parts: []const []const u8,
    ) Error![]const u8 {
        const base = if (h.options.machine_root.len == 0) "/" else h.options.machine_root;
        return joinAbsolute(arena, base, parts);
    }

    pub fn scoped(
        h: *const Host,
        arena: Allocator,
        scope: contracts.Scope,
        parts: []const []const u8,
    ) Error![]const u8 {
        return switch (scope) {
            .user => h.userPath(arena, parts),
            .machine => h.systemPath(arena, parts),
        };
    }

    /// Directories machine-scope integration files are written into (the privilege helper's
    /// policy). Registry keys and SCM services have no file location and are not listed.
    pub fn machineIntegrationDirs(h: *const Host, arena: Allocator) Error![]const []const u8 {
        return native.machineDirs(h, arena);
    }

    /// Whether a recorded location belongs to machine scope (outside the user's home).
    pub fn isSystem(h: *const Host, location: []const u8) bool {
        if (h.options.machine_root.len > 0) {
            return std.mem.startsWith(u8, location, h.options.machine_root);
        }
        const home = h.options.env.home orelse return true;
        return !std.mem.startsWith(u8, location, home);
    }

    const vtable: api.VTable = .{
        .createDirPath = createDirPath,
        .writeFile = writeFile,
        .appendFile = appendFile,
        .copyFile = copyFile,
        .rename = rename,
        .deleteFile = deleteFile,
        .deleteTree = deleteTree,
        .setPointer = setPointer,
        .deletePointer = deletePointer,
        .prepareIntegration = prepareIntegration,
        .discardIntegration = discardIntegration,
        .activateIntegration = activateIntegration,
        .removeIntegration = removeIntegration,
        .freeSpace = freeSpace,
        .now = now,
    };

    fn self(ptr: *anyopaque) *Host {
        return @ptrCast(@alignCast(ptr));
    }

    fn createDirPath(ptr: *anyopaque, path: []const u8) Error!void {
        return self(ptr).local.createDirPath(path);
    }

    fn writeFile(
        ptr: *anyopaque,
        path: []const u8,
        bytes: []const u8,
        executable_bit: bool,
    ) Error!void {
        return self(ptr).local.writeFile(path, bytes, executable_bit);
    }

    fn appendFile(ptr: *anyopaque, path: []const u8, bytes: []const u8) Error!void {
        return self(ptr).local.appendFile(path, bytes);
    }

    fn copyFile(
        ptr: *anyopaque,
        source: []const u8,
        target: []const u8,
        executable_bit: bool,
    ) Error!void {
        return self(ptr).local.copyFile(source, target, executable_bit);
    }

    fn rename(ptr: *anyopaque, from: []const u8, to: []const u8) Error!void {
        return self(ptr).local.rename(from, to);
    }

    fn deleteFile(ptr: *anyopaque, path: []const u8) Error!void {
        return self(ptr).local.deleteFile(path);
    }

    fn deleteTree(ptr: *anyopaque, path: []const u8) Error!void {
        return self(ptr).local.deleteTree(path);
    }

    fn setPointer(ptr: *anyopaque, link: []const u8, target: []const u8) Error!void {
        const h = self(ptr);
        if (comptime builtin.os.tag == .windows) {
            var buffer: [scratch_bytes]u8 = undefined; // SAFETY: used only through the FBA.
            var fba: std.heap.FixedBufferAllocator = .init(&buffer);
            return native.setPointer(h, fba.allocator(), link, target);
        }
        return h.local.setPointer(link, target);
    }

    fn deletePointer(ptr: *anyopaque, link: []const u8) Error!void {
        return self(ptr).local.deletePointer(link);
    }

    fn prepareIntegration(ptr: *anyopaque, request: *const api.IntegrationRequest) Error!void {
        var buffer: [scratch_bytes]u8 = undefined; // SAFETY: used only through the FBA.
        var fba: std.heap.FixedBufferAllocator = .init(&buffer);
        return native.prepare(self(ptr), fba.allocator(), request);
    }

    fn discardIntegration(ptr: *anyopaque, request: *const api.IntegrationRequest) Error!void {
        var buffer: [scratch_bytes]u8 = undefined; // SAFETY: used only through the FBA.
        var fba: std.heap.FixedBufferAllocator = .init(&buffer);
        return native.discard(self(ptr), fba.allocator(), request);
    }

    fn activateIntegration(
        ptr: *anyopaque,
        arena: Allocator,
        request: *const api.IntegrationRequest,
    ) Error![]const u8 {
        return native.activate(self(ptr), arena, request);
    }

    fn removeIntegration(
        ptr: *anyopaque,
        installed: contracts.installation.Integration,
    ) Error!void {
        var buffer: [scratch_bytes]u8 = undefined; // SAFETY: used only through the FBA.
        var fba: std.heap.FixedBufferAllocator = .init(&buffer);
        return native.remove(self(ptr), fba.allocator(), installed);
    }

    fn freeSpace(ptr: *anyopaque, path: []const u8) Error!u64 {
        return self(ptr).local.freeSpace(path);
    }

    fn now(ptr: *anyopaque) i64 {
        return std.Io.Clock.real.now(self(ptr).local.io).toSeconds();
    }
};

/// `base` joined with parts using the host separator. Parts from manifests are validated by
/// the caller (names.zig); here only traversal and separators are refused.
pub fn joinAbsolute(
    arena: Allocator,
    base: []const u8,
    parts: []const []const u8,
) Error![]const u8 {
    if (!std.fs.path.isAbsolute(base)) return error.PlatformIntegrationFailed;
    const all = try arena.alloc([]const u8, parts.len + 1);
    all[0] = base;
    for (parts, 1..) |part, i| {
        const traversal = std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..");
        if (part.len == 0 or traversal or std.mem.findAny(u8, part, "/\\\x00") != null) {
            return error.PlatformIntegrationFailed;
        }
        all[i] = part;
    }
    return std.fs.path.join(arena, all);
}

/// `<root><sep>current[<sep><target>]` with `target`'s `/` rewritten to `sep`.
pub fn executable(
    arena: Allocator,
    sep: u8,
    root: []const u8,
    target: []const u8,
) Error![]const u8 {
    if (target.len == 0) return std.fmt.allocPrint(arena, "{s}{c}current", .{ root, sep });
    const relative = try arena.dupe(u8, try names.target(target));
    std.mem.replaceScalar(u8, relative, '/', sep);
    return std.fmt.allocPrint(arena, "{s}{c}current{c}{s}", .{ root, sep, sep, relative });
}

test "host vtable binds the native backend" {
    var h: Host = .init(std.testing.io, .{ .env = .{}, .system_managers = false });
    const p = h.platform();
    try std.testing.expect(p.now() > 0);
}

test "host paths stay under injected roots" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const h: Host = .init(std.testing.io, .{ .env = .{ .home = "/home/u" }, .machine_root = "/m" });
    try std.testing.expectEqualStrings(
        "/home/u/Applications/Hello",
        try h.scoped(a, .user, &.{ "Applications", "Hello" }),
    );
    try std.testing.expectEqualStrings(
        "/m/Applications/Hello",
        try h.scoped(a, .machine, &.{ "Applications", "Hello" }),
    );
    try std.testing.expectError(error.PlatformIntegrationFailed, h.userPath(a, &.{".."}));
    const dirs = try h.machineIntegrationDirs(a);
    try std.testing.expect(dirs.len > 0);
    for (dirs) |dir| try std.testing.expect(std.mem.startsWith(u8, dir, "/m/"));
    try std.testing.expect(h.isSystem("/m/etc/x"));
    try std.testing.expect(!h.isSystem("/home/u/x"));
    try std.testing.expectEqualStrings("/r/current/bin/x", try executable(a, '/', "/r", "bin/x"));
    const windows_exe = try executable(a, '\\', "C:\\r", "bin/x.exe");
    try std.testing.expectEqualStrings("C:\\r\\current\\bin\\x.exe", windows_exe);
    try std.testing.expectError(error.PlatformIntegrationFailed, executable(a, '/', "/r", "../x"));
}
