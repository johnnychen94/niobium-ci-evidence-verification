//! X11 window over the core protocol on the local socket (no libX11, no libc). Requests are
//! encoded by x11_wire; replies are awaited synchronously and events that arrive meanwhile are
//! queued. A self-pipe wakes `poll` from other threads. Crash traps
//! (docs/spec/platform-contract-v1.md): a closed connection and protocol error packets are
//! errors returned from `next`, never panics; every length from the server is checked.

const std = @import("std");
const linux = std.os.linux;
const ui = @import("ui_core");
const render = @import("ui_render");
const window = @import("window.zig");
const wire = @import("x11_wire.zig");

pub const capabilities: ui.env.Capabilities = .{};

pub const Error = wire.Error || error{ OutOfMemory, UiX11ConnectionLost, UiWindowFailed };

const max_file = 1 << 20;
/// Largest reply accepted: a full-window GetImage at 400% of the largest wizard window.
const max_reply = 64 << 20;

fn ok(rc: usize) ?usize {
    return if (linux.errno(rc) == .SUCCESS) rc else null;
}

/// Whole-file read with raw syscalls (Xauthority, GTK settings); null on any failure.
fn readFile(arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const z = arena.dupeSentinel(u8, path, 0) catch return null;
    const fd_rc = ok(linux.open(z.ptr, .{ .CLOEXEC = true }, 0)) orelse return null;
    const fd = std.math.cast(i32, fd_rc) orelse return null;
    defer _ = linux.close(fd); // lint-allow(no-discard-call): read-only descriptor.
    var out: std.ArrayList(u8) = .empty;
    var buffer: [4096]u8 = undefined; // SAFETY: only the bytes read are appended.
    // loop-bound: stops at EOF or after max_file bytes.
    while (out.items.len < max_file) {
        const n = ok(linux.read(fd, &buffer, buffer.len)) orelse return null;
        if (n == 0) return out.items;
        out.appendSlice(arena, buffer[0..n]) catch return null;
    }
    return null;
}

fn protocolError(f: @FieldType(wire.Packet, "failure")) Error {
    std.log.err("x11: error {d} for request {d}", .{ f.code, f.major });
    return error.UiX11Protocol;
}

const Atoms = struct {
    wm_protocols: u32 = 0,
    wm_delete_window: u32 = 0,
    net_wm_name: u32 = 0,
    utf8_string: u32 = 0,
};

pub const Window = struct {
    arena: std.mem.Allocator = undefined, // SAFETY: set first thing in `open`.
    environ: *const std.process.Environ.Map = undefined, // SAFETY: set first thing in `open`.
    fd: i32 = -1,
    wake_pipe: [2]i32 = .{ -1, -1 },
    setup: wire.Setup = undefined, // SAFETY: parsed in `connect` before any use.
    window_id: u32 = 0,
    gc: u32 = 0,
    atoms: Atoms = .{},
    keymap: wire.Keymap = .{ .per_keycode = 0, .min_keycode = 0, .keysyms = &.{} },
    queue: window.Queue = .{},
    in: [1 << 16]u8 = undefined, // SAFETY: only [0..in_len] is read.
    in_len: usize = 0,
    out: std.ArrayList(u8) = .empty,
    scale_value: u16 = 100,
    logical: window.Size = .{ .w = 0, .h = 0 },
    /// Device size of the last `present`.
    shown: struct { w: u16, h: u16 } = .{ .w = 0, .h = 0 },
    failed: ?Error = null,

    pub fn open(
        w: *Window,
        arena: std.mem.Allocator,
        environ: *const std.process.Environ.Map,
        o: window.Options,
    ) Error!void {
        w.* = .{ .arena = arena, .environ = environ, .logical = .{ .w = o.width, .h = o.height } };
        errdefer w.close();
        const display = try wire.parseDisplay(
            environ.get("DISPLAY") orelse return error.UiNoDisplay,
        );
        try w.connect(display.number);
        var fds: [2]i32 = undefined; // SAFETY: written by pipe2.
        _ = ok(linux.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true })) orelse
            return error.UiWindowFailed;
        w.wake_pipe = fds;
        w.atoms = .{
            .wm_protocols = try w.intern("WM_PROTOCOLS"),
            .wm_delete_window = try w.intern("WM_DELETE_WINDOW"),
            .net_wm_name = try w.intern("_NET_WM_NAME"),
            .utf8_string = try w.intern("UTF8_STRING"),
        };
        w.keymap = try w.keyboardMapping();
        w.scale_value = try w.detectScale();
        try w.createWindow(o.title);
    }

    pub fn close(w: *Window) void {
        if (w.fd >= 0) _ = linux.close(w.fd); // lint-allow(no-discard-call): closing at exit.
        for (w.wake_pipe) |fd| if (fd >= 0) {
            _ = linux.close(fd); // lint-allow(no-discard-call): closing at exit.
        };
        w.fd = -1;
        w.wake_pipe = .{ -1, -1 };
    }

    fn connect(w: *Window, number: u32) Error!void {
        const sock_rc = ok(
            linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0),
        ) orelse
            return error.UiNoDisplay;
        w.fd = std.math.cast(i32, sock_rc) orelse return error.UiNoDisplay;
        var addr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
        const path = std.fmt.bufPrint(&addr.path, "/tmp/.X11-unix/X{d}", .{number}) catch
            return error.UiNoDisplay;
        _ = path;
        _ = ok(
            linux.connect(w.fd, &addr, @sizeOf(linux.sockaddr.un)),
        ) orelse return error.UiNoDisplay;
        const auth = w.readCookie(number);
        w.out.clearRetainingCapacity();
        try wire.setupRequest(&w.out, w.arena, auth);
        try w.flush();
        var header: [8]u8 = undefined; // SAFETY: filled by readExact.
        try w.readExact(&header);
        const total = wire.setupLength(&header);
        const reply = try w.arena.alloc(u8, total);
        @memcpy(reply[0..8], &header);
        try w.readExact(reply[8..]);
        w.setup = try wire.parseSetup(reply);
    }

    fn readCookie(w: *Window, number: u32) ?[]const u8 {
        const path = w.environ.get("XAUTHORITY") orelse blk: {
            const home = w.environ.get("HOME") orelse return null;
            break :blk std.fmt.allocPrint(w.arena, "{s}/.Xauthority", .{home}) catch return null;
        };
        const file = readFile(w.arena, path) orelse return null;
        return wire.findCookie(file, number);
    }

    fn id(w: *Window, n: u32) u32 {
        return w.setup.id_base | (n & w.setup.id_mask);
    }

    fn flush(w: *Window) Error!void {
        var sent: usize = 0;
        // loop-bound: each write sends at least one byte or fails.
        while (sent < w.out.items.len) {
            const rest = w.out.items[sent..];
            const n = ok(
                linux.write(w.fd, rest.ptr, rest.len),
            ) orelse return error.UiX11ConnectionLost;
            if (n == 0) return error.UiX11ConnectionLost;
            sent += n;
        }
        w.out.clearRetainingCapacity();
    }

    fn readExact(w: *Window, buffer: []u8) Error!void {
        var got: usize = 0;
        // loop-bound: each read returns at least one byte or ends the connection.
        while (got < buffer.len) {
            const rest = buffer[got..];
            const n = ok(
                linux.read(w.fd, rest.ptr, rest.len),
            ) orelse return error.UiX11ConnectionLost;
            if (n == 0) return error.UiX11ConnectionLost;
            got += n;
        }
    }

    /// Reads what the socket has into `in` (blocking until at least one byte).
    fn fill(w: *Window) Error!void {
        if (w.in_len == w.in.len) return error.UiX11Protocol;
        const rest = w.in[w.in_len..];
        const n = ok(linux.read(w.fd, rest.ptr, rest.len)) orelse return error.UiX11ConnectionLost;
        if (n == 0) return error.UiX11ConnectionLost;
        w.in_len += n;
    }

    /// The next whole packet from `in`, copied to the arena. A reply larger than `in` (GetImage)
    /// is completed by reading its remainder straight from the socket.
    fn takePacket(w: *Window) Error!?[]const u8 {
        const len = wire.packetLength(w.in[0..w.in_len]) orelse {
            if (w.in_len < 32 or w.in[0] != 1) return null;
            const extra = std.mem.readInt(u32, w.in[4..8], .little);
            const total = 32 + @as(u64, extra) * 4;
            if (total <= w.in.len) return null;
            if (total > max_reply) return error.UiX11Protocol;
            const size = std.math.cast(usize, total) orelse return error.UiX11Protocol;
            const reply = try w.arena.alloc(u8, size);
            @memcpy(reply[0..w.in_len], w.in[0..w.in_len]);
            try w.readExact(reply[w.in_len..]);
            w.in_len = 0;
            return reply;
        };
        const packet = try w.arena.dupe(u8, w.in[0..len]);
        std.mem.copyForwards(u8, w.in[0 .. w.in_len - len], w.in[len..w.in_len]);
        w.in_len -= len;
        return packet;
    }

    /// Sends the buffered request and waits for its reply; events seen meanwhile are queued.
    fn roundTrip(w: *Window) Error![]const u8 {
        try w.flush();
        // loop-bound: ends with the reply, an error packet, or a lost connection.
        while (true) {
            while (try w.takePacket()) |packet| {
                switch (wire.decode(packet)) {
                    .reply => return packet,
                    .failure => |f| return protocolError(f),
                    .event => |e| w.translate(e),
                }
            }
            try w.fill();
        }
    }

    fn intern(w: *Window, name: []const u8) Error!u32 {
        const len = std.math.cast(u16, name.len) orelse return error.UiX11Protocol;
        var b = try wire.Builder.begin(&w.out, w.arena, wire.opcode.intern_atom, 0);
        try b.u16le(len);
        try b.u16le(0);
        try b.bytes(name);
        try b.finish();
        return wire.atomOf(try w.roundTrip());
    }

    fn keyboardMapping(w: *Window) Error!wire.Keymap {
        const min = w.setup.min_keycode;
        const count = std.math.cast(u8, @as(u16, w.setup.max_keycode) - min + 1) orelse 255;
        var b = try wire.Builder.begin(&w.out, w.arena, wire.opcode.get_keyboard_mapping, 0);
        try b.byte(min);
        try b.byte(count);
        try b.u16le(0);
        try b.finish();
        return wire.parseKeymap(try w.roundTrip(), min);
    }

    fn getProperty(w: *Window, window_id: u32, name: u32) Error![]const u8 {
        var b = try wire.Builder.begin(&w.out, w.arena, wire.opcode.get_property, 0);
        try b.u32le(window_id);
        try b.u32le(name);
        try b.u32le(0);
        try b.u32le(0);
        try b.u32le(1 << 16);
        try b.finish();
        return wire.propertyValue(try w.roundTrip());
    }

    /// `GDK_SCALE` (integer), else `Xft.dpi` from the root window's resources, else 100%.
    fn detectScale(w: *Window) Error!u16 {
        if (w.environ.get("GDK_SCALE")) |text| {
            const factor = std.fmt.parseInt(u16, text, 10) catch 1;
            return std.math.clamp(factor, 1, 4) * 100;
        }
        const resources = try w.getProperty(w.setup.root, wire.atom.resource_manager);
        return window.scaleForDpi(wire.xftDpi(resources) orelse 96);
    }

    fn device(w: *const Window, logical: i32) Error!u16 {
        const px = @divFloor(logical * @as(i32, w.scale_value) + 50, 100);
        return std.math.cast(u16, px) orelse error.UiX11Unsupported;
    }

    fn createWindow(w: *Window, title: []const u8) Error!void {
        w.window_id = w.id(1);
        w.gc = w.id(2);
        const width = try w.device(w.logical.w);
        const height = try w.device(w.logical.h);
        var b = try wire.Builder.begin(
            &w.out,
            w.arena,
            wire.opcode.create_window,
            w.setup.root_depth,
        );
        try b.u32le(w.window_id);
        try b.u32le(w.setup.root);
        try b.i16le(0);
        try b.i16le(0);
        try b.u16le(width);
        try b.u16le(height);
        try b.u16le(0);
        try b.u16le(1); // InputOutput
        try b.u32le(0); // CopyFromParent visual
        try b.u32le(0x2 | 0x800); // background-pixel, event-mask
        try b.u32le(0);
        try b.u32le(wire.event_mask);
        try b.finish();
        b = try wire.Builder.begin(&w.out, w.arena, wire.opcode.create_gc, 0);
        try b.u32le(w.gc);
        try b.u32le(w.window_id);
        try b.u32le(0);
        try b.finish();
        try w.setProperty(wire.atom.wm_name, wire.atom.string, 8, title);
        try w.setProperty(w.atoms.net_wm_name, w.atoms.utf8_string, 8, title);
        try w.setProperty(
            w.atoms.wm_protocols,
            wire.atom.atom_type,
            32,
            std.mem.asBytes(&w.atoms.wm_delete_window),
        );
        try w.sizeHints(width, height);
        b = try wire.Builder.begin(&w.out, w.arena, wire.opcode.map_window, 0);
        try b.u32le(w.window_id);
        try b.finish();
        try w.flush();
    }

    fn setProperty(w: *Window, name: u32, kind: u32, format: u8, data: []const u8) Error!void {
        const units = std.math.cast(u32, data.len / (format / 8)) orelse return error.UiX11Protocol;
        var b = try wire.Builder.begin(&w.out, w.arena, wire.opcode.change_property, 0);
        try b.u32le(w.window_id);
        try b.u32le(name);
        try b.u32le(kind);
        for ([_]u8{ format, 0, 0, 0 }) |v| try b.byte(v);
        try b.u32le(units);
        try b.bytes(data);
        try b.finish();
    }

    /// Fixed size: min = max = the client size (WM_NORMAL_HINTS).
    fn sizeHints(w: *Window, width: u16, height: u16) Error!void {
        var hints: [18]u32 = @splat(0);
        hints[0] = 16 | 32; // PMinSize | PMaxSize
        hints[5] = width;
        hints[6] = height;
        hints[7] = width;
        hints[8] = height;
        try w.setProperty(
            wire.atom.wm_normal_hints,
            wire.atom.wm_size_hints,
            32,
            std.mem.sliceAsBytes(&hints),
        );
    }

    fn resize(w: *Window) Error!void {
        const width = try w.device(w.logical.w);
        const height = try w.device(w.logical.h);
        try w.sizeHints(width, height);
        var b = try wire.Builder.begin(&w.out, w.arena, wire.opcode.configure_window, 0);
        try b.u32le(w.window_id);
        try b.u16le(0x4 | 0x8);
        try b.u16le(0);
        try b.u32le(width);
        try b.u32le(height);
        try b.finish();
        try w.flush();
    }

    pub fn scale(w: *const Window) u16 {
        return w.scale_value;
    }

    fn translate(w: *Window, e: wire.Event) void {
        switch (e) {
            .key => |k| if (wire.keyOf(w.keymap.keysym(k.keycode), k.shift)) |key| {
                w.queue.push(.{ .input = .{ .key = key } });
            },
            .button_press => |b| switch (b.button) {
                1 => w.queue.push(.{ .input = .{ .pointer_down = b.at } }),
                4, 5 => {
                    const step = @divFloor(48 * @as(i32, w.scale_value), 100);
                    const dy = if (b.button == 4) -step else step;
                    w.queue.push(.{ .input = .{ .wheel = .{ .at = b.at, .dy = dy } } });
                },
                else => {},
            },
            .button_release => |b| if (b.button == 1) {
                w.queue.push(.{ .input = .{ .pointer_up = b.at } });
            },
            .motion => |p| w.queue.push(.{ .input = .{ .pointer_move = p } }),
            .leave => w.queue.push(.{ .input = .pointer_leave }),
            .expose => w.queue.push(.redraw),
            .client_message => |m| if (m.message_type == w.atoms.wm_protocols and
                m.data0 == w.atoms.wm_delete_window) w.queue.push(.close),
            .configure, .property, .other => {},
        }
    }

    pub fn next(w: *Window, timeout_ms: ?u32) Error!window.Event {
        // loop-bound: returns on the first queued event, wake, timeout, or failure.
        while (true) {
            if (w.failed) |err| return err;
            if (w.queue.pop()) |event| return event;
            while (try w.takePacket()) |packet| switch (wire.decode(packet)) {
                .event => |e| w.translate(e),
                .failure => |f| return protocolError(f),
                .reply => {},
            };
            if (w.queue.len > 0) continue;
            var fds = [_]linux.pollfd{
                .{ .fd = w.fd, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = w.wake_pipe[0], .events = linux.POLL.IN, .revents = 0 },
            };
            const timeout: i32 = if (timeout_ms) |ms| std.math.cast(
                i32,
                ms,
            ) orelse std.math.maxInt(i32) else -1;
            const ready = ok(linux.poll(&fds, fds.len, timeout)) orelse continue;
            if (ready == 0) return .timeout;
            if (fds[1].revents != 0) {
                var drain: [64]u8 = undefined; // SAFETY: contents are discarded.
                // lint-allow(no-discard-call): only empties the pipe.
                _ = linux.read(
                    w.wake_pipe[0],
                    &drain,
                    drain.len,
                );
                return .wake;
            }
            if (fds[0].revents & (linux.POLL.HUP | linux.POLL.ERR) != 0) {
                return error.UiX11ConnectionLost;
            }
            try w.fill();
        }
    }

    pub fn present(w: *Window, c: *const render.Canvas) Error!void {
        const width = std.math.cast(u16, c.width) orelse return error.UiX11Unsupported;
        const height = std.math.cast(usize, c.height) orelse return error.UiX11Unsupported;
        w.shown = .{
            .w = width,
            .h = std.math.cast(u16, height) orelse return error.UiX11Unsupported,
        };
        const rows = wire.rowsPerPutImage(w.setup.max_request, width);
        var y: usize = 0;
        // loop-bound: one PutImage per strip of at most `rows` rows.
        while (y < height) : (y += rows) {
            const n = @min(rows, height - y);
            const strip = std.mem.sliceAsBytes(c.pixels[y * width ..][0 .. n * width]);
            var b = try wire.Builder.begin(&w.out, w.arena, wire.opcode.put_image, 2); // ZPixmap
            try b.u32le(w.window_id);
            try b.u32le(w.gc);
            try b.u16le(width);
            try b.u16le(std.math.cast(u16, n) orelse return error.UiX11Unsupported);
            try b.i16le(0);
            try b.i16le(std.math.cast(i16, y) orelse return error.UiX11Unsupported);
            try b.byte(0);
            try b.byte(w.setup.root_depth);
            try b.u16le(0);
            try b.bytes(strip);
            try b.finish();
            try w.flush();
        }
    }

    /// The window's pixels read back with GetImage; 0xAARRGGBB rows top-down. For the smoke test.
    pub fn snapshot(w: *Window, arena: std.mem.Allocator) Error!?render.Image {
        if (w.shown.w == 0 or w.shown.h == 0) return null;
        var b = try wire.Builder.begin(&w.out, w.arena, wire.opcode.get_image, 2); // ZPixmap
        try b.u32le(w.window_id);
        try b.i16le(0);
        try b.i16le(0);
        try b.u16le(w.shown.w);
        try b.u16le(w.shown.h);
        try b.u32le(0xFFFFFFFF);
        try b.finish();
        const reply = try w.roundTrip();
        const count = @as(usize, w.shown.w) * w.shown.h;
        if (reply.len < 32 + count * 4) return error.UiX11Protocol;
        const pixels = try arena.alloc(u32, count);
        for (pixels, 0..) |*p, i| {
            p.* = 0xFF000000 | std.mem.readInt(u32, reply[32 + i * 4 ..][0..4], .little);
        }
        return .{ .width = w.shown.w, .height = w.shown.h, .pixels = pixels };
    }

    pub fn waker(w: *Window) window.Waker {
        return .{ .context = w, .wake_fn = wake };
    }

    fn wake(context: *anyopaque) void {
        const w: *Window = @ptrCast(@alignCast(context));
        const byte = [_]u8{1};
        // A full pipe already holds a pending wake.
        _ = linux.write(w.wake_pipe[1], &byte, 1); // lint-allow(no-discard-call): see above.
    }

    /// No native picker on X11 (`capabilities`): the location field is edited in place.
    pub fn chooseFolder(
        w: *Window,
        arena: std.mem.Allocator,
        initial: []const u8,
    ) Error!?[]const u8 {
        _ = w;
        _ = arena;
        _ = initial;
        return null;
    }

    pub fn system(w: *const Window) window.System {
        const config = w.environ.get("XDG_CONFIG_HOME") orelse blk: {
            const home = w.environ.get("HOME") orelse break :blk null;
            break :blk std.fmt.allocPrint(w.arena, "{s}/.config", .{home}) catch null;
        };
        const ini = if (config) |dir| blk: {
            const path = std.fmt.allocPrint(w.arena, "{s}/gtk-3.0/settings.ini", .{dir}) catch
                break :blk "";
            break :blk readFile(w.arena, path) orelse "";
        } else "";
        const a = wire.appearance(ini, w.environ.get("GTK_THEME"));
        return .{
            .dark = a.dark,
            .high_contrast = a.high_contrast,
            .reduced_motion = a.reduced_motion,
        };
    }
};
