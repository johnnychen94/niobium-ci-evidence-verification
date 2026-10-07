//! Path policy (docs/spec/platform-contract-v1.md#capabilities, Paths): install, cache and
//! staging roots per scope × platform. The framework decides; components cannot. Pure: the
//! environment is passed in, so every combination is tested on every host.

const std = @import("std");
const contracts = @import("contracts");
const platform = @import("platform");

pub const Os = platform.api.Os;
pub const Env = platform.api.Env;

pub const Error = error{ PlanMissingEnvironment, PlanRelativeEnvironment, OutOfMemory };

/// Integration kinds a scope × platform can carry. The platform backend may narrow this further.
pub const Support = struct {
    shortcuts: bool = true,
    file_associations: bool = true,
    services: bool = true,
    registration: bool = false,

    pub fn default(os: Os, scope: contracts.Scope) Support {
        return switch (os) {
            // Associations are declared by the app bundle; there is no dynamic registration.
            .macos => .{ .file_associations = false },
            // SCM services are machine-wide only.
            .windows => .{ .services = scope == .machine, .registration = true },
            .linux => .{},
        };
    }
};

fn absolute(os: Os, value: ?[]const u8) Error![]const u8 {
    const text = value orelse return error.PlanMissingEnvironment;
    if (text.len == 0) return error.PlanMissingEnvironment;
    const ok = switch (os) {
        .windows => text.len >= 3 and std.ascii.isAlphabetic(text[0]) and text[1] == ':' and
            (text[2] == '\\' or text[2] == '/') or std.mem.startsWith(u8, text, "\\\\"),
        .macos, .linux => text[0] == '/',
    };
    if (!ok) return error.PlanRelativeEnvironment;
    return std.mem.trimEnd(u8, text, "/\\");
}

fn join(arena: std.mem.Allocator, os: Os, parts: []const []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (parts, 0..) |part, index| {
        if (index > 0) try out.append(arena, os.separator());
        try out.appendSlice(arena, part);
    }
    return out.items;
}

pub fn installRoot(
    arena: std.mem.Allocator,
    os: Os,
    scope: contracts.Scope,
    product_id: []const u8,
    env: Env,
) Error![]const u8 {
    std.debug.assert(contracts.ids.isProductId(product_id));
    return switch (os) {
        .macos => switch (scope) {
            .user => join(
                arena,
                os,
                &.{ try absolute(os, env.home), "Library/Application Support", product_id },
            ),
            .machine => join(arena, os, &.{ try machineInstallBase(os, env), product_id }),
        },
        .windows => switch (scope) {
            .user => join(
                arena,
                os,
                &.{ try absolute(os, env.local_app_data), "Programs", product_id },
            ),
            .machine => join(arena, os, &.{ try machineInstallBase(os, env), product_id }),
        },
        .linux => switch (scope) {
            .user => if (env.xdg_data_home) |value|
                join(arena, os, &.{ try absolute(os, value), product_id })
            else
                join(arena, os, &.{ try absolute(os, env.home), ".local/share", product_id }),
            .machine => join(arena, os, &.{ try machineInstallBase(os, env), product_id }),
        },
    };
}

/// The directory machine-scope roots live in (`<base>/<product id>`). The privilege helper
/// derives its own policy from this, never from the broker.
pub fn machineInstallBase(os: Os, env: Env) Error![]const u8 {
    return switch (os) {
        .macos => "/Library/Application Support",
        .windows => absolute(os, env.program_files),
        .linux => "/opt",
    };
}

/// Per-user cache: downloads, and staging for machine-scope transactions.
pub fn cacheRoot(
    arena: std.mem.Allocator,
    os: Os,
    product_id: []const u8,
    env: Env,
) Error![]const u8 {
    return switch (os) {
        .macos => join(arena, os, &.{ try absolute(os, env.home), "Library/Caches", product_id }),
        .windows => join(
            arena,
            os,
            &.{ try absolute(os, env.local_app_data), product_id, "Cache" },
        ),
        .linux => if (env.xdg_cache_home) |value|
            join(arena, os, &.{ try absolute(os, value), product_id })
        else
            join(arena, os, &.{ try absolute(os, env.home), ".cache", product_id }),
    };
}

/// User scope stages inside the root (same volume, so placing is a rename); machine scope stages
/// in the user cache and the privilege helper copies into the root.
pub fn stagingDir(
    arena: std.mem.Allocator,
    os: Os,
    scope: contracts.Scope,
    root: []const u8,
    cache: []const u8,
    tx: u64,
) Error![]const u8 {
    const name = try arena.print("tx-{d}", .{tx});
    const base = if (scope == .user) root else cache;
    return join(arena, os, &.{ base, "staging", name });
}

/// Portable integration target relative to the install root, before native rendering.
pub fn maintainerPath(os: Os) []const u8 {
    return if (os == .windows) "maintainer/setup.exe" else "maintainer/setup";
}

test "path policy: scope × platform" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = "com.example.hello";
    const posix: Env = .{ .home = "/Users/ann/" };
    const win: Env = .{
        .local_app_data = "C:\\Users\\ann\\AppData\\Local",
        .program_files = "C:\\Program Files",
    };
    const Case = struct { os: Os, scope: contracts.Scope, env: Env, want: []const u8 };
    const cases = [_]Case{
        .{
            .os = .macos,
            .scope = .user,
            .env = posix,
            .want = "/Users/ann/Library/Application Support/" ++ id,
        },
        .{
            .os = .macos,
            .scope = .machine,
            .env = .{},
            .want = "/Library/Application Support/" ++ id,
        },
        .{
            .os = .windows,
            .scope = .user,
            .env = win,
            .want = "C:\\Users\\ann\\AppData\\Local\\Programs\\" ++ id,
        },
        .{ .os = .windows, .scope = .machine, .env = win, .want = "C:\\Program Files\\" ++ id },
        .{ .os = .linux, .scope = .user, .env = posix, .want = "/Users/ann/.local/share/" ++ id },
        .{
            .os = .linux,
            .scope = .user,
            .env = .{ .xdg_data_home = "/data" },
            .want = "/data/" ++ id,
        },
        .{ .os = .linux, .scope = .machine, .env = .{}, .want = "/opt/" ++ id },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(
            case.want,
            try installRoot(a, case.os, case.scope, id, case.env),
        );
    }
    try std.testing.expectError(
        error.PlanMissingEnvironment,
        installRoot(a, .macos, .user, id, .{}),
    );
    try std.testing.expectError(
        error.PlanRelativeEnvironment,
        installRoot(a, .linux, .user, id, .{ .home = "relative/home" }),
    );
    try std.testing.expectError(
        error.PlanRelativeEnvironment,
        installRoot(a, .windows, .user, id, .{ .local_app_data = "AppData" }),
    );
    try std.testing.expectEqualStrings(
        "/Users/ann/.cache/" ++ id,
        try cacheRoot(a, .linux, id, posix),
    );
    try std.testing.expectEqualStrings(
        "C:\\Users\\ann\\AppData\\Local\\" ++ id ++ "\\Cache",
        try cacheRoot(a, .windows, id, win),
    );
    try std.testing.expectEqualStrings(
        "/r/staging/tx-7",
        try stagingDir(a, .linux, .user, "/r", "/c", 7),
    );
    try std.testing.expectEqualStrings(
        "/c/staging/tx-7",
        try stagingDir(a, .linux, .machine, "/r", "/c", 7),
    );
    try std.testing.expect(!Support.default(.macos, .user).file_associations);
    try std.testing.expect(!Support.default(.windows, .user).services);
    try std.testing.expect(Support.default(.windows, .machine).registration);
}
