//! The system folder dialog on Windows: `IFileDialog` with `FOS_PICKFOLDERS`. Crash traps
//! (docs/spec/platform-contract-v1.md): COM is initialized and released in pairs around the
//! dialog, and every COM pointer is released on all paths.

const std = @import("std");

const HRESULT = i32;

extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(
    clsid: *const Guid,
    outer: ?*anyopaque,
    context: u32,
    iid: *const Guid,
    out: *?*anyopaque,
) callconv(.winapi) HRESULT;
extern "ole32" fn CoTaskMemFree(ptr: ?*anyopaque) callconv(.winapi) void;

/// The chosen directory, or null when the dialog was dismissed or could not open.
pub fn chooseFolder(
    arena: std.mem.Allocator,
    owner: ?*anyopaque,
) error{OutOfMemory}!?[]const u8 {
    const hr = CoInitializeEx(null, 0x2 | 0x4); // apartment-threaded, no OLE1 DDE
    if (hr < 0) return null;
    defer CoUninitialize();
    return pickFolder(arena, owner);
}

const Guid = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };

const clsid_file_open_dialog: Guid = .{
    .a = 0xDC1C5A9C,
    .b = 0xE88A,
    .c = 0x4DDE,
    .d = .{ 0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7 },
};
const iid_file_dialog: Guid = .{
    .a = 0x42F85136,
    .b = 0xDB7E,
    .c = 0x439C,
    .d = .{ 0x85, 0xF1, 0xE4, 0x07, 0x5D, 0x13, 0x5F, 0xC8 },
};

/// IFileDialog vtable through `GetResult` (IUnknown, IModalWindow, IFileDialog order).
const FileDialogVtbl = extern struct {
    query_interface: *const anyopaque,
    add_ref: *const anyopaque,
    release: *const fn (*FileDialog) callconv(.winapi) u32,
    show: *const fn (*FileDialog, ?*anyopaque) callconv(.winapi) HRESULT,
    set_file_types: *const anyopaque,
    set_file_type_index: *const anyopaque,
    get_file_type_index: *const anyopaque,
    advise: *const anyopaque,
    unadvise: *const anyopaque,
    set_options: *const fn (*FileDialog, u32) callconv(.winapi) HRESULT,
    get_options: *const fn (*FileDialog, *u32) callconv(.winapi) HRESULT,
    set_default_folder: *const anyopaque,
    set_folder: *const anyopaque,
    get_folder: *const anyopaque,
    get_current_selection: *const anyopaque,
    set_file_name: *const anyopaque,
    get_file_name: *const anyopaque,
    set_title: *const anyopaque,
    set_ok_button_label: *const anyopaque,
    set_file_name_label: *const anyopaque,
    get_result: *const fn (*FileDialog, *?*ShellItem) callconv(.winapi) HRESULT,
};
const FileDialog = extern struct { vtbl: *const FileDialogVtbl };

/// IShellItem vtable through `GetDisplayName`.
const ShellItemVtbl = extern struct {
    query_interface: *const anyopaque,
    add_ref: *const anyopaque,
    release: *const fn (*ShellItem) callconv(.winapi) u32,
    bind_to_handler: *const anyopaque,
    get_parent: *const anyopaque,
    get_display_name: *const fn (*ShellItem, u32, *?[*:0]u16) callconv(.winapi) HRESULT,
};
const ShellItem = extern struct { vtbl: *const ShellItemVtbl };

const FOS_PICKFOLDERS = 0x20;
const FOS_FORCEFILESYSTEM = 0x40;
const SIGDN_FILESYSPATH: u32 = 0x80058000;

fn pickFolder(arena: std.mem.Allocator, owner: ?*anyopaque) error{OutOfMemory}!?[]const u8 {
    var raw: ?*anyopaque = null;
    const clsid = &clsid_file_open_dialog;
    if (CoCreateInstance(clsid, null, 1, &iid_file_dialog, &raw) < 0) return null;
    const file_dialog: *FileDialog = @ptrCast(@alignCast(raw orelse return null));
    // lint-allow(no-discard-call): the reference count.
    defer _ = file_dialog.vtbl.release(file_dialog);
    var options: u32 = 0;
    if (file_dialog.vtbl.get_options(file_dialog, &options) < 0) return null;
    if (file_dialog.vtbl.set_options(
        file_dialog,
        options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM,
    ) < 0) return null;
    if (file_dialog.vtbl.show(file_dialog, owner) < 0) return null; // includes "canceled"
    var item: ?*ShellItem = null;
    if (file_dialog.vtbl.get_result(file_dialog, &item) < 0) return null;
    const shell_item = item orelse return null;
    // lint-allow(no-discard-call): the reference count.
    defer _ = shell_item.vtbl.release(shell_item);
    var name: ?[*:0]u16 = null;
    if (shell_item.vtbl.get_display_name(shell_item, SIGDN_FILESYSPATH, &name) < 0) return null;
    const wide = name orelse return null;
    defer CoTaskMemFree(wide);
    return std.unicode.wtf16LeToWtf8Alloc(arena, std.mem.span(wide)) catch error.OutOfMemory;
}
