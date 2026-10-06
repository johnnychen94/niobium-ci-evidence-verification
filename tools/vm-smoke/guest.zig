//! What vm-smoke knows about each guest: its VM name, OS, scratch directory, and how to run a
//! download or a mkdir there. Pure functions over `prlctl`/`prlsrvctl` text output.

const std = @import("std");

pub const Os = enum { windows, linux };

pub const Vm = struct {
    /// `prlctl` VM name.
    name: []const u8,
    /// `targets.cross_targets` name of the bundle it runs.
    target: []const u8,
    os: Os,
};

pub const vms = [_]Vm{
    .{ .name = "Windows 11", .target = "x86_64-windows", .os = .windows },
    .{ .name = "Ubuntu 24.04.3 ARM64", .target = "aarch64-linux", .os = .linux },
};

pub const State = enum { running, stopped, suspended, paused, other };

/// `prlctl status <vm>`: `VM <name> exist <state>`.
pub fn parseState(text: []const u8) State {
    const trimmed = std.mem.trim(u8, text, " \r\n");
    const space = std.mem.findScalarLast(u8, trimmed, ' ') orelse return .other;
    return std.meta.stringToEnum(State, trimmed[space + 1 ..]) orelse .other;
}

/// The host's address on the Parallels shared network (`prlsrvctl net info Shared`).
pub fn parseHostAddress(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_adapter = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.eql(u8, line, "Parallels adapter:")) {
            in_adapter = true;
        } else if (in_adapter) {
            const value = std.mem.cutPrefix(u8, line, "IPv4 address: ") orelse continue;
            return value;
        }
    }
    return null;
}

/// Scratch directory in the guest for one run.
pub fn scratch(arena: std.mem.Allocator, os: Os, run: []const u8) ![]const u8 {
    return switch (os) {
        .linux => std.fmt.allocPrint(arena, "/tmp/niobium-vm-smoke/{s}", .{run}),
        .windows => std.fmt.allocPrint(arena, "C:\\Users\\Public\\niobium-vm-smoke\\{s}", .{run}),
    };
}

/// `root` joined with a `/`-separated bundle path in the guest's separator.
pub fn join(arena: std.mem.Allocator, os: Os, root: []const u8, rel: []const u8) ![]const u8 {
    const native = switch (os) {
        .linux => rel,
        .windows => try std.mem.replaceOwned(u8, arena, rel, "/", "\\"),
    };
    const separator = if (os == .windows) "\\" else "/";
    return std.mem.concat(arena, u8, &.{ root, separator, native });
}

/// Guest argv that downloads `url` to `dest`, creating its directory.
pub fn fetch(
    arena: std.mem.Allocator,
    os: Os,
    url: []const u8,
    dest: []const u8,
) ![]const []const u8 {
    return switch (os) {
        .linux => try arena.dupe([]const u8, &.{
            "python3",
            "-c",
            "import os,sys,urllib.request;os.makedirs(os.path.dirname(sys.argv[2]),exist" ++
                "_ok=True);" ++
                "urllib.request.urlretrieve(sys.argv[1],sys.argv[2])",
            url,
            dest,
        }),
        .windows => try arena.dupe([]const u8, &.{
            "powershell.exe",
            "-NoProfile",
            "-Command",
            try std.fmt.allocPrint(
                arena,
                "New-Item -ItemType Directory -Force -Path (Split-Path '{s}') | Out-Null; " ++
                    "Invoke-WebRequest -UseBasicParsing -Uri '{s}' -OutFile '{s}'",
                .{ dest, url, dest },
            ),
        }),
    };
}

test "prlctl and prlsrvctl output parsing" {
    try std.testing.expectEqual(State.running, parseState("VM Windows 11 exist running\n"));
    try std.testing.expectEqual(State.suspended, parseState("VM Windows 11 exist suspended"));
    try std.testing.expectEqual(State.other, parseState("garbage"));
    const info = "Network ID: Shared\nParallels adapter:\n\tIPv4 address: 10.211.55.2\n" ++
        "DHCPv4 server:\n\tServer address: 10.211.55.1\n";
    try std.testing.expectEqualStrings("10.211.55.2", parseHostAddress(info).?);
    try std.testing.expect(parseHostAddress("Network ID: Shared\n") == null);
}

test "guest paths use the guest separator" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try scratch(a, .windows, "20261006T000000Z");
    try std.testing.expectEqualStrings(
        "C:\\Users\\Public\\niobium-vm-smoke\\20261006T000000Z\\repository\\metadata\\1.root.json",
        try join(a, .windows, root, "repository/metadata/1.root.json"),
    );
    try std.testing.expectEqualStrings(
        "/tmp/niobium-vm-smoke/r/setup",
        try join(a, .linux, try scratch(a, .linux, "r"), "setup"),
    );
}
