//! Stable test identities shared by build selection and evidence validation.
const std = @import("std");

pub const Suite = enum { unit, conformance, e2e, sim, golden, fuzz, @"c-smoke" };
pub const Case = struct {
    id: []const u8,
    suite: Suite,
    acceptance: []const []const u8,
};
pub const cases = [_]Case{
    .{ .id = "host-user", .suite = .conformance, .acceptance = &.{"N1-AC-14"} },
    .{ .id = "host-machine", .suite = .conformance, .acceptance = &.{"N1-AC-14"} },
    .{
        .id = "online-lifecycle",
        .suite = .e2e,
        .acceptance = &.{ "N1-UJ-01", "N1-UJ-03", "N1-UJ-04", "N1-INV-06" },
    },
    .{ .id = "repair-uninstall", .suite = .e2e, .acceptance = &.{ "N1-UJ-05", "N1-UJ-06" } },
    .{ .id = "offline-bundle", .suite = .e2e, .acceptance = &.{"N1-UJ-07"} },
    .{ .id = "artifact-tampering", .suite = .e2e, .acceptance = &.{"N1-INV-05"} },
};

pub const contracts = [_][]const u8{
    "create_managed_file", "atomic_replace", "pointer_swap_recovery", "shortcut",
    "file_association",    "service",        "registration",          "free_space",
    "integration_names",
};

pub fn optional(contract: []const u8, os: []const u8) bool {
    if (std.mem.eql(u8, contract, "registration")) return true;
    if (std.mem.eql(u8, contract, "file_association")) return !std.mem.eql(u8, os, "linux");
    if (std.mem.eql(u8, contract, "service")) return std.mem.eql(u8, os, "windows");
    return false;
}

pub const Selection = struct {
    suites: std.EnumSet(Suite),
    case: ?[]const u8,

    pub fn parse(suites: ?[]const u8, case: ?[]const u8) error{InvalidSelection}!Selection {
        var selected: std.EnumSet(Suite) = .empty;
        var names = std.mem.splitScalar(u8, suites orelse "unit,conformance", ',');
        while (names.next()) |name| {
            const suite = std.meta.stringToEnum(Suite, name) orelse return error.InvalidSelection;
            if (selected.contains(suite)) return error.InvalidSelection;
            selected.insert(suite);
        }
        if (case) |id| {
            const found = find(id) orelse return error.InvalidSelection;
            if (!selected.contains(found.suite)) return error.InvalidSelection;
            selected = .initOne(found.suite);
        }
        return .{ .suites = selected, .case = case };
    }
};

pub fn find(id: []const u8) ?Case {
    for (cases) |case| if (std.mem.eql(u8, id, case.id)) return case;
    return null;
}

pub fn lane(suite: Suite) []const u8 {
    return switch (suite) {
        .unit => "L1/L2",
        .sim, .fuzz => "L2",
        .conformance => "L3",
        .e2e, .golden, .@"c-smoke" => "L4",
    };
}

pub fn validSeedRange(count: u32, start: u64) bool {
    return count > 0 and count <= 100_000 and
        start <= std.math.maxInt(u64) - (@as(u64, count) - 1);
}

test "N1-AC-20 selection fails closed and preserves the fast default" {
    const fast = try Selection.parse(null, null);
    try std.testing.expect(fast.suites.contains(.unit));
    try std.testing.expect(fast.suites.contains(.conformance));
    const one = try Selection.parse("e2e,conformance", "online-lifecycle");
    try std.testing.expectEqual(@as(usize, 1), one.suites.count());
    for ([_][]const u8{ "", "vm", "unit,", "sim,sim" }) |bad| {
        try std.testing.expectError(error.InvalidSelection, Selection.parse(bad, null));
    }
    try std.testing.expectError(error.InvalidSelection, Selection.parse("unit", "host-user"));
    try std.testing.expectError(error.InvalidSelection, Selection.parse("e2e", "missing"));
}
