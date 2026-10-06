//! VirtualPlatform: real files under a temp root, plus seeded faults and kill points
//! (fault.zig), integrations materialized as files under `system_root`, and an injectable clock.
//! After a kill every call fails with error.PlatformKilled, like a dead process; a fresh
//! instance over the same directories models the restart.

const std = @import("std");
const contracts = @import("contracts");
const api = @import("api.zig");
const fault = @import("fault.zig");
const local = @import("local.zig");

const Error = api.Error;

pub const Virtual = struct {
    local: local.Local,
    faults: fault.FaultPlan = .none(),
    /// Absolute directory where shortcuts, associations, services and registrations land.
    system_root: []const u8,
    clock: i64 = 1_790_000_000,
    dead: bool = false,
    mutations: u32 = 0,
    /// Reported by freeSpace; null asks the real volume.
    free_bytes: ?u64 = null,

    pub fn init(io: std.Io, system_root: []const u8) Virtual {
        return .{ .local = .{ .io = io }, .system_root = system_root };
    }

    pub fn platform(v: *Virtual) api.Platform {
        return .{ .ptr = v, .vtable = &vtable };
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

    fn self(ptr: *anyopaque) *Virtual {
        return @ptrCast(@alignCast(ptr));
    }

    /// Consult the fault plan before a mutation. Kill marks the instance dead.
    fn gate(v: *Virtual, op: fault.Op) Error!void {
        if (v.dead) return error.PlatformKilled;
        v.mutations += 1;
        return switch (v.faults.next(op)) {
            .none, .clock_skew, .connection_reset, .timeout => {},
            .kill => {
                v.dead = true;
                return error.PlatformKilled;
            },
            .no_space => error.FsNoSpace,
            .access_denied => error.FsAccessDenied,
            .sharing_violation => error.FsSharingViolation,
            .partial_write, .rename_failed => error.FsIo,
        };
    }

    fn createDirPath(ptr: *anyopaque, path: []const u8) Error!void {
        const v = self(ptr);
        try v.gate(.make_dir);
        return v.local.createDirPath(path);
    }

    fn writeFile(
        ptr: *anyopaque,
        path: []const u8,
        bytes: []const u8,
        executable: bool,
    ) Error!void {
        const v = self(ptr);
        try v.gate(.write);
        return v.local.writeFile(path, bytes, executable);
    }

    /// A kill during an append leaves a torn prefix, like a crash mid-write.
    fn appendFile(ptr: *anyopaque, path: []const u8, bytes: []const u8) Error!void {
        const v = self(ptr);
        v.gate(.write) catch |err| {
            if (err == error.PlatformKilled and bytes.len > 1 and v.mutations % 2 == 0) {
                // lint-allow(no-empty-catch): the torn prefix is best effort; the kill wins.
                v.local.appendFile(path, bytes[0 .. bytes.len / 2]) catch {};
            }
            return err;
        };
        return v.local.appendFile(path, bytes);
    }

    fn copyFile(
        ptr: *anyopaque,
        source: []const u8,
        target: []const u8,
        executable: bool,
    ) Error!void {
        const v = self(ptr);
        try v.gate(.create_file);
        return v.local.copyFile(source, target, executable);
    }

    fn rename(ptr: *anyopaque, from: []const u8, to: []const u8) Error!void {
        const v = self(ptr);
        try v.gate(.rename);
        return v.local.rename(from, to);
    }

    fn deleteFile(ptr: *anyopaque, path: []const u8) Error!void {
        const v = self(ptr);
        try v.gate(.remove);
        return v.local.deleteFile(path);
    }

    fn deleteTree(ptr: *anyopaque, path: []const u8) Error!void {
        const v = self(ptr);
        try v.gate(.remove);
        return v.local.deleteTree(path);
    }

    fn setPointer(ptr: *anyopaque, link: []const u8, target: []const u8) Error!void {
        const v = self(ptr);
        try v.gate(.symlink);
        return v.local.setPointer(link, target);
    }

    fn deletePointer(ptr: *anyopaque, link: []const u8) Error!void {
        const v = self(ptr);
        try v.gate(.remove);
        return v.local.deletePointer(link);
    }

    const Location = struct {
        buffer: [std.fs.max_path_bytes]u8 = undefined, // SAFETY: only buffer[0..len] is read.
        len: usize = 0,

        fn slice(l: *const Location) []const u8 {
            return l.buffer[0..l.len];
        }
    };

    /// `<system_root>/<kind>/<id>` plus an optional `.tx-<n>` suffix for prepared entries.
    fn location(
        v: *const Virtual,
        kind: contracts.installation.IntegrationKind,
        id: []const u8,
        tx: ?u64,
    ) Error!Location {
        const separator = std.mem.findAny(u8, id, "/\\\x00") != null;
        if (id.len == 0 or separator or std.mem.eql(u8, id, "..")) {
            return error.PlatformIntegrationFailed;
        }
        var out: Location = .{};
        const sep = std.fs.path.sep_str;
        const text = if (tx) |n|
            std.fmt.bufPrint(
                &out.buffer,
                "{s}" ++ sep ++ "{t}" ++ sep ++ "{s}.tx-{d}",
                .{ v.system_root, kind, id, n },
            )
        else
            std.fmt.bufPrint(
                &out.buffer,
                "{s}" ++ sep ++ "{t}" ++ sep ++ "{s}",
                .{ v.system_root, kind, id },
            );
        out.len = (text catch return error.PlatformIntegrationFailed).len;
        return out;
    }

    fn describe(buffer: []u8, request: *const api.IntegrationRequest) Error![]const u8 {
        const i = request.integration;
        return std.fmt.bufPrint(
            buffer,
            "{s}\n{s}\n{s}\n",
            .{ request.product_id, i.label, i.target },
        ) catch
            error.PlatformIntegrationFailed;
    }

    fn prepareIntegration(ptr: *anyopaque, request: *const api.IntegrationRequest) Error!void {
        const v = self(ptr);
        try v.gate(.create_file);
        const temp = try v.location(request.integration.kind, request.integration.id, request.tx);
        const dir = std.fs.path.dirname(temp.slice()) orelse return error.PlatformIntegrationFailed;
        try v.local.createDirPath(dir);
        var buffer: [4096]u8 = undefined; // SAFETY: written by describe.
        try v.local.writeFile(temp.slice(), try describe(&buffer, request), false);
    }

    fn discardIntegration(ptr: *anyopaque, request: *const api.IntegrationRequest) Error!void {
        const v = self(ptr);
        try v.gate(.remove);
        const temp = try v.location(request.integration.kind, request.integration.id, request.tx);
        return v.local.deleteFile(temp.slice());
    }

    fn activateIntegration(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        request: *const api.IntegrationRequest,
    ) Error![]const u8 {
        const v = self(ptr);
        try v.gate(.rename);
        const i = request.integration;
        const temp = try v.location(i.kind, i.id, request.tx);
        const final = try v.location(i.kind, i.id, null);
        v.local.rename(temp.slice(), final.slice()) catch |err| switch (err) {
            // Already activated by an earlier attempt (roll-forward after a crash).
            error.FsNotFound => {
                const dir = std.fs.path.dirname(
                    final.slice(),
                ) orelse return error.PlatformIntegrationFailed;
                try v.local.createDirPath(dir);
                var buffer: [4096]u8 = undefined; // SAFETY: written by describe.
                try v.local.writeFile(final.slice(), try describe(&buffer, request), false);
            },
            else => return err,
        };
        return arena.dupe(u8, final.slice());
    }

    fn removeIntegration(
        ptr: *anyopaque,
        installed: contracts.installation.Integration,
    ) Error!void {
        const v = self(ptr);
        try v.gate(.remove);
        const expected = try v.location(installed.kind, installed.id, null);
        if (!std.mem.eql(
            u8,
            expected.slice(),
            installed.location,
        )) return error.PlatformIntegrationFailed;
        return v.local.deleteFile(installed.location);
    }

    fn freeSpace(ptr: *anyopaque, path: []const u8) Error!u64 {
        const v = self(ptr);
        if (v.dead) return error.PlatformKilled;
        return v.free_bytes orelse v.local.freeSpace(path);
    }

    fn now(ptr: *anyopaque) i64 {
        return self(ptr).clock;
    }
};

test "virtual integrations persist as files and kill is sticky" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sys = try tmp.dir.realPathFileAlloc(io, ".", a);
    var v: Virtual = .init(io, sys);
    const p = v.platform();
    const request: api.IntegrationRequest = .{
        .integration = .{
            .kind = .shortcut,
            .id = "Hello",
            .label = "Hello",
            .target = "runtime/bin/hello",
        },
        .product_id = "com.example.hello",
        .product_name = "Hello",
        .scope = .user,
        .root = "/root",
        .tx = 1,
    };
    try p.prepareIntegration(&request);
    const where = try p.activateIntegration(a, &request);
    try std.testing.expectEqualStrings(where, try p.activateIntegration(a, &request));
    try p.removeIntegration(.{ .kind = .shortcut, .id = "Hello", .location = where });
    var bad = request;
    bad.integration.id = "../escape";
    try std.testing.expectError(error.PlatformIntegrationFailed, p.prepareIntegration(&bad));
    v.faults = .init(1, .{ .fault_per_mille = 0, .kill_at = 0 });
    try std.testing.expectError(error.PlatformKilled, p.createDirPath(sys));
    v.faults = .none();
    try std.testing.expectError(error.PlatformKilled, p.createDirPath(sys));
}
