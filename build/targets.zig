//! Target matrix. Shipping artifacts are ReleaseSafe (see ADR-0001, crash resistance).

const std = @import("std");

pub const CrossTarget = struct {
    /// Directory name under zig-out/cross/ and key in tools/check-binary allowlists.
    name: []const u8,
    query: std.Target.Query,
    /// Part of vm-smoke only; not a shipping target.
    smoke_only: bool = false,
};

pub const cross_targets = [_]CrossTarget{
    .{
        .name = "x86_64-windows",
        .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    },
    .{ .name = "aarch64-macos", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
    .{ .name = "x86_64-linux", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl } },
    .{
        .name = "aarch64-linux",
        .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
        .smoke_only = true,
    },
};

pub const shipping_optimize: std.lang.Optimize = .safe;

/// ELF shipping builds carry no DWARF (about 10 of 13 MB of a Linux `setup`); `zig objcopy`
/// cannot split it out on 0.17. Mach-O and PE keep debug info outside the executable already.
pub fn shippingStrip(target: std.Target) ?bool {
    return if (target.ofmt == .elf) true else null;
}

/// `setup` ReleaseSafe size budget per target (plan: at most 30 MiB).
pub const setup_size_limit_bytes: u64 = 30 * 1024 * 1024;
