//! Win32 window: one top-level window, the canvas blitted with `SetDIBitsToDevice` (a top-down
//! 32-bit DIB is the canvas's BGRA layout). Per-monitor DPI v2 comes from the application
//! manifest (apps/setup/setup.manifest). Crash traps (docs/spec/platform-contract-v1.md): the
//! wndproc never propagates an error (it queues events or stores the failure for `next`).
//! The folder dialog is in win32_dialog.zig.

const std = @import("std");
const ui = @import("ui_core");
const render = @import("ui_render");
const window = @import("window.zig");
const dialog = @import("win32_dialog.zig");

pub const capabilities: ui.env.Capabilities = .{ .native_folder_picker = true };

pub const Error = error{ OutOfMemory, UiWindowFailed, InvalidUtf8 };

const HWND = *opaque {};
const HDC = *opaque {};
const HINSTANCE = *opaque {};
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const BOOL = i32;
const HRESULT = i32;
const WNDPROC = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const WNDCLASSEXW = extern struct {
    size: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    proc: WNDPROC,
    class_extra: i32 = 0,
    window_extra: i32 = 0,
    instance: ?HINSTANCE,
    icon: ?*anyopaque = null,
    cursor: ?*anyopaque = null,
    background: ?*anyopaque = null,
    menu_name: ?[*:0]const u16 = null,
    class_name: [*:0]const u16,
    icon_small: ?*anyopaque = null,
};

const POINT = extern struct { x: i32, y: i32 };
const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

const MSG = extern struct {
    hwnd: ?HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
    time: u32,
    pt: POINT,
    private: u32,
};

const PAINTSTRUCT = extern struct {
    hdc: ?HDC,
    erase: BOOL,
    paint: RECT,
    restore: BOOL,
    inc_update: BOOL,
    reserved: [32]u8,
};

const BITMAPINFOHEADER = extern struct {
    size: u32 = @sizeOf(BITMAPINFOHEADER),
    width: i32,
    height: i32,
    planes: u16 = 1,
    bit_count: u16 = 32,
    compression: u32 = 0, // BI_RGB
    size_image: u32 = 0,
    x_ppm: i32 = 0,
    y_ppm: i32 = 0,
    clr_used: u32 = 0,
    clr_important: u32 = 0,
};

const CREATESTRUCTW = extern struct {
    create_params: ?*anyopaque,
    // The remaining fields are never read.
};

const TRACKMOUSEEVENT = extern struct {
    size: u32 = @sizeOf(TRACKMOUSEEVENT),
    flags: u32,
    hwnd: HWND,
    hover_time: u32 = 0,
};

const HIGHCONTRASTW = extern struct {
    size: u32 = @sizeOf(HIGHCONTRASTW),
    flags: u32 = 0,
    scheme: ?[*:0]u16 = null,
};

extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?HINSTANCE;
extern "user32" fn RegisterClassExW(class: *const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(
    ex_style: u32,
    class_name: [*:0]const u16,
    title: [*:0]const u16,
    style: u32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    parent: ?HWND,
    menu: ?*anyopaque,
    instance: ?HINSTANCE,
    param: ?*anyopaque,
) callconv(.winapi) ?HWND;
extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn ShowWindow(hwnd: HWND, cmd: i32) callconv(.winapi) BOOL;
extern "user32" fn DefWindowProcW(
    hwnd: HWND,
    msg: u32,
    w: WPARAM,
    l: LPARAM,
) callconv(.winapi) LRESULT;
extern "user32" fn PeekMessageW(
    msg: *MSG,
    hwnd: ?HWND,
    min: u32,
    max: u32,
    remove: u32,
) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(msg: *const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) LRESULT;
extern "user32" fn PostMessageW(hwnd: HWND, msg: u32, w: WPARAM, l: LPARAM) callconv(.winapi) BOOL;
extern "user32" fn MsgWaitForMultipleObjectsEx(
    count: u32,
    handles: ?*const anyopaque,
    timeout: u32,
    wake_mask: u32,
    flags: u32,
) callconv(.winapi) u32;
extern "user32" fn BeginPaint(hwnd: HWND, ps: *PAINTSTRUCT) callconv(.winapi) ?HDC;
extern "user32" fn EndPaint(hwnd: HWND, ps: *const PAINTSTRUCT) callconv(.winapi) BOOL;
extern "user32" fn GetDC(hwnd: HWND) callconv(.winapi) ?HDC;
extern "user32" fn ReleaseDC(hwnd: HWND, hdc: HDC) callconv(.winapi) i32;
extern "user32" fn InvalidateRect(
    hwnd: HWND,
    rect: ?*const RECT,
    erase: BOOL,
) callconv(.winapi) BOOL;
extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(.winapi) u32;
extern "user32" fn GetDpiForSystem() callconv(.winapi) u32;
extern "user32" fn AdjustWindowRectExForDpi(
    rect: *RECT,
    style: u32,
    menu: BOOL,
    ex_style: u32,
    dpi: u32,
) callconv(.winapi) BOOL;
extern "user32" fn SetWindowPos(
    hwnd: HWND,
    after: ?HWND,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    flags: u32,
) callconv(.winapi) BOOL;
extern "user32" fn SetWindowLongPtrW(hwnd: HWND, index: i32, value: isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongPtrW(hwnd: HWND, index: i32) callconv(.winapi) isize;
extern "user32" fn ScreenToClient(hwnd: HWND, point: *POINT) callconv(.winapi) BOOL;
extern "user32" fn SetCapture(hwnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
extern "user32" fn TrackMouseEvent(track: *TRACKMOUSEEVENT) callconv(.winapi) BOOL;
extern "user32" fn GetKeyState(key: i32) callconv(.winapi) i16;
extern "user32" fn LoadCursorW(instance: ?HINSTANCE, name: usize) callconv(.winapi) ?*anyopaque;
extern "user32" fn SystemParametersInfoW(
    action: u32,
    param: u32,
    data: ?*anyopaque,
    ini: u32,
) callconv(.winapi) BOOL;
extern "user32" fn GetSystemMetricsForDpi(index: i32, dpi: u32) callconv(.winapi) i32;
extern "gdi32" fn SetDIBitsToDevice(
    hdc: HDC,
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    src_x: i32,
    src_y: i32,
    start_scan: u32,
    lines: u32,
    bits: *const anyopaque,
    info: *const BITMAPINFOHEADER,
    usage: u32,
) callconv(.winapi) i32;
extern "dwmapi" fn DwmSetWindowAttribute(
    hwnd: HWND,
    attribute: u32,
    value: *const anyopaque,
    size: u32,
) callconv(.winapi) HRESULT;
extern "advapi32" fn RegGetValueW(
    key: usize,
    sub_key: [*:0]const u16,
    value: [*:0]const u16,
    flags: u32,
    kind: ?*u32,
    data: ?*anyopaque,
    size: ?*u32,
) callconv(.winapi) i32;

const WM_PAINT = 0x000F;
const WM_CLOSE = 0x0010;
const WM_ERASEBKGND = 0x0014;
const WM_SETTINGCHANGE = 0x001A;
const WM_NCCREATE = 0x0081;
const WM_KEYDOWN = 0x0100;
const WM_SYSKEYDOWN = 0x0104;
const WM_MOUSEMOVE = 0x0200;
const WM_LBUTTONDOWN = 0x0201;
const WM_LBUTTONUP = 0x0202;
const WM_MOUSEWHEEL = 0x020A;
const WM_MOUSELEAVE = 0x02A3;
const WM_DPICHANGED = 0x02E0;
const WM_THEMECHANGED = 0x031A;
const WM_APP_WAKE = 0x8000 + 0x4E;

const style: u32 = 0x00C00000 | 0x00080000 | 0x00020000; // caption, sysmenu, minimizebox
const GWLP_USERDATA = -21;
const PM_REMOVE = 1;
const QS_ALLINPUT = 0x04FF;
const MWMO_INPUTAVAILABLE = 0x0004;
const INFINITE: u32 = 0xFFFFFFFF;
const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("NiobiumWindow");

pub const Window = struct {
    hwnd: ?HWND = null,
    queue: window.Queue = .{},
    scale_value: u16 = 100,
    canvas: ?*const render.Canvas = null,
    tracking: bool = false,
    logical: window.Size = .{ .w = 0, .h = 0 },

    pub fn open(
        w: *Window,
        arena: std.mem.Allocator,
        environ: *const std.process.Environ.Map,
        o: window.Options,
    ) Error!void {
        _ = environ;
        w.* = .{ .logical = .{ .w = o.width, .h = o.height } };
        const instance = GetModuleHandleW(null);
        const class: WNDCLASSEXW = .{
            .proc = wndproc,
            .instance = instance,
            .cursor = LoadCursorW(null, 32512), // IDC_ARROW
            .class_name = class_name,
        };
        // A second registration fails with "class already exists", which is fine.
        if (RegisterClassExW(&class) == 0) std.log.debug("window class already registered", .{});
        const title = try std.unicode.utf8ToUtf16LeAllocZ(arena, o.title);
        const dpi = GetDpiForSystem();
        const outer = outerSize(w.logical, dpi);
        w.hwnd = CreateWindowExW(
            0,
            class_name,
            title,
            style,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            outer.w,
            outer.h,
            null,
            null,
            instance,
            w,
        ) orelse
            return error.UiWindowFailed;
        w.scale_value = window.scaleForDpi(GetDpiForWindow(w.hwnd.?));
        w.resizeForDpi(GetDpiForWindow(w.hwnd.?));
        w.applyDarkTitleBar();
        // lint-allow(no-discard-call): returns the previous visibility.
        _ = ShowWindow(
            w.hwnd.?,
            1,
        );
    }

    pub fn close(w: *Window) void {
        if (w.hwnd) |hwnd| {
            // lint-allow(no-discard-call): previous value.
            _ = SetWindowLongPtrW(
                hwnd,
                GWLP_USERDATA,
                0,
            );
            // lint-allow(no-discard-call): nothing to do on failure at exit.
            _ = DestroyWindow(
                hwnd,
            );
        }
        w.* = .{};
    }

    pub fn scale(w: *const Window) u16 {
        return w.scale_value;
    }

    fn resizeForDpi(w: *Window, dpi: u32) void {
        const outer = outerSize(w.logical, dpi);
        // lint-allow(no-discard-call): best effort; the canvas still fits.
        _ = SetWindowPos(
            w.hwnd.?,
            null,
            0,
            0,
            outer.w,
            outer.h,
            0x0002 | 0x0004 | 0x0010,
        );
    }

    fn applyDarkTitleBar(w: *Window) void {
        const dark: BOOL = @intFromBool(w.system().dark);
        // lint-allow(no-discard-call): older Windows ignores the attribute.
        _ = DwmSetWindowAttribute(
            w.hwnd.?,
            20,
            &dark,
            @sizeOf(BOOL),
        );
    }

    pub fn next(w: *Window, timeout_ms: ?u32) Error!window.Event {
        // loop-bound: returns once a message queued an event or the wait times out.
        while (true) {
            if (w.queue.pop()) |event| return event;
            var msg: MSG = undefined; // SAFETY: filled by PeekMessageW before it is read.
            if (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
                if (msg.message == WM_APP_WAKE) return .wake;
                // lint-allow(no-discard-call): reports whether a char was produced.
                _ = TranslateMessage(
                    &msg,
                );
                // lint-allow(no-discard-call): the wndproc result is for Windows.
                _ = DispatchMessageW(
                    &msg,
                );
                continue;
            }
            const wait = MsgWaitForMultipleObjectsEx(
                0,
                null,
                timeout_ms orelse INFINITE,
                QS_ALLINPUT,
                MWMO_INPUTAVAILABLE,
            );
            if (wait == 0x102) return .timeout; // WAIT_TIMEOUT
        }
    }

    pub fn present(w: *Window, c: *const render.Canvas) Error!void {
        w.canvas = c;
        const hwnd = w.hwnd orelse return;
        const hdc = GetDC(hwnd) orelse return error.UiWindowFailed;
        defer _ = ReleaseDC(hwnd, hdc); // lint-allow(no-discard-call): always 1 for a window DC.
        blit(hdc, c);
    }

    pub fn waker(w: *Window) window.Waker {
        return .{ .context = w, .wake_fn = wake };
    }

    fn wake(context: *anyopaque) void {
        const w: *Window = @ptrCast(@alignCast(context));
        const hwnd = w.hwnd orelse return;
        // lint-allow(no-discard-call): a full queue already holds a wake.
        _ = PostMessageW(
            hwnd,
            WM_APP_WAKE,
            0,
            0,
        );
    }

    pub fn system(w: *const Window) window.System {
        _ = w;
        var contrast: HIGHCONTRASTW = .{};
        const has_contrast = SystemParametersInfoW(
            0x0042,
            @sizeOf(HIGHCONTRASTW),
            &contrast,
            0,
        ) != 0;
        var animation: BOOL = 1;
        const has_animation = SystemParametersInfoW(0x1042, 0, &animation, 0) != 0;
        return .{
            .dark = !appsUseLightTheme(),
            .high_contrast = has_contrast and contrast.flags & 1 != 0,
            .reduced_motion = has_animation and animation == 0,
        };
    }

    pub fn chooseFolder(
        w: *Window,
        arena: std.mem.Allocator,
        initial: []const u8,
    ) Error!?[]const u8 {
        _ = initial;
        return dialog.chooseFolder(arena, w.hwnd);
    }
};

fn outerSize(logical: window.Size, dpi: u32) window.Size {
    const factor: i32 = @intCast(dpi);
    var r: RECT = .{
        .left = 0,
        .top = 0,
        .right = @divFloor(logical.w * factor + 48, 96),
        .bottom = @divFloor(logical.h * factor + 48, 96),
    };
    // lint-allow(no-discard-call): on failure the client size is used unadjusted.
    _ = AdjustWindowRectExForDpi(
        &r,
        style,
        0,
        0,
        dpi,
    );
    return .{ .w = r.right - r.left, .h = r.bottom - r.top };
}

fn blit(hdc: HDC, c: *const render.Canvas) void {
    const info: BITMAPINFOHEADER = .{ .width = c.width, .height = -c.height };
    const w: u32 = @intCast(c.width);
    const h: u32 = @intCast(c.height);
    // lint-allow(no-discard-call): a failed blit shows on the next paint.
    _ = SetDIBitsToDevice(
        hdc,
        0,
        0,
        w,
        h,
        0,
        0,
        0,
        h,
        c.pixels.ptr,
        &info,
        0,
    );
}

fn appsUseLightTheme() bool {
    const key = std.unicode.utf8ToUtf16LeStringLiteral(
        "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
    );
    const value = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");
    var data: u32 = 1;
    var size: u32 = @sizeOf(u32);
    const hkcu: usize = 0x80000001;
    if (RegGetValueW(
        hkcu,
        key,
        value,
        0x10,
        null,
        &data,
        &size,
    ) != 0) return true; // RRF_RT_REG_DWORD
    return data != 0;
}

fn from(hwnd: HWND) ?*Window {
    const raw = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (raw == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(raw)));
}

fn pointOf(l: LPARAM) ui.geometry.Point {
    const bits: usize = @bitCast(l);
    const x: i16 = @bitCast(@as(u16, @truncate(bits)));
    const y: i16 = @bitCast(@as(u16, @truncate(bits >> 16)));
    return .{ .x = x, .y = y };
}

fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT {
    if (msg == WM_NCCREATE) {
        const create: *const CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lp)));
        // lint-allow(no-discard-call): previous value is 0.
        _ = SetWindowLongPtrW(
            hwnd,
            GWLP_USERDATA,
            @bitCast(@intFromPtr(create.create_params)),
        );
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
    const w = from(hwnd) orelse return DefWindowProcW(hwnd, msg, wp, lp);
    switch (msg) {
        WM_CLOSE => w.queue.push(.close),
        WM_PAINT => paint(w, hwnd),
        WM_ERASEBKGND => return 1,
        WM_MOUSEMOVE => {
            if (!w.tracking) {
                var track: TRACKMOUSEEVENT = .{ .flags = 0x2, .hwnd = hwnd }; // TME_LEAVE
                w.tracking = TrackMouseEvent(&track) != 0;
            }
            w.queue.push(.{ .input = .{ .pointer_move = pointOf(lp) } });
        },
        WM_MOUSELEAVE => {
            w.tracking = false;
            w.queue.push(.{ .input = .pointer_leave });
        },
        WM_LBUTTONDOWN => {
            // lint-allow(no-discard-call): returns the previous capture window.
            _ = SetCapture(
                hwnd,
            );
            w.queue.push(.{ .input = .{ .pointer_down = pointOf(lp) } });
        },
        WM_LBUTTONUP => {
            _ = ReleaseCapture(); // lint-allow(no-discard-call): fails only without capture.
            w.queue.push(.{ .input = .{ .pointer_up = pointOf(lp) } });
        },
        WM_MOUSEWHEEL => wheel(w, hwnd, wp, lp),
        WM_KEYDOWN, WM_SYSKEYDOWN => if (keyOf(wp)) |key| {
            w.queue.push(.{ .input = .{ .key = key } });
        } else return DefWindowProcW(hwnd, msg, wp, lp),
        WM_DPICHANGED => {
            const dpi: u32 = @intCast(wp & 0xFFFF);
            w.scale_value = window.scaleForDpi(dpi);
            w.resizeForDpi(dpi);
            w.queue.push(.{ .scale = w.scale_value });
        },
        WM_SETTINGCHANGE, WM_THEMECHANGED => {
            w.applyDarkTitleBar();
            w.queue.push(.appearance);
            return DefWindowProcW(hwnd, msg, wp, lp);
        },
        else => return DefWindowProcW(hwnd, msg, wp, lp),
    }
    return 0;
}

fn paint(w: *Window, hwnd: HWND) void {
    var ps: PAINTSTRUCT = undefined; // SAFETY: filled by BeginPaint.
    const hdc = BeginPaint(hwnd, &ps) orelse return;
    if (w.canvas) |c| blit(hdc, c);
    _ = EndPaint(hwnd, &ps); // lint-allow(no-discard-call): always nonzero.
    w.queue.push(.redraw);
}

fn wheel(w: *Window, hwnd: HWND, wp: WPARAM, lp: LPARAM) void {
    const delta: i16 = @bitCast(@as(u16, @truncate(wp >> 16)));
    const screen = pointOf(lp);
    // Wheel positions are screen coordinates.
    var p: POINT = .{ .x = screen.x, .y = screen.y };
    if (ScreenToClient(hwnd, &p) == 0) return;
    // One notch (120) scrolls three 16-logical-pixel lines.
    const step = @divTrunc(-@as(i32, delta) * 3 * 16 * @as(i32, w.scale_value), 120 * 100);
    if (step == 0) return;
    w.queue.push(.{ .input = .{ .wheel = .{ .at = .{ .x = p.x, .y = p.y }, .dy = step } } });
}

fn keyOf(wp: WPARAM) ?ui.input.Key {
    return switch (wp) {
        0x09 => if (GetKeyState(0x10) < 0) .shift_tab else .tab,
        0x0D => .enter,
        0x20 => .space,
        0x1B => .escape,
        0x25 => .left,
        0x26 => .up,
        0x27 => .right,
        0x28 => .down,
        else => null,
    };
}
