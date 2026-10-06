//! Production wiring shared by `apps/setup` and `apps/libdistribution`: process environment, host
//! platform, repository source and elevator. Tests assemble `Options` by hand instead.

const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts");
const platform = @import("platform");
const repository = @import("repository");
const elevation = @import("elevation.zig");
const root = @import("root.zig");

pub const Error = error{ RepoNotFound, RepoUnavailable, PlatformUnsupported, OutOfMemory };

/// XDG base directories must be absolute; relative values are ignored (XDG spec).
fn xdg(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    if (text.len == 0 or text[0] != '/') return null;
    return text;
}

/// Platform paths from the process environment (`HOME`/`USERPROFILE`, `%LOCALAPPDATA%`, XDG).
pub fn envFrom(map: *const std.process.Environ.Map) platform.Env {
    const windows = builtin.os.tag == .windows;
    return .{
        .home = if (windows) map.get("USERPROFILE") else map.get("HOME"),
        .local_app_data = map.get("LOCALAPPDATA"),
        .app_data = map.get("APPDATA"),
        .program_files = map.get("ProgramFiles"),
        .program_data = map.get("ProgramData"),
        .xdg_data_home = xdg(map.get("XDG_DATA_HOME")),
        .xdg_config_home = xdg(map.get("XDG_CONFIG_HOME")),
        .xdg_cache_home = xdg(map.get("XDG_CACHE_HOME")),
    };
}

pub fn isUrl(spec: []const u8) bool {
    return std.mem.startsWith(u8, spec, "https://") or std.mem.startsWith(u8, spec, "http://");
}

/// Already root: machine-scope mutations need no helper. Windows always goes through `runas`,
/// which does not prompt when the token is already elevated.
fn privileged() bool {
    return switch (builtin.os.tag) {
        .linux => std.os.linux.geteuid() == 0,
        .macos => std.c.geteuid() == 0,
        else => false,
    };
}

/// What a frontend decides; everything else comes from the runtime.
pub const Request = struct {
    product_id: []const u8,
    root_bytes: []const u8,
    channel: ?contracts.Channel = null,
    scope: ?contracts.Scope = null,
    components: ?[]const []const u8 = null,
    install_dir: ?[]const u8 = null,
    work_dir: ?[]const u8 = null,
    installer_version: []const u8,
    sink: root.Sink = .{},
    /// Fixed TUF clock (tests of the frontends); null reads the real clock.
    now: ?i64 = null,
};

pub const Runtime = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    env: platform.Env,
    environ: ?*const std.process.Environ.Map,
    host: platform.Host,
    client: std.http.Client,
    repo: repository.Repository,
    dir: ?std.Io.Dir = null,
    /// The running setup: maintainer source and helper executable. Null in the C ABI.
    self_exe: ?[]const u8,
    process: elevation.Process,
    cancel: std.atomic.Value(bool) = .init(false),

    /// `rt` must stay at a fixed address: the platform, repository and elevator point into it.
    /// A null `repo_spec` leaves an empty repository (uninstall and status need none).
    pub fn init(
        rt: *Runtime,
        io: std.Io,
        gpa: std.mem.Allocator,
        environ: ?*const std.process.Environ.Map,
        repo_spec: ?[]const u8,
        self_exe: ?[]const u8,
    ) Error!void {
        const env: platform.Env = if (environ) |map| envFrom(map) else .{};
        rt.* = .{
            .io = io,
            .gpa = gpa,
            .env = env,
            .environ = environ,
            .host = .init(io, .{ .env = env }),
            .client = .{ .allocator = gpa, .io = io },
            .repo = .{ .embedded = .{ .io = io, .files = &.{} } },
            .self_exe = self_exe,
            .process = .{ .io = io, .gpa = gpa, .self_exe = self_exe orelse "" },
        };
        const spec = repo_spec orelse return;
        if (isUrl(spec)) {
            const base = std.mem.trimEnd(u8, spec, "/");
            rt.repo = .{ .http = .{ .client = &rt.client, .base = base, .cancel = &rt.cancel } };
            return;
        }
        const dir = std.Io.Dir.cwd().openDir(io, spec, .{}) catch |err| return switch (err) {
            error.FileNotFound, error.NotDir => error.RepoNotFound,
            else => error.RepoUnavailable,
        };
        rt.dir = dir;
        rt.repo = .{ .directory = .{ .io = io, .dir = dir, .cancel = &rt.cancel } };
    }

    pub fn deinit(rt: *Runtime) void {
        if (rt.dir) |dir| dir.close(rt.io);
        rt.client.deinit();
    }

    pub fn elevator(rt: *Runtime) elevation.Elevator {
        if (privileged()) return .{ .direct = rt.host.platform() };
        if (rt.self_exe == null) return .unavailable;
        return .{ .process = &rt.process };
    }

    pub fn options(rt: *Runtime, request: Request) Error!root.Options {
        return .{
            .io = rt.io,
            .gpa = rt.gpa,
            .platform = rt.host.platform(),
            .elevator = rt.elevator(),
            .repository = &rt.repo,
            .root_bytes = request.root_bytes,
            .product_id = request.product_id,
            .channel = request.channel,
            .scope = request.scope,
            .components = request.components,
            .install_dir = request.install_dir,
            .work_dir = request.work_dir,
            .env = rt.env,
            .target_platform = contracts.Platform.current() orelse return error.PlatformUnsupported,
            .installer_version = request.installer_version,
            .maintainer_source = rt.self_exe,
            .bootstrap_env = rt.environ,
            .sink = request.sink,
            .cancel = &rt.cancel,
            .now = request.now,
        };
    }
};

test "environment maps to platform paths" {
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("HOME", "/home/ann");
    try map.put("USERPROFILE", "C:\\Users\\ann");
    try map.put("XDG_DATA_HOME", "relative/data");
    try map.put("XDG_CACHE_HOME", "/var/cache/ann");
    const env = envFrom(&map);
    const home = if (builtin.os.tag == .windows) "C:\\Users\\ann" else "/home/ann";
    try std.testing.expectEqualStrings(home, env.home.?);
    try std.testing.expectEqual(@as(?[]const u8, null), env.xdg_data_home);
    try std.testing.expectEqualStrings("/var/cache/ann", env.xdg_cache_home.?);
    try std.testing.expect(isUrl("https://dl.example.com/hello"));
    try std.testing.expect(!isUrl("/srv/repository"));
}
