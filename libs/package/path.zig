//! Payload path rules: contracts' relative-path rules plus portability across NTFS, APFS and ext4.

const std = @import("std");
const contracts = @import("contracts");

pub const Error = error{UnsafePath};

const reserved = [_][]const u8{ "con", "prn", "aux", "nul" };
const reserved_numbered = [_][]const u8{ "com", "lpt" };

fn isReservedName(segment: []const u8) bool {
    const stem_len = std.mem.findScalar(u8, segment, '.') orelse segment.len;
    const stem = segment[0..stem_len];
    var lower: [4]u8 = undefined; // SAFETY: only the first stem.len bytes are read.
    if (stem.len < 3 or stem.len > lower.len) return false;
    const folded = std.ascii.lowerString(lower[0..stem.len], stem);
    for (reserved) |name| {
        if (std.mem.eql(u8, folded, name)) return true;
    }
    if (folded.len != 4 or folded[3] < '0' or folded[3] > '9') return false;
    for (reserved_numbered) |name| {
        if (std.mem.eql(u8, folded[0..3], name)) return true;
    }
    return false;
}

fn checkSegment(segment: []const u8) Error!void {
    for (segment) |c| {
        if (c < 0x20 or c == 0x7f) return error.UnsafePath;
        if (std.mem.findScalar(u8, "<>\"|?*", c) != null) return error.UnsafePath;
    }
    const last = segment[segment.len - 1];
    if (last == '.' or last == ' ') return error.UnsafePath;
    if (isReservedName(segment)) return error.UnsafePath;
}

pub fn check(path: []const u8, limits: contracts.Limits) Error!void {
    try contracts.ids.checkRelativePath(path, limits.path_bytes);
    var segments = std.mem.splitScalar(u8, path, '/');
    var count: usize = 0;
    while (segments.next()) |segment| {
        count += 1;
        if (count > limits.path_components) return error.UnsafePath;
        try checkSegment(segment);
    }
}

test "N1-INV-02 portable payload paths" {
    const limits: contracts.Limits = .{};
    const bad = [_][]const u8{
        "files/CON",     "files/aux.txt", "files/lpt1", "files/a.", "files/a ",
        "files/a\x01b",  "files/a|b",     "files/a?",   "../x",     "/abs",
        "files//double", "files/a/",
    };
    for (bad) |path| try std.testing.expectError(error.UnsafePath, check(path, limits));
    try check("files/bin/hello", limits);
    try check("files/console.txt", limits);
    try check("files/com10", limits);
    var deep: [64 * 2 + 1]u8 = @splat('a');
    var i: usize = 1;
    while (i < deep.len) : (i += 2) deep[i] = '/';
    try std.testing.expectError(error.UnsafePath, check(&deep, limits));
}
