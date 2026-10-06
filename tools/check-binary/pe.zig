//! PE/COFF: import DLLs, DllCharacteristics (ASLR, NX, high-entropy VA), RWX sections.

const std = @import("std");
const bytes = @import("bytes.zig");

const dll_dynamic_base = 0x0040;
const dll_high_entropy_va = 0x0020;
const dll_nx_compat = 0x0100;
const scn_mem_execute = 0x2000_0000;
const scn_mem_write = 0x8000_0000;
const max_sections = 96;
const max_imports = 512;

const Section = struct { name: []const u8, va: u32, virtual_size: u32, raw: u32, raw_size: u32 };

pub fn parse(arena: std.mem.Allocator, data: []const u8) !bytes.Facts {
    const image: bytes.Image = .{ .data = data };
    const pe_offset = try image.int(u32, 0x3c);
    if (!std.mem.eql(u8, try image.slice(pe_offset, 4), "PE\x00\x00")) return error.BinaryNotPe;
    const coff = @as(u64, pe_offset) + 4;
    const section_count = try image.int(u16, coff + 2);
    const optional_size = try image.int(u16, coff + 16);
    const optional = coff + 20;
    const magic = try image.int(u16, optional);
    const pe32_plus = magic == 0x20b;
    const characteristics = try image.int(u16, optional + 70);
    const data_dirs = optional + @as(u64, if (pe32_plus) 112 else 96);
    const import_rva = try image.int(u32, data_dirs + 8);

    if (section_count > max_sections) return error.BinaryTooManySections;
    const sections = try arena.alloc(Section, section_count);
    var rwx: std.ArrayList([]const u8) = .empty;
    const table = optional + optional_size;
    for (sections, 0..) |*section, index| {
        const at = table + index * 40;
        const raw_name = try image.slice(at, 8);
        section.* = .{
            .name = raw_name[0 .. std.mem.findScalar(u8, raw_name, 0) orelse 8],
            .virtual_size = try image.int(u32, at + 8),
            .va = try image.int(u32, at + 12),
            .raw_size = try image.int(u32, at + 16),
            .raw = try image.int(u32, at + 20),
        };
        const flags = try image.int(u32, at + 36);
        if (flags & scn_mem_execute != 0 and flags & scn_mem_write != 0) {
            try rwx.append(arena, section.name);
        }
    }
    return .{
        .format = .pe,
        .dependencies = try imports(arena, image, sections, import_rva),
        .writable_executable = rwx.items,
        .aslr = characteristics & dll_dynamic_base != 0,
        .dep_nx = characteristics & dll_nx_compat != 0,
        .high_entropy_va = !pe32_plus or characteristics & dll_high_entropy_va != 0,
    };
}

fn fileOffset(sections: []const Section, rva: u32) ?u64 {
    for (sections) |section| {
        const span = @max(section.virtual_size, section.raw_size);
        if (rva >= section.va and rva - section.va < span) {
            return @as(u64, section.raw) + (rva - section.va);
        }
    }
    return null;
}

fn imports(
    arena: std.mem.Allocator,
    image: bytes.Image,
    sections: []const Section,
    import_rva: u32,
) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    if (import_rva == 0) return names.items;
    const start = fileOffset(sections, import_rva) orelse return error.BinaryBadImportTable;
    for (0..max_imports) |index| {
        const descriptor = start + index * 20;
        const name_rva = try image.int(u32, descriptor + 12);
        if (name_rva == 0) return names.items;
        const name_offset = fileOffset(sections, name_rva) orelse return error.BinaryBadImportTable;
        try names.append(arena, try image.cstr(name_offset, 256));
    }
    return error.BinaryTooManyImports;
}

test "rejects non-PE input" {
    var data: [128]u8 = @splat(0);
    data[0x3c] = 0x40;
    try std.testing.expectError(error.BinaryNotPe, parse(std.testing.allocator, &data));
}
