//! ELF64: DT_NEEDED, PT_LOAD with W+X, executable PT_GNU_STACK.

const std = @import("std");
const bytes = @import("bytes.zig");

const pt_load = 1;
const pt_dynamic = 2;
const pt_gnu_stack = 0x6474e551;
const pf_x = 1;
const pf_w = 2;
const dt_null = 0;
const dt_needed = 1;
const dt_strtab = 5;
const max_headers = 128;
const max_dynamic = 1024;

const Load = struct { vaddr: u64, offset: u64, filesz: u64 };

pub fn parse(arena: std.mem.Allocator, data: []const u8) !bytes.Facts {
    const image: bytes.Image = .{ .data = data };
    if (!std.mem.eql(u8, try image.slice(0, 4), "\x7fELF")) return error.BinaryNotElf;
    if ((try image.slice(4, 1))[0] != 2) return error.BinaryElfNot64Bit;
    const ph_offset = try image.int(u64, 32);
    const ph_size = try image.int(u16, 54);
    const ph_count = try image.int(u16, 56);
    if (ph_count > max_headers) return error.BinaryTooManyHeaders;
    var loads: std.ArrayList(Load) = .empty;
    var rwx: std.ArrayList([]const u8) = .empty;
    var dynamic: ?Load = null;
    var exec_stack = false;
    for (0..ph_count) |index| {
        const at = ph_offset + index * ph_size;
        const kind = try image.int(u32, at);
        const flags = try image.int(u32, at + 4);
        const segment: Load = .{
            .offset = try image.int(u64, at + 8),
            .vaddr = try image.int(u64, at + 16),
            .filesz = try image.int(u64, at + 32),
        };
        switch (kind) {
            pt_load => {
                try loads.append(arena, segment);
                if (flags & pf_w != 0 and flags & pf_x != 0) {
                    try rwx.append(arena, try arena.print("PT_LOAD@0x{x}", .{segment.vaddr}));
                }
            },
            pt_dynamic => dynamic = segment,
            pt_gnu_stack => exec_stack = flags & pf_x != 0,
            else => {},
        }
    }
    return .{
        .format = .elf,
        .dependencies = if (dynamic) |d| try needed(arena, image, loads.items, d) else &.{},
        .writable_executable = rwx.items,
        .executable_stack = exec_stack,
    };
}

fn fileOffset(loads: []const Load, vaddr: u64) ?u64 {
    for (loads) |load| {
        if (vaddr >= load.vaddr and vaddr - load.vaddr < load.filesz) {
            return load.offset + (vaddr - load.vaddr);
        }
    }
    return null;
}

fn needed(
    arena: std.mem.Allocator,
    image: bytes.Image,
    loads: []const Load,
    dynamic: Load,
) ![]const []const u8 {
    var strtab: ?u64 = null;
    var offsets: std.ArrayList(u64) = .empty;
    for (0..max_dynamic) |index| {
        const at = dynamic.offset + index * 16;
        if (index * 16 >= dynamic.filesz) break;
        const tag = try image.int(u64, at);
        const value = try image.int(u64, at + 8);
        switch (tag) {
            dt_null => break,
            dt_needed => try offsets.append(arena, value),
            dt_strtab => strtab = value,
            else => {},
        }
    }
    if (offsets.items.len == 0) return &.{};
    const table = fileOffset(loads, strtab orelse return error.BinaryBadDynamic) orelse
        return error.BinaryBadDynamic;
    const names = try arena.alloc([]const u8, offsets.items.len);
    for (offsets.items, names) |offset, *name| name.* = try image.cstr(table + offset, 256);
    return names;
}

test "rejects non-ELF input" {
    const data: [64]u8 = @splat(0);
    try std.testing.expectError(error.BinaryNotElf, parse(std.testing.allocator, &data));
}
