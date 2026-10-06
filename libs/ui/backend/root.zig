//! Window backends: AppKit, Win32, X11, offscreen; the session and event loop they share.

const std = @import("std");
const builtin = @import("builtin");
const tokens = @import("ui_tokens");

pub const window = @import("window.zig");
pub const session = @import("session.zig");
pub const driver = @import("driver.zig");
pub const offscreen = @import("offscreen.zig");
pub const fonts = @import("fonts.zig");
pub const host = @import("host.zig");
pub const x11_wire = @import("x11_wire.zig");
pub const Session = session.Session;

/// Platform tokens of the target OS.
pub const platform: tokens.Platform = switch (builtin.os.tag) {
    .macos => .macos,
    .windows => .windows,
    else => .linux,
};

/// The window backend of the target OS.
pub const native = switch (builtin.os.tag) {
    .macos => @import("appkit.zig"),
    .windows => @import("win32.zig"),
    .linux => @import("x11.zig"),
    else => @compileError("no window backend for this OS"),
};

test {
    _ = window;
    _ = session;
    _ = driver;
    _ = offscreen;
    _ = fonts;
    _ = host;
    _ = x11_wire;
    std.testing.refAllDecls(native);
    std.testing.refAllDecls(native.Window);
}
