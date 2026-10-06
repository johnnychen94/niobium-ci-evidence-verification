//! Mach-O 64: LC_LOAD_DYLIB family and segments mapped writable + executable.

const std = @import("std");
const bytes = @import("bytes.zig");

const magic_64 = 0xfeedfacf;
const lc_req_dyld = 0x8000_0000;
const lc_segment_64 = 0x19;
const lc_load_dylib = 0x0c;
const lc_load_weak_dylib = 0x18 | lc_req_dyld;
const lc_reexport_dylib = 0x1f | lc_req_dyld;
const lc_lazy_load_dylib = 0x20;
const lc_load_upward_dylib = 0x23 | lc_req_dyld;
const vm_prot_write = 0x2;
const vm_prot_execute = 0x4;
const max_commands = 512;

pub fn parse(arena: std.mem.Allocator, data: []const u8) !bytes.Facts {
    const image: bytes.Image = .{ .data = data };
    if (try image.int(u32, 0) != magic_64) return error.BinaryNotMacho;
    const command_count = try image.int(u32, 16);
    if (command_count > max_commands) return error.BinaryTooManyCommands;
    var deps: std.ArrayList([]const u8) = .empty;
    var rwx: std.ArrayList([]const u8) = .empty;
    var at: u64 = 32;
    for (0..command_count) |_| {
        const cmd = try image.int(u32, at);
        const size = try image.int(u32, at + 4);
        if (size < 8) return error.BinaryBadLoadCommand;
        switch (cmd) {
            lc_load_dylib,
            lc_load_weak_dylib,
            lc_reexport_dylib,
            lc_lazy_load_dylib,
            lc_load_upward_dylib,
            => {
                const name_offset = try image.int(u32, at + 8);
                if (name_offset >= size) return error.BinaryBadLoadCommand;
                try deps.append(arena, try image.cstr(at + name_offset, size - name_offset));
            },
            lc_segment_64 => {
                const name = try image.slice(at + 8, 16);
                const init_prot = try image.int(u32, at + 60);
                if (init_prot & vm_prot_write != 0 and init_prot & vm_prot_execute != 0) {
                    try rwx.append(arena, name[0 .. std.mem.findScalar(u8, name, 0) orelse 16]);
                }
            },
            else => {},
        }
        at += size;
    }
    return .{ .format = .macho, .dependencies = deps.items, .writable_executable = rwx.items };
}

test "rejects non-Mach-O input" {
    const data: [64]u8 = @splat(0);
    try std.testing.expectError(error.BinaryNotMacho, parse(std.testing.allocator, &data));
}
