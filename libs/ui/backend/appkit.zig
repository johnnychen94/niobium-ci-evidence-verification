//! AppKit window through the Objective-C runtime C API (no ObjC compiler). One NSWindow with a
//! runtime-registered NSView subclass; the canvas is drawn as a CGImage in `drawRect:`.
//! Crash traps (docs/spec/platform-contract-v1.md): every call happens on the main thread
//! (`open` refuses otherwise), each loop turn runs inside an autorelease pool, ObjC methods
//! only queue events and never fail, and strings are checked before reaching NSString.

const std = @import("std");
const ui = @import("ui_core");
const render = @import("ui_render");
const window = @import("window.zig");

pub const capabilities: ui.env.Capabilities = .{ .native_folder_picker = true };

pub const Error = error{ OutOfMemory, UiNotMainThread, UiWindowFailed };

const Id = ?*anyopaque;
const Sel = ?*anyopaque;

const Point = extern struct { x: f64, y: f64 };
const Rect = extern struct { x: f64, y: f64, w: f64, h: f64 };

extern "objc" fn objc_getClass(name: [*:0]const u8) Id;
extern "objc" fn sel_registerName(name: [*:0]const u8) Sel;
extern "objc" fn objc_msgSend() void;
extern "objc" fn objc_allocateClassPair(superclass: Id, name: [*:0]const u8, extra: usize) Id;
extern "objc" fn objc_registerClassPair(class: Id) void;
extern "objc" fn class_addMethod(
    class: Id,
    name: Sel,
    imp: *const anyopaque,
    types: [*:0]const u8,
) u8;
extern "objc" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "objc" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;
extern "c" fn pthread_main_np() c_int;

extern var NSDefaultRunLoopMode: Id;
extern var NSAppearanceNameAqua: Id;
extern var NSAppearanceNameDarkAqua: Id;
extern var kCGColorSpaceSRGB: ?*const anyopaque;

extern fn CGColorSpaceCreateWithName(name: ?*const anyopaque) ?*anyopaque;
extern fn CGColorSpaceRelease(space: ?*anyopaque) void;
extern fn CGDataProviderCreateWithData(
    info: ?*anyopaque,
    data: *const anyopaque,
    size: usize,
    release: ?*const anyopaque,
) ?*anyopaque;
extern fn CGDataProviderRelease(provider: ?*anyopaque) void;
extern fn CGImageCreate(
    width: usize,
    height: usize,
    bits_per_component: usize,
    bits_per_pixel: usize,
    bytes_per_row: usize,
    space: ?*anyopaque,
    bitmap_info: u32,
    provider: ?*anyopaque,
    decode: ?*const f64,
    interpolate: bool,
    intent: i32,
) ?*anyopaque;
extern fn CGImageRelease(image: ?*anyopaque) void;
extern fn CGContextDrawImage(context: ?*anyopaque, rect: Rect, image: ?*anyopaque) void;
extern fn CGContextSaveGState(context: ?*anyopaque) void;
extern fn CGContextRestoreGState(context: ?*anyopaque) void;
extern fn CGContextTranslateCTM(context: ?*anyopaque, tx: f64, ty: f64) void;
extern fn CGContextScaleCTM(context: ?*anyopaque, sx: f64, sy: f64) void;
extern fn CGContextSetInterpolationQuality(context: ?*anyopaque, quality: i32) void;

/// `kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst`: the canvas's 0xAARRGGBB words.
const bitmap_info: u32 = (2 << 12) | 6;
const style_mask: u64 = 1 | 2 | 4; // titled, closable, miniaturizable
const event_application_defined: u64 = 15;
const wake_subtype: i16 = 0x4E62;
const modal_ok: i64 = 1;

/// `objc_msgSend` cast to `R (id, SEL, args...)`.
fn send(comptime R: type, target: Id, name: [*:0]const u8, args: anytype) R {
    const fields = @typeInfo(@TypeOf(args)).@"struct".field_types;
    const types = comptime blk: {
        var list: [fields.len + 2]type = undefined; // SAFETY: every slot is set here.
        list[0] = Id;
        list[1] = Sel;
        for (fields, 2..) |T, i| list[i] = T;
        const final = list;
        break :blk final;
    };
    const F = @Fn(&types, &@splat(.{}), R, .{ .@"callconv" = .c });
    const f: *const F = @ptrCast(&objc_msgSend);
    return @call(.auto, f, .{ target, sel_registerName(name) } ++ args);
}

fn class(name: [*:0]const u8) Id {
    return objc_getClass(name);
}

fn string(arena: std.mem.Allocator, text: []const u8) Error!Id {
    if (!std.unicode.utf8ValidateSlice(text)) return send(Id, class("NSString"), "string", .{});
    const z = try arena.dupeSentinel(u8, text, 0);
    return send(Id, class("NSString"), "stringWithUTF8String:", .{z.ptr});
}

/// The single open window; ObjC callbacks find it here (main thread only).
// lint-allow(no-global-var): ObjC method IMPs receive only `self`; one window per process.
var active: ?*Window = null;
// lint-allow(no-global-var): ObjC classes are registered once per process.
var classes_registered = false;

pub const Window = struct {
    app: Id = null,
    ns_window: Id = null,
    view: Id = null,
    delegate: Id = null,
    queue: window.Queue = .{},
    scale_value: u16 = 100,
    canvas: ?*const render.Canvas = null,

    pub fn open(
        w: *Window,
        arena: std.mem.Allocator,
        environ: *const std.process.Environ.Map,
        o: window.Options,
    ) Error!void {
        _ = environ;
        if (pthread_main_np() == 0) return error.UiNotMainThread;
        std.debug.assert(active == null);
        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);
        try registerClasses();
        w.* = .{ .app = send(Id, class("NSApplication"), "sharedApplication", .{}) };
        send(void, w.app, "setActivationPolicy:", .{@as(i64, 0)});
        send(void, w.app, "finishLaunching", .{});
        const rect: Rect = .{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(o.width),
            .h = @floatFromInt(o.height),
        };
        const alloc_window = send(Id, class("NSWindow"), "alloc", .{});
        w.ns_window = send(Id, alloc_window, "initWithContentRect:styleMask:backing:defer:", .{
            rect, style_mask, @as(u64, 2), @as(u8, 0),
        });
        if (w.ns_window == null) return error.UiWindowFailed;
        send(void, w.ns_window, "setReleasedWhenClosed:", .{@as(u8, 0)});
        send(void, w.ns_window, "setTitle:", .{try string(arena, o.title)});
        w.view = send(Id, send(Id, class("NiobiumView"), "alloc", .{}), "initWithFrame:", .{rect});
        w.delegate = send(Id, send(Id, class("NiobiumWindowDelegate"), "alloc", .{}), "init", .{});
        if (w.view == null or w.delegate == null) return error.UiWindowFailed;
        const area = send(Id, class("NSTrackingArea"), "alloc", .{});
        const tracking = send(Id, area, "initWithRect:options:owner:userInfo:", .{
            rect, @as(u64, 0x01 | 0x02 | 0x80 | 0x200), w.view, @as(Id, null),
        });
        send(void, w.view, "addTrackingArea:", .{tracking});
        send(void, tracking, "release", .{});
        send(void, w.ns_window, "setContentView:", .{w.view});
        send(void, w.ns_window, "setDelegate:", .{w.delegate});
        send(void, w.ns_window, "makeFirstResponder:", .{w.view});
        send(void, w.ns_window, "center", .{});
        send(void, w.ns_window, "makeKeyAndOrderFront:", .{@as(Id, null)});
        send(void, w.app, "activateIgnoringOtherApps:", .{@as(u8, 1)});
        active = w;
        w.scale_value = backingScale(w);
    }

    pub fn close(w: *Window) void {
        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);
        send(void, w.ns_window, "setDelegate:", .{@as(Id, null)});
        send(void, w.ns_window, "orderOut:", .{@as(Id, null)});
        send(void, w.ns_window, "close", .{});
        for ([_]Id{ w.view, w.delegate, w.ns_window }) |object| send(void, object, "release", .{});
        active = null;
        w.* = .{};
    }

    pub fn scale(w: *const Window) u16 {
        return w.scale_value;
    }

    /// Blocks for the next event, at most `timeout_ms` when given.
    pub fn next(w: *Window, timeout_ms: ?u32) Error!window.Event {
        // loop-bound: returns as soon as an AppKit event queued something or the wait ends.
        while (true) {
            if (w.queue.pop()) |event| return event;
            const pool = objc_autoreleasePoolPush();
            defer objc_autoreleasePoolPop(pool);
            const date = if (timeout_ms) |ms|
                send(Id, class("NSDate"), "dateWithTimeIntervalSinceNow:", .{
                    @as(f64, @floatFromInt(ms)) / 1000.0,
                })
            else
                send(Id, class("NSDate"), "distantFuture", .{});
            const event = send(Id, w.app, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{
                @as(u64, std.math.maxInt(u64)), date, NSDefaultRunLoopMode, @as(u8, 1),
            }) orelse return .timeout;
            if (send(u64, event, "type", .{}) == event_application_defined and
                send(i16, event, "subtype", .{}) == wake_subtype) return .wake;
            send(void, w.app, "sendEvent:", .{event});
        }
    }

    pub fn present(w: *Window, c: *const render.Canvas) Error!void {
        w.canvas = c;
        send(void, w.view, "display", .{});
    }

    /// What the view draws, read back through AppKit's own display cache (no screen-capture
    /// permission needed); 0xAARRGGBB rows top-down. For the smoke test.
    pub fn snapshot(w: *Window, arena: std.mem.Allocator) Error!?render.Image {
        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);
        const bounds = send(Rect, w.view, "bounds", .{});
        const rep = send(Id, w.view, "bitmapImageRepForCachingDisplayInRect:", .{bounds}) orelse
            return null;
        send(void, w.view, "cacheDisplayInRect:toBitmapImageRep:", .{ bounds, rep });
        const width: usize = @intCast(send(i64, rep, "pixelsWide", .{}));
        const height: usize = @intCast(send(i64, rep, "pixelsHigh", .{}));
        const row: usize = @intCast(send(i64, rep, "bytesPerRow", .{}));
        const samples: usize = @intCast(send(i64, rep, "samplesPerPixel", .{}));
        const data = send(?[*]const u8, rep, "bitmapData", .{}) orelse return null;
        if (samples < 3 or send(i64, rep, "bitsPerSample", .{}) != 8) return null;
        const pixels = try arena.alloc(u32, width * height);
        for (0..height) |y| {
            for (0..width) |x| {
                const p = data[y * row + x * samples ..];
                pixels[y * width + x] = 0xFF000000 | @as(
                    u32,
                    p[0],
                ) << 16 | @as(u32, p[1]) << 8 | p[2];
            }
        }
        return .{ .width = @intCast(width), .height = @intCast(height), .pixels = pixels };
    }

    pub fn waker(w: *Window) window.Waker {
        return .{ .context = w, .wake_fn = wake };
    }

    /// Any thread: posts an application-defined event that `next` turns into `.wake`.
    fn wake(context: *anyopaque) void {
        const w: *Window = @ptrCast(@alignCast(context));
        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);
        const sel_name = "otherEventWithType:location:modifierFlags:timestamp:windowNumber:" ++
            "context:subtype:data1:data2:";
        const event = send(Id, class("NSEvent"), sel_name, .{
            event_application_defined, Point{ .x = 0, .y = 0 }, @as(u64, 0),  @as(f64, 0),
            @as(i64, 0),               @as(Id, null),           wake_subtype, @as(i64, 0),
            @as(i64, 0),
        });
        send(void, w.app, "postEvent:atStart:", .{ event, @as(u8, 0) });
    }

    pub fn system(w: *const Window) window.System {
        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);
        const appearance = send(Id, w.app, "effectiveAppearance", .{});
        var names = [_]Id{ NSAppearanceNameAqua, NSAppearanceNameDarkAqua };
        const list = send(Id, class("NSArray"), "arrayWithObjects:count:", .{
            @as([*]Id, &names), @as(u64, names.len),
        });
        const best = send(Id, appearance, "bestMatchFromAppearancesWithNames:", .{list});
        const workspace = send(Id, class("NSWorkspace"), "sharedWorkspace", .{});
        return .{
            .dark = best != null and
                send(u8, best, "isEqualToString:", .{NSAppearanceNameDarkAqua}) != 0,
            .high_contrast = send(
                u8,
                workspace,
                "accessibilityDisplayShouldIncreaseContrast",
                .{},
            ) != 0,
            .reduced_motion = send(
                u8,
                workspace,
                "accessibilityDisplayShouldReduceMotion",
                .{},
            ) != 0,
        };
    }

    /// NSOpenPanel for one directory, starting next to `initial`; null when dismissed.
    pub fn chooseFolder(
        w: *Window,
        arena: std.mem.Allocator,
        initial: []const u8,
    ) Error!?[]const u8 {
        _ = w;
        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);
        const panel = send(Id, class("NSOpenPanel"), "openPanel", .{});
        send(void, panel, "setCanChooseFiles:", .{@as(u8, 0)});
        send(void, panel, "setCanChooseDirectories:", .{@as(u8, 1)});
        send(void, panel, "setCanCreateDirectories:", .{@as(u8, 1)});
        send(void, panel, "setAllowsMultipleSelection:", .{@as(u8, 0)});
        if (std.fs.path.dirname(initial)) |parent| {
            const url = send(Id, class("NSURL"), "fileURLWithPath:", .{try string(arena, parent)});
            send(void, panel, "setDirectoryURL:", .{url});
        }
        if (send(i64, panel, "runModal", .{}) != modal_ok) return null;
        const path = send(Id, send(Id, panel, "URL", .{}), "path", .{});
        const text = send(?[*:0]const u8, path, "UTF8String", .{}) orelse return null;
        return try arena.dupe(u8, std.mem.span(text));
    }
};

fn backingScale(w: *const Window) u16 {
    const factor = send(f64, w.ns_window, "backingScaleFactor", .{});
    return std.math.lossyCast(u16, @round(std.math.clamp(factor, 1, 4) * 100));
}

fn registerClasses() Error!void {
    if (classes_registered) return;
    const view = objc_allocateClassPair(class("NSView"), "NiobiumView", 0) orelse
        return error.UiWindowFailed;
    const methods = .{
        .{ "drawRect:", &drawRect, "v@:{CGRect={CGPoint=dd}{CGSize=dd}}" },
        .{ "isFlipped", &yes, "B@:" },
        .{ "acceptsFirstResponder", &yes, "B@:" },
        .{ "acceptsFirstMouse:", &yesFor, "B@:@" },
        .{ "mouseDown:", &mouseDown, "v@:@" },
        .{ "mouseUp:", &mouseUp, "v@:@" },
        .{ "mouseDragged:", &mouseMoved, "v@:@" },
        .{ "mouseMoved:", &mouseMoved, "v@:@" },
        .{ "mouseExited:", &mouseExited, "v@:@" },
        .{ "scrollWheel:", &scrollWheel, "v@:@" },
        .{ "keyDown:", &keyDown, "v@:@" },
        .{ "viewDidChangeBackingProperties", &backingChanged, "v@:" },
        .{ "viewDidChangeEffectiveAppearance", &appearanceChanged, "v@:" },
    };
    inline for (methods) |m| {
        if (class_addMethod(view, sel_registerName(m[0]), m[1], m[2]) == 0) {
            return error.UiWindowFailed;
        }
    }
    objc_registerClassPair(view);
    const delegate = objc_allocateClassPair(class("NSObject"), "NiobiumWindowDelegate", 0) orelse
        return error.UiWindowFailed;
    const should_close = sel_registerName("windowShouldClose:");
    if (class_addMethod(delegate, should_close, &windowShouldClose, "B@:@") == 0) {
        return error.UiWindowFailed;
    }
    objc_registerClassPair(delegate);
    classes_registered = true;
}

fn push(event: window.Event) void {
    if (active) |w| w.queue.push(event);
}

fn yes(_: Id, _: Sel) callconv(.c) u8 {
    return 1;
}

fn yesFor(_: Id, _: Sel, _: Id) callconv(.c) u8 {
    return 1;
}

fn windowShouldClose(_: Id, _: Sel, _: Id) callconv(.c) u8 {
    push(.close);
    return 0;
}

fn drawRect(self: Id, _: Sel, _: Rect) callconv(.c) void {
    const w = active orelse return;
    const c = w.canvas orelse return;
    const graphics = send(Id, class("NSGraphicsContext"), "currentContext", .{});
    const context = send(?*anyopaque, graphics, "CGContext", .{}) orelse return;
    const bounds = send(Rect, self, "bounds", .{});
    const width: usize = @intCast(c.width);
    const height: usize = @intCast(c.height);
    const space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    defer CGColorSpaceRelease(space);
    const provider = CGDataProviderCreateWithData(null, c.pixels.ptr, c.pixels.len * 4, null);
    defer CGDataProviderRelease(provider);
    const image = CGImageCreate(
        width,
        height,
        8,
        32,
        width * 4,
        space,
        bitmap_info,
        provider,
        null,
        false,
        0,
    ) orelse
        return;
    defer CGImageRelease(image);
    CGContextSaveGState(context);
    defer CGContextRestoreGState(context);
    CGContextSetInterpolationQuality(context, 1);
    // The view is flipped; CGImage rows run bottom-up in user space.
    CGContextTranslateCTM(context, 0, bounds.h);
    CGContextScaleCTM(context, 1, -1);
    CGContextDrawImage(context, .{ .x = 0, .y = 0, .w = bounds.w, .h = bounds.h }, image);
}

/// The event's position in device pixels of the flipped view.
fn location(self: Id, event: Id) ui.geometry.Point {
    const in_window = send(Point, event, "locationInWindow", .{});
    const p = send(Point, self, "convertPoint:fromView:", .{ in_window, @as(Id, null) });
    const factor: f64 = if (active) |w| @floatFromInt(w.scale_value) else 100;
    return .{
        .x = std.math.lossyCast(i32, @floor(p.x * factor / 100)),
        .y = std.math.lossyCast(i32, @floor(p.y * factor / 100)),
    };
}

fn mouseDown(self: Id, _: Sel, event: Id) callconv(.c) void {
    push(.{ .input = .{ .pointer_down = location(self, event) } });
}

fn mouseUp(self: Id, _: Sel, event: Id) callconv(.c) void {
    push(.{ .input = .{ .pointer_up = location(self, event) } });
}

fn mouseMoved(self: Id, _: Sel, event: Id) callconv(.c) void {
    push(.{ .input = .{ .pointer_move = location(self, event) } });
}

fn mouseExited(_: Id, _: Sel, _: Id) callconv(.c) void {
    push(.{ .input = .pointer_leave });
}

fn scrollWheel(self: Id, _: Sel, event: Id) callconv(.c) void {
    const delta = send(f64, event, "scrollingDeltaY", .{});
    const precise = send(u8, event, "hasPreciseScrollingDeltas", .{}) != 0;
    const points = if (precise) delta else delta * 16;
    const factor: f64 = if (active) |w| @floatFromInt(w.scale_value) else 100;
    const dy = std.math.lossyCast(i32, @round(-points * factor / 100));
    if (dy != 0) push(.{ .input = .{ .wheel = .{ .at = location(self, event), .dy = dy } } });
}

const flag_shift: u64 = 1 << 17;
const flag_command: u64 = 1 << 20;

fn keyDown(_: Id, _: Sel, event: Id) callconv(.c) void {
    const code = send(u16, event, "keyCode", .{});
    const flags = send(u64, event, "modifierFlags", .{});
    if (flags & flag_command != 0) {
        // Cmd+Q, Cmd+W close; Cmd+. is Escape.
        switch (code) {
            12, 13 => push(.close),
            47 => push(.{ .input = .{ .key = .escape } }),
            else => {},
        }
        return;
    }
    const key: ui.input.Key = switch (code) {
        48 => if (flags & flag_shift != 0) .shift_tab else .tab,
        36, 76 => .enter,
        49 => .space,
        53 => .escape,
        123 => .left,
        124 => .right,
        125 => .down,
        126 => .up,
        else => return,
    };
    push(.{ .input = .{ .key = key } });
}

fn backingChanged(_: Id, _: Sel) callconv(.c) void {
    const w = active orelse return;
    const next_scale = backingScale(w);
    if (next_scale == w.scale_value) return;
    w.scale_value = next_scale;
    push(.{ .scale = next_scale });
}

fn appearanceChanged(_: Id, _: Sel) callconv(.c) void {
    push(.appearance);
}
