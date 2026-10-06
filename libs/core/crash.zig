//! Crash record: a panic or native fault writes `crash-<UTC>.json` (version, phase, tx-id,
//! stack addresses) next to the logs, runs the registered flush hook (journal), then falls
//! through to the std handler. Apps wire it with:
//!   pub const panic = std.debug.FullPanic(core.crash.panic);
//!   pub const debug = struct { pub const handleSegfault = core.crash.handleSegfault; };

const std = @import("std");

pub const Phase = enum(u8) {
    startup,
    recover,
    discover,
    validate,
    resolve,
    plan,
    prepare,
    download,
    verify,
    execute,
    commit,
    bootstrap,
    verify_install,
    finalize,
    ui,
    helper,
    portable,
    packager,
};

pub const Kind = enum { panic, fault };

pub const max_addresses = 32;
const max_text = 256;

pub const Record = struct {
    kind: Kind,
    message: []const u8,
    version: []const u8,
    product: []const u8,
    phase: Phase,
    tx_id: u64,
    unix_seconds: i64,
    addresses: []const usize,
};

const Text = struct {
    bytes: [max_text]u8 = @splat(0),
    len: u16 = 0,

    fn set(text: *Text, value: []const u8) void {
        const n: u16 = @intCast(@min(value.len, max_text));
        @memcpy(text.bytes[0..n], value[0..n]);
        text.len = n;
    }

    fn get(text: *const Text) []const u8 {
        return text.bytes[0..text.len];
    }
};

const State = struct {
    version: Text = .{},
    product: Text = .{},
    dir: Text = .{},
    phase: std.atomic.Value(u8) = .init(0),
    tx_id: std.atomic.Value(u64) = .init(0),
    recording: std.atomic.Value(bool) = .init(false),
    flush: ?*const fn () void = null,
};

// lint-allow(no-global-var): the panic handler has no other channel to process state.
var state: State = .{};

pub const Options = struct {
    version: []const u8,
    product: []const u8,
    /// Absolute log directory. Empty disables the file record (stderr trace still prints).
    dir: []const u8,
    flush: ?*const fn () void = null,
};

/// Call once at startup, before worker threads exist.
pub fn configure(options: Options) void {
    state.version.set(options.version);
    state.product.set(options.product);
    state.dir.set(options.dir);
    state.flush = options.flush;
}

pub fn setPhase(phase: Phase) void {
    state.phase.store(@backingInt(phase), .release);
}

pub fn setTransaction(tx_id: u64) void {
    state.tx_id.store(tx_id, .release);
}

pub fn panic(message: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    capture(.panic, message, first_trace_addr orelse @returnAddress(), null);
    std.debug.defaultPanic(message, first_trace_addr);
}

pub fn handleSegfault(addr: ?usize, name: []const u8, context: ?std.debug.CpuContextPtr) noreturn {
    @branchHint(.cold);
    capture(.fault, name, addr, context);
    std.debug.defaultHandleSegfault(addr, name, context);
}

fn capture(kind: Kind, message: []const u8, first: ?usize, context: ?std.debug.CpuContextPtr) void {
    if (state.recording.swap(true, .acq_rel)) return;
    if (state.flush) |flush| flush();
    if (state.dir.len == 0) return;
    var address_buffer: [max_addresses]usize = @splat(0);
    const trace = std.debug.captureCurrentStackTrace(.{
        .first_address = if (context == null) first else null,
        .context = context,
        .allow_unsafe_unwind = context != null,
    }, &address_buffer);
    const io = std.Options.debug_io;
    const now = std.Io.Clock.real.now(io).toSeconds();
    const record: Record = .{
        .kind = kind,
        .message = message,
        .version = state.version.get(),
        .product = state.product.get(),
        .phase = @fromBackingInt(@intCast(state.phase.load(.acquire))),
        .tx_id = state.tx_id.load(.acquire),
        .unix_seconds = now,
        .addresses = trace.return_addresses,
    };
    writeRecord(io, state.dir.get(), record) catch return;
}

fn writeRecord(io: std.Io, dir: []const u8, record: Record) !void {
    var name_buffer: [max_text + 64]u8 = @splat(0);
    var name_writer: std.Io.Writer = .fixed(&name_buffer);
    try name_writer.print("{s}/crash-", .{dir});
    try writeUtc(&name_writer, record.unix_seconds);
    try name_writer.writeAll(".json");
    var body_buffer: [8192]u8 = @splat(0);
    var body: std.Io.Writer = .fixed(&body_buffer);
    try format(&body, record);
    try std.Io.Dir.cwd().writeFile(
        io,
        .{ .sub_path = name_writer.buffered(), .data = body.buffered() },
    );
}

/// `YYYYMMDDTHHMMSSZ`.
pub fn writeUtc(writer: *std.Io.Writer, unix_seconds: i64) std.Io.Writer.Error!void {
    const seconds: u64 = std.math.cast(u64, unix_seconds) orelse 0;
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const day = epoch.getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    const clock = epoch.getDaySeconds();
    try writer.print("{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        day.year,                month_day.month.numeric(),  month_day.day_index + 1,
        clock.getHoursIntoDay(), clock.getMinutesIntoHour(), clock.getSecondsIntoMinute(),
    });
}

/// One JSON object; schema documented in docs/development/testing-lanes.md#crash-records.
pub fn format(writer: *std.Io.Writer, record: Record) std.Io.Writer.Error!void {
    try writer.print("{{\"schema\":1,\"kind\":\"{s}\",\"message\":", .{@tagName(record.kind)});
    try std.json.Stringify.encodeJsonString(record.message, .{}, writer);
    try writer.writeAll(",\"version\":");
    try std.json.Stringify.encodeJsonString(record.version, .{}, writer);
    try writer.writeAll(",\"product\":");
    try std.json.Stringify.encodeJsonString(record.product, .{}, writer);
    try writer.print(",\"phase\":\"{s}\",\"tx_id\":{d},\"time\":\"", .{
        @tagName(record.phase), record.tx_id,
    });
    try writeUtc(writer, record.unix_seconds);
    try writer.writeAll("\",\"addresses\":[");
    for (record.addresses, 0..) |address, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("\"0x{x}\"", .{address});
    }
    try writer.writeAll("]}\n");
}

test "crash record is valid JSON with stable fields" {
    var buffer: [1024]u8 = undefined; // SAFETY: fixed writer scratch.
    var writer: std.Io.Writer = .fixed(&buffer);
    try format(&writer, .{
        .kind = .panic,
        .message = "index out of bounds: \"x\"",
        .version = "0.1.0",
        .product = "com.example.hello",
        .phase = .commit,
        .tx_id = 7,
        .unix_seconds = 1_790_000_000,
        .addresses = &.{ 0x1000, 0x2000 },
    });
    const Parsed = struct {
        schema: u8,
        kind: []const u8,
        message: []const u8,
        version: []const u8,
        product: []const u8,
        phase: []const u8,
        tx_id: u64,
        time: []const u8,
        addresses: []const []const u8,
    };
    const parsed = try std.json.parseFromSlice(
        Parsed,
        std.testing.allocator,
        writer.buffered(),
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("commit", parsed.value.phase);
    try std.testing.expectEqualStrings("20260921T141320Z", parsed.value.time);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.addresses.len);
}

test "record file lands in the configured directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const dir = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    try writeRecord(io, dir, .{
        .kind = .fault,
        .message = "Segmentation fault",
        .version = "0.1.0",
        .product = "p",
        .phase = .execute,
        .tx_id = 1,
        .unix_seconds = 0,
        .addresses = &.{},
    });
    const bytes = try tmp.dir.readFileAlloc(
        io,
        "crash-19700101T000000Z.json",
        std.testing.allocator,
        .limited(4096),
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.find(u8, bytes, "\"kind\":\"fault\"") != null);
}
