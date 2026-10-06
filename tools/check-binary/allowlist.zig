//! Declared dynamic dependencies per target and artifact kind. Anything else is a gate failure
//! ("undeclared dynamic dependency = 0"). Windows names compare case-insensitively.

pub const Kind = enum { exe, dylib };

pub const Rule = struct {
    target: []const u8,
    kind: Kind,
    dependencies: []const []const u8,
};

const windows_system = [_][]const u8{
    "kernel32.dll",         "ntdll.dll", "advapi32.dll", "ws2_32.dll", "crypt32.dll", "bcrypt.dll",
    "bcryptprimitives.dll",
};

const windows_dylib = windows_system ++ [_][]const u8{"shell32.dll"};

const windows_gui = windows_system ++ [_][]const u8{
    "user32.dll", "gdi32.dll",  "shell32.dll", "ole32.dll", "comdlg32.dll", "uxtheme.dll",
    "dwmapi.dll", "shcore.dll",
};

const frameworks = "/System/Library/Frameworks/";

const macos_system = [_][]const u8{
    "/usr/lib/libSystem.B.dylib",
    frameworks ++ "CoreFoundation.framework/Versions/A/CoreFoundation",
    frameworks ++ "Security.framework/Versions/A/Security",
};

const macos_gui = macos_system ++ [_][]const u8{
    "/usr/lib/libobjc.A.dylib",
    frameworks ++ "AppKit.framework/Versions/C/AppKit",
    frameworks ++ "Foundation.framework/Versions/C/Foundation",
    frameworks ++ "CoreGraphics.framework/Versions/A/CoreGraphics",
};

pub const rules = [_]Rule{
    .{ .target = "x86_64-windows", .kind = .exe, .dependencies = &windows_gui },
    // shell32: `runas` elevation of the privilege helper (ShellExecuteExW).
    .{ .target = "x86_64-windows", .kind = .dylib, .dependencies = &windows_dylib },
    .{ .target = "aarch64-macos", .kind = .exe, .dependencies = &macos_gui },
    .{ .target = "aarch64-macos", .kind = .dylib, .dependencies = &macos_system },
    // Linux artifacts are static musl; X11 is spoken over the socket, not via libX11.
    .{ .target = "x86_64-linux", .kind = .exe, .dependencies = &.{} },
    .{ .target = "x86_64-linux", .kind = .dylib, .dependencies = &.{} },
    .{ .target = "aarch64-linux", .kind = .exe, .dependencies = &.{} },
    .{ .target = "aarch64-linux", .kind = .dylib, .dependencies = &.{} },
};
