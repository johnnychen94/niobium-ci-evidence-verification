//! Privilege broker and same-binary helper (ADR-0007, docs/spec/ipc-v1.md). The broker is a
//! `platform.Platform`; the helper serves the closed op set onto the host backend.

const std = @import("std");

pub const broker = @import("broker.zig");
pub const helper = @import("helper.zig");
pub const elevate = @import("elevate.zig");

pub const Broker = broker.Broker;
pub const Session = broker.Session;

pub const HelperArgs = struct {
    tx: []const u8,
    nonce: []const u8,
    /// Windows: the broker's named pipe; stdio otherwise.
    pipe: ?[]const u8 = null,
};

pub const ArgsError = error{PrivilegeBadArguments};

/// `--priv-helper-v1 --tx <tx> --nonce <32 hex> [--pipe <name>]`, nothing else.
pub fn parseHelperArgs(argv: []const []const u8) ArgsError!HelperArgs {
    if (argv.len == 0 or !std.mem.eql(u8, argv[0], "--priv-helper-v1")) {
        return error.PrivilegeBadArguments;
    }
    var tx: ?[]const u8 = null;
    var nonce: ?[]const u8 = null;
    var pipe: ?[]const u8 = null;
    var index: usize = 1;
    while (index < argv.len) : (index += 2) {
        if (index + 1 >= argv.len) return error.PrivilegeBadArguments;
        const value = argv[index + 1];
        const slot = if (std.mem.eql(u8, argv[index], "--tx"))
            &tx
        else if (std.mem.eql(u8, argv[index], "--nonce"))
            &nonce
        else if (std.mem.eql(u8, argv[index], "--pipe"))
            &pipe
        else
            return error.PrivilegeBadArguments;
        if (slot.* != null) return error.PrivilegeBadArguments;
        slot.* = value;
    }
    const n = nonce orelse return error.PrivilegeBadArguments;
    if (n.len != Session.nonce_len) return error.PrivilegeBadArguments;
    for (n) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) {
        return error.PrivilegeBadArguments;
    };
    const t = tx orelse return error.PrivilegeBadArguments;
    if (t.len == 0 or t.len > 64) return error.PrivilegeBadArguments;
    for (t) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return error.PrivilegeBadArguments;
    return .{ .tx = t, .nonce = n, .pipe = pipe };
}

test "helper arguments are closed" {
    const nonce = "0123456789abcdef0123456789abcdef";
    const ok = try parseHelperArgs(&.{ "--priv-helper-v1", "--tx", "tx-3-ab", "--nonce", nonce });
    try std.testing.expectEqualStrings("tx-3-ab", ok.tx);
    const bad = [_][]const []const u8{
        &.{},
        &.{ "--tx", "t", "--nonce", nonce },
        &.{ "--priv-helper-v1", "--tx", "t" },
        &.{ "--priv-helper-v1", "--tx", "t", "--nonce", "short" },
        &.{ "--priv-helper-v1", "--tx", "t;rm", "--nonce", nonce },
        &.{ "--priv-helper-v1", "--tx", "t", "--nonce", nonce, "--exec", "x" },
        &.{ "--priv-helper-v1", "--tx", "t", "--tx", "u", "--nonce", nonce },
    };
    for (bad) |argv| try std.testing.expectError(
        error.PrivilegeBadArguments,
        parseHelperArgs(argv),
    );
}

test {
    _ = broker;
    _ = helper;
    _ = elevate;
    _ = @import("privilege_test.zig");
}
