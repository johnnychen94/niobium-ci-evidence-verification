//! Post-build binary lint and size gate.
//!   nb-check-binary lint --target <name> --kind exe|dylib <file>
//!   nb-check-binary size --baseline <zon> --limit <bytes> [--write] (<name> <file>)...

const std = @import("std");
const repo = @import("repo");
const bytes = @import("bytes.zig");
const allowlist = @import("allowlist.zig");
const size = @import("size.zig");

const max_binary_bytes = 256 << 20;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return error.UsageMissingCommand;
    if (std.mem.eql(u8, args[1], "lint")) return lintCommand(arena, io, args[2..]);
    if (std.mem.eql(u8, args[1], "size")) return size.command(arena, io, args[2..]);
    if (std.mem.eql(u8, args[1], "dump") and args.len == 3) return dump(arena, io, args[2]);
    return error.UsageUnknownCommand;
}

fn lintCommand(arena: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    if (args.len != 5) return error.UsageLint;
    if (!std.mem.eql(u8, args[0], "--target") or !std.mem.eql(u8, args[2], "--kind")) {
        return error.UsageLint;
    }
    const target = args[1];
    const kind = std.meta.stringToEnum(allowlist.Kind, args[3]) orelse return error.UsageLint;
    const path = args[4];
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_binary_bytes));
    const facts = try parse(arena, data);
    var report: repo.Report = .{ .arena = arena, .tool = "check-binary" };
    try check(&report, target, kind, std.fs.path.basename(path), facts);
    try report.finish(io);
}

fn dump(arena: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_binary_bytes));
    const facts = try parse(arena, data);
    std.debug.print("{s}: {s}\n", .{ path, @tagName(facts.format) });
    for (facts.dependencies) |dependency| std.debug.print("  needs {s}\n", .{dependency});
    for (facts.writable_executable) |section| std.debug.print("  rwx {s}\n", .{section});
    std.debug.print("  exec_stack={} aslr={?} nx={?} high_entropy={?}\n", .{
        facts.executable_stack, facts.aslr, facts.dep_nx, facts.high_entropy_va,
    });
}

pub fn parse(arena: std.mem.Allocator, data: []const u8) !bytes.Facts {
    if (std.mem.startsWith(u8, data, "MZ")) return @import("pe.zig").parse(arena, data);
    if (std.mem.startsWith(u8, data, "\x7fELF")) return @import("elf.zig").parse(arena, data);
    if (std.mem.startsWith(
        u8,
        data,
        "\xcf\xfa\xed\xfe",
    )) return @import("macho.zig").parse(arena, data);
    return error.BinaryUnknownFormat;
}

pub fn check(
    report: *repo.Report,
    target: []const u8,
    kind: allowlist.Kind,
    name: []const u8,
    facts: bytes.Facts,
) !void {
    const rule = findRule(target, kind) orelse {
        return report.add(
            "{s}: no allowlist for target {s} ({s})",
            .{ name, target, @tagName(kind) },
        );
    };
    for (facts.dependencies) |dependency| {
        if (!allowed(rule, facts.format, dependency)) {
            try report.add("{s}: undeclared dynamic dependency {s}", .{ name, dependency });
        }
    }
    for (facts.writable_executable) |section| {
        try report.add("{s}: writable+executable section {s}", .{ name, section });
    }
    if (facts.executable_stack) try report.add("{s}: executable stack (PT_GNU_STACK)", .{name});
    if (facts.aslr == false) try report.add("{s}: PE without DYNAMICBASE (ASLR)", .{name});
    if (facts.dep_nx == false) try report.add("{s}: PE without NXCOMPAT (DEP)", .{name});
    if (facts.high_entropy_va == false) try report.add("{s}: PE without HIGHENTROPYVA", .{name});
}

fn findRule(target: []const u8, kind: allowlist.Kind) ?allowlist.Rule {
    for (allowlist.rules) |rule| {
        if (rule.kind == kind and std.mem.eql(u8, rule.target, target)) return rule;
    }
    return null;
}

fn allowed(rule: allowlist.Rule, format: bytes.Format, dependency: []const u8) bool {
    for (rule.dependencies) |entry| {
        const same = if (format == .pe)
            std.ascii.eqlIgnoreCase(entry, dependency)
        else
            std.mem.eql(u8, entry, dependency);
        if (same) return true;
    }
    return false;
}

test "policy flags undeclared deps, RWX and missing PE hardening" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var report: repo.Report = .{ .arena = arena_state.allocator(), .tool = "test" };
    try check(&report, "x86_64-windows", .exe, "setup.exe", .{
        .format = .pe,
        .dependencies = &.{ "KERNEL32.dll", "evil.dll" },
        .writable_executable = &.{".text"},
        .aslr = true,
        .dep_nx = false,
        .high_entropy_va = true,
    });
    try std.testing.expectEqual(@as(usize, 3), report.findings.items.len);
}

test "clean static ELF passes" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var report: repo.Report = .{ .arena = arena_state.allocator(), .tool = "test" };
    try check(&report, "x86_64-linux", .exe, "setup", .{
        .format = .elf,
        .dependencies = &.{},
        .writable_executable = &.{},
    });
    try std.testing.expectEqual(@as(usize, 0), report.findings.items.len);
}

test {
    _ = bytes;
    _ = @import("pe.zig");
    _ = @import("elf.zig");
    _ = @import("macho.zig");
    _ = size;
}
