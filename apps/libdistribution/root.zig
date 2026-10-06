//! C ABI v1 (docs/spec/abi-v1.md, api/c/distribution.h). Every entry point catches errors and
//! returns a status (`-exit code`); no Zig error, allocator or slice crosses the boundary.
//! A context owns one engine run: check_update/resolve → fetch → stage → transaction_commit.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const contracts = @import("contracts");
const core = @import("core");
const engine = @import("engine");
const planner = @import("planner");
const portable = @import("portable");

const Allocator = std.mem.Allocator;
const Runtime = engine.runtime.Runtime;

pub const abi_v1: u32 = 1;
const ok: i32 = 0;

const gpa: Allocator = if (builtin.is_test) std.testing.allocator else std.heap.smp_allocator;

pub const Buffer = extern struct { data: ?[*]const u8, len: usize };

pub const Config = extern struct {
    struct_size: u32,
    repository: ?[*:0]const u8,
    trust_root: ?[*]const u8,
    trust_root_len: usize,
    product_id: ?[*:0]const u8,
    channel: ?[*:0]const u8,
    scope: i32,
    install_dir: ?[*:0]const u8,
    work_dir: ?[*:0]const u8,
};

pub const UpdateInfo = extern struct {
    struct_size: u32,
    update_available: i32,
    release_sequence: u64,
    installed_release_sequence: u64,
    version: [64]u8,
};

pub const EventFn = *const fn (user: ?*anyopaque, json: [*]const u8, len: usize) callconv(.c) void;

/// What C sees: an opaque handle.
pub const Handle = opaque {};

pub const Api = extern struct {
    struct_size: u32,
    context_create: *const fn (?*const Config, ?*?*Handle) callconv(.c) i32,
    context_destroy: *const fn (?*Handle) callconv(.c) void,
    check_update: *const fn (?*Handle, ?*UpdateInfo) callconv(.c) i32,
    resolve: *const fn (?*Handle) callconv(.c) i32,
    fetch: *const fn (?*Handle) callconv(.c) i32,
    stage: *const fn (?*Handle) callconv(.c) i32,
    transaction_commit: *const fn (?*Handle) callconv(.c) i32,
    portable_resolve: *const fn (?*Handle, ?[*:0]const u8, ?*Buffer) callconv(.c) i32,
    portable_run: *const fn (
        ?*Handle,
        ?[*:0]const u8,
        ?[*:null]const ?[*:0]const u8,
        ?*i32,
    ) callconv(.c) i32,
    event_subscribe: *const fn (?*Handle, ?EventFn, ?*anyopaque) callconv(.c) i32,
    cancel: *const fn (?*Handle) callconv(.c) i32,
    last_error: *const fn (?*Handle, ?*Buffer) callconv(.c) i32,
};

const api: Api = .{
    .struct_size = @sizeOf(Api),
    .context_create = contextCreate,
    .context_destroy = contextDestroy,
    .check_update = checkUpdate,
    .resolve = resolve,
    .fetch = fetch,
    .stage = stage,
    .transaction_commit = transactionCommit,
    .portable_resolve = portableResolve,
    .portable_run = portableRun,
    .event_subscribe = eventSubscribe,
    .cancel = cancel,
    .last_error = lastError,
};

pub export fn dist_get_api(requested_version: u32, out_api: ?*?*const Api) callconv(.c) i32 {
    const out = out_api orelse return usage;
    if (requested_version != abi_v1) return usage;
    out.* = &api;
    return ok;
}

const usage: i32 = core.ExitCode.usage.abiStatus();

const Error = engine.Error || engine.runtime.Error || error{
    UsageNullArgument,
    UsageBadConfig,
    UsageStepOrder,
    BootstrapPending,
};

pub const Context = struct {
    threaded: std.Io.Threaded,
    environ: std.process.Environ.Map,
    arena_state: std.heap.ArenaAllocator,
    rt: Runtime,
    request: engine.runtime.Request,
    work_dir: ?[]const u8,
    engine: ?engine.Engine = null,
    callback: ?EventFn = null,
    user: ?*anyopaque = null,
    error_bytes: [512]u8 = @splat(0),
    error_len: usize = 0,
    result: std.ArrayList(u8) = .empty,
    /// Fixed TUF clock for tests; null reads the real clock.
    now: ?i64 = null,

    fn io(c: *Context) std.Io {
        return c.threaded.io();
    }

    fn sink(c: *Context) engine.Sink {
        return .bind(Context, c, emit);
    }

    fn emit(c: *Context, event: engine.events.Event) void {
        const callback = c.callback orelse return;
        var buffer: [1024]u8 = undefined; // SAFETY: fixed writer scratch.
        var writer: std.Io.Writer = .fixed(&buffer);
        contracts.events.write(&writer, event) catch return;
        const line = std.mem.trimEnd(u8, writer.buffered(), "\n");
        callback(c.user, line.ptr, line.len);
    }

    /// Records `{"code","message","exit_code"}`, emits the `error` event, returns the status.
    fn fail(c: *Context, err: Error) i32 {
        const name = @errorName(err);
        const code = core.exit_code.fromName(name);
        var writer: std.Io.Writer = .fixed(&c.error_bytes);
        writer.writeAll("{\"code\":\"") catch return code.abiStatus();
        core.exit_code.eventCode(&writer, name) catch return code.abiStatus();
        writer.print("\",\"message\":\"{s}\",\"exit_code\":{d}}}", .{
            name,
            @backingInt(code),
        }) catch return code.abiStatus();
        c.error_len = writer.buffered().len;
        c.sink().failure(name);
        return code.abiStatus();
    }

    fn engineFor(c: *Context) Error!*engine.Engine {
        if (c.engine == null) {
            var request = c.request;
            request.sink = c.sink();
            request.now = c.now;
            c.engine = .init(try c.rt.options(request));
        }
        return &c.engine.?;
    }

    fn ensureResolved(c: *Context) Error!*engine.Engine {
        const e = try c.engineFor();
        if (e.step == .idle) {
            try e.begin(.install);
            try e.resolve();
        }
        return e;
    }

    fn arena(c: *Context) Allocator {
        return c.arena_state.allocator();
    }
};

fn context(handle: ?*Handle) ?*Context {
    const h = handle orelse return null;
    return @ptrCast(@alignCast(h));
}

/// procfs reports size 0, so the file is streamed rather than sized by stat.
fn procEnviron(io: std.Io) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, "/proc/self/environ", .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined; // SAFETY: reader scratch space.
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(gpa, .limited(1 << 20));
}

fn processEnviron() std.process.Environ {
    if (builtin.os.tag == .windows) return .{ .block = .global };
    if (builtin.link_libc) return .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    return .empty;
}

/// The host's environment. Linux builds carry no libc (a `.so` linked against one libc breaks
/// inside a host using another), so they read `/proc/self/environ`: the environment at exec.
fn environMap(io: std.Io) Error!std.process.Environ.Map {
    if (builtin.os.tag == .windows or builtin.link_libc) {
        return processEnviron().createMap(gpa) catch error.OutOfMemory;
    }
    var map: std.process.Environ.Map = .init(gpa);
    errdefer map.deinit();
    const bytes = procEnviron(io) catch |err| {
        std.log.warn("/proc/self/environ: {t}", .{err});
        return map;
    };
    defer gpa.free(bytes);
    var entries = std.mem.splitScalar(u8, bytes, 0);
    while (entries.next()) |entry| {
        const eq = std.mem.findScalar(u8, entry, '=') orelse continue;
        if (eq == 0) continue;
        try map.put(entry[0..eq], entry[eq + 1 ..]);
    }
    return map;
}

fn optionalString(arena: Allocator, value: ?[*:0]const u8) Error!?[]const u8 {
    const text = value orelse return null;
    const slice = std.mem.span(text);
    if (slice.len == 0) return null;
    return try arena.dupe(u8, slice);
}

fn requestFrom(arena: Allocator, config: *const Config) Error!engine.runtime.Request {
    const product = try optionalString(arena, config.product_id) orelse
        return error.UsageBadConfig;
    if (!contracts.ids.isProductId(product)) return error.UsageBadConfig;
    const root = config.trust_root orelse return error.UsageBadConfig;
    if (config.trust_root_len == 0) return error.UsageBadConfig;
    const channel: ?contracts.Channel = if (try optionalString(arena, config.channel)) |name|
        std.meta.stringToEnum(contracts.Channel, name) orelse return error.UsageBadConfig
    else
        null;
    return .{
        .product_id = product,
        .root_bytes = try arena.dupe(u8, root[0..config.trust_root_len]),
        .channel = channel,
        .scope = switch (config.scope) {
            0 => .user,
            1 => .machine,
            else => return error.UsageBadConfig,
        },
        .install_dir = try optionalString(arena, config.install_dir),
        .work_dir = try optionalString(arena, config.work_dir),
        .installer_version = build_options.version,
    };
}

fn create(config: *const Config) Error!*Context {
    if (config.struct_size < @sizeOf(Config)) return error.UsageBadConfig;
    const c = try gpa.create(Context);
    errdefer gpa.destroy(c);
    c.* = .{
        .threaded = .init(gpa, .{ .environ = processEnviron() }),
        // SAFETY: filled from the process environment right below.
        .environ = undefined,
        .arena_state = .init(gpa),
        // SAFETY: initialized by Runtime.init below.
        .rt = undefined,
        // SAFETY: filled by requestFrom below.
        .request = undefined,
        .work_dir = null,
    };
    errdefer c.threaded.deinit();
    errdefer c.arena_state.deinit();
    c.environ = try environMap(c.io());
    errdefer c.environ.deinit();
    c.request = try requestFrom(c.arena(), config);
    c.work_dir = c.request.work_dir;
    const repository = try optionalString(c.arena(), config.repository) orelse
        return error.UsageBadConfig;
    try c.rt.init(c.io(), gpa, &c.environ, repository, null);
    return c;
}

fn contextCreate(config: ?*const Config, out_context: ?*?*Handle) callconv(.c) i32 {
    const out = out_context orelse return usage;
    out.* = null;
    const cfg = config orelse return usage;
    const c = create(cfg) catch |err| return core.exit_code.fromError(err).abiStatus();
    out.* = @ptrCast(c);
    return ok;
}

fn contextDestroy(handle: ?*Handle) callconv(.c) void {
    const c = context(handle) orelse return;
    if (c.engine) |*e| e.deinit();
    c.rt.deinit();
    c.result.deinit(gpa);
    c.environ.deinit();
    c.arena_state.deinit();
    c.threaded.deinit();
    gpa.destroy(c);
}

fn checkUpdate(handle: ?*Handle, out_info: ?*UpdateInfo) callconv(.c) i32 {
    const c = context(handle) orelse return usage;
    const info = out_info orelse return c.fail(error.UsageNullArgument);
    if (info.struct_size < @sizeOf(UpdateInfo)) return c.fail(error.UsageBadConfig);
    const e = c.ensureResolved() catch |err| return c.fail(err);
    const offer = e.offer() orelse return c.fail(error.UsageStepOrder);
    info.update_available = @intFromBool(offer.available);
    info.release_sequence = offer.release_sequence;
    info.installed_release_sequence = if (e.current) |current| current.release_sequence else 0;
    info.version = @splat(0);
    const len = @min(offer.version.len, info.version.len - 1);
    @memcpy(info.version[0..len], offer.version[0..len]);
    return ok;
}

fn resolve(handle: ?*Handle) callconv(.c) i32 {
    const c = context(handle) orelse return usage;
    _ = c.ensureResolved() catch |err| return c.fail(err);
    return ok;
}

/// After `resolve` found the installed release (`up_to_date`), the later steps are no-ops.
fn resolved(c: *Context) Error!?*engine.Engine {
    const e = if (c.engine) |*e| e else return error.UsageStepOrder;
    return if (e.report != null) null else e;
}

fn fetch(handle: ?*Handle) callconv(.c) i32 {
    const c = context(handle) orelse return usage;
    const step = resolved(c) catch |err| return c.fail(err);
    const e = step orelse return ok;
    e.fetch() catch |err| return c.fail(err);
    return ok;
}

fn stage(handle: ?*Handle) callconv(.c) i32 {
    const c = context(handle) orelse return usage;
    const step = resolved(c) catch |err| return c.fail(err);
    const e = step orelse return ok;
    e.stage() catch |err| return c.fail(err);
    return ok;
}

fn transactionCommit(handle: ?*Handle) callconv(.c) i32 {
    const c = context(handle) orelse return usage;
    const step = resolved(c) catch |err| return c.fail(err);
    const e = step orelse return ok;
    const report = e.commit() catch |err| return c.fail(err);
    if (report.bootstrap == .pending) return c.fail(error.BootstrapPending);
    return ok;
}

fn prepare(c: *Context, target_text: [*:0]const u8) Error!portable.Prepared {
    const target = try portable.parseTarget(std.mem.span(target_text));
    const base = c.work_dir orelse try planner.paths.cacheRoot(
        c.arena(),
        engine.nativeOs(),
        target.product_id,
        c.rt.env,
    );
    const cache: portable.Cache = .{
        .io = c.io(),
        .path = try std.fs.path.join(c.arena(), &.{ base, "portable" }),
    };
    return portable.prepare(gpa, c.arena(), &c.rt.repo, cache, .{
        .target = target,
        .root_bytes = c.request.root_bytes,
        .channel = c.request.channel orelse .stable,
        .platform = contracts.Platform.current() orelse return error.PlatformUnsupported,
        .installer_version = build_options.version,
        .now = c.now orelse std.Io.Clock.real.now(c.io()).toSeconds(),
        .cancel = &c.rt.cancel,
    });
}

fn portableResolve(handle: ?*Handle, target: ?[*:0]const u8, out_path: ?*Buffer) callconv(.c) i32 {
    const c = context(handle) orelse return usage;
    const text = target orelse return c.fail(error.UsageNullArgument);
    const out = out_path orelse return c.fail(error.UsageNullArgument);
    const prepared = prepare(c, text) catch |err| return c.fail(err);
    c.result.clearRetainingCapacity();
    c.result.appendSlice(gpa, prepared.exe) catch return c.fail(error.OutOfMemory);
    out.* = .{ .data = c.result.items.ptr, .len = c.result.items.len };
    return ok;
}

fn portableRun(
    handle: ?*Handle,
    target: ?[*:0]const u8,
    argv: ?[*:null]const ?[*:0]const u8,
    out_exit_code: ?*i32,
) callconv(.c) i32 {
    const c = context(handle) orelse return usage;
    const text = target orelse return c.fail(error.UsageNullArgument);
    const out = out_exit_code orelse return c.fail(error.UsageNullArgument);
    const prepared = prepare(c, text) catch |err| return c.fail(err);
    var args: std.ArrayList([]const u8) = .empty;
    if (argv) |list| for (std.mem.span(list)) |arg| {
        args.append(c.arena(), std.mem.span(arg.?)) catch return c.fail(error.OutOfMemory);
    };
    const code = portable.run(c.io(), prepared, c.arena(), args.items, &c.environ) catch |err|
        return c.fail(err);
    out.* = code;
    return ok;
}

fn eventSubscribe(handle: ?*Handle, callback: ?EventFn, user: ?*anyopaque) callconv(.c) i32 {
    const c = context(handle) orelse return usage;
    c.callback = callback;
    c.user = user;
    return ok;
}

fn cancel(handle: ?*Handle) callconv(.c) i32 {
    const c = context(handle) orelse return usage;
    c.rt.cancel.store(true, .release);
    return ok;
}

fn lastError(handle: ?*Handle, out_json: ?*Buffer) callconv(.c) i32 {
    const c = context(handle) orelse return usage;
    const out = out_json orelse return usage;
    out.* = .{ .data = &c.error_bytes, .len = c.error_len };
    return ok;
}

test {
    _ = @import("abi_test.zig");
}
