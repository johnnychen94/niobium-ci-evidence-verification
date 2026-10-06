//! Stable exit-code table (docs/spec/cli-v1.md#exit-codes). C ABI status = -code
//! (docs/spec/abi-v1.md). Errors are classified by exact name first, then by name prefix, so
//! every library declares errors with a category prefix (`Trust*`, `Manifest*`, `Repo*`, ...)
//! instead of a shared enum.

const std = @import("std");

pub const ExitCode = enum(u8) {
    ok = 0,
    internal = 1,
    usage = 2,
    validation = 3,
    trust = 4,
    network = 5,
    filesystem = 6,
    permission = 7,
    bootstrap_pending = 8,
    cancelled = 9,
    busy = 10,
    unsupported_schema = 11,
    not_installed = 12,
    unsupported_platform = 13,

    pub fn abiStatus(code: ExitCode) i32 {
        return -@as(i32, @backingInt(code));
    }

    /// Category used in JSON event codes: `<category>.<snake_error_name>`.
    pub fn category(code: ExitCode) []const u8 {
        return switch (code) {
            .ok => "ok",
            .internal => "internal",
            .usage => "usage",
            .validation => "validation",
            .trust => "trust",
            .network => "network",
            .filesystem => "fs",
            .permission => "permission",
            .bootstrap_pending => "bootstrap",
            .cancelled => "cancelled",
            .busy => "busy",
            .unsupported_schema => "schema",
            .not_installed => "not_installed",
            .unsupported_platform => "platform",
        };
    }
};

const exact = std.StaticStringMap(ExitCode).initComptime(.{
    // std filesystem and IO errors
    .{ "FileNotFound", .filesystem },            .{ "NoSpaceLeft", .filesystem },
    .{ "DiskQuota", .filesystem },               .{ "FileBusy", .filesystem },
    .{ "PathAlreadyExists", .filesystem },       .{ "NotDir", .filesystem },
    .{ "IsDir", .filesystem },                   .{ "NameTooLong", .filesystem },
    .{ "FileTooBig", .filesystem },              .{ "InputOutput", .filesystem },
    .{ "ReadOnlyFileSystem", .filesystem },      .{ "SharingViolation", .filesystem },
    .{ "BadPathName", .filesystem },             .{ "SymLinkLoop", .filesystem },
    .{ "DirNotEmpty", .filesystem },             .{ "LockViolation", .filesystem },
    .{ "StreamTooLong", .validation },           .{ "EndOfStream", .validation },
    // permissions
    .{ "AccessDenied", .permission },            .{ "PermissionDenied", .permission },
    // std.json strict decode
    .{ "SyntaxError", .validation },             .{ "UnexpectedEndOfInput", .validation },
    .{ "UnknownField", .validation },            .{ "DuplicateField", .validation },
    .{ "MissingField", .validation },            .{ "InvalidCharacter", .validation },
    .{ "InvalidNumber", .validation },           .{ "InvalidEnumTag", .validation },
    .{ "LengthMismatch", .validation },          .{ "ValueTooLong", .validation },
    .{ "UnexpectedToken", .validation },         .{ "BufferUnderrun", .validation },
    .{ "Overflow", .validation },
    // network and time
                   .{ "ConnectionRefused", .network },
    .{ "ConnectionResetByPeer", .network },      .{ "ConnectionTimedOut", .network },
    .{ "NetworkUnreachable", .network },         .{ "HostUnreachable", .network },
    .{ "Timeout", .network },                    .{ "UnknownHostName", .network },
    .{ "TemporaryNameServerFailure", .network },
    // cancellation and schema
    .{ "Canceled", .cancelled },
    .{ "Cancelled", .cancelled },                .{ "UnsupportedSchema", .unsupported_schema },
    .{ "InstallerTooOld", .unsupported_schema }, .{ "NotInstalled", .not_installed },
    .{ "TransactionBusy", .busy },               .{ "OutOfMemory", .internal },
    // spec-named errors without a category prefix
    .{ "ForbiddenField", .validation },          .{ "UnsafePath", .validation },
    .{ "DuplicateEntry", .validation },          .{ "ForbiddenEntryType", .validation },
    .{ "ArchiveBomb", .validation },             .{ "SignatureThreshold", .trust },
    .{ "Expired", .trust },                      .{ "RollbackAttack", .trust },
    .{ "HashMismatch", .trust },                 .{ "LengthMismatch", .trust },
    .{ "UnknownRole", .trust },                  .{ "PathNotDelegated", .trust },
    .{ "UnauthorizedArtifact", .trust },         .{ "ReleaseSequenceRegression", .trust },
    .{ "MetadataTooLarge", .trust },             .{ "UnsupportedSchema", .unsupported_schema },
});

const Prefix = struct { []const u8, ExitCode };

const prefixes = [_]Prefix{
    .{ "Usage", .usage },
    .{ "Manifest", .validation },
    .{ "Component", .validation },
    .{ "Json", .validation },
    .{ "Archive", .validation },
    .{ "Config", .validation },
    .{ "Resolve", .validation },
    .{ "Plan", .validation },
    .{ "Pack", .validation },
    .{ "Trust", .trust },
    .{ "Repo", .network },
    .{ "Http", .network },
    .{ "Network", .network },
    .{ "Fs", .filesystem },
    .{ "Journal", .filesystem },
    .{ "Privilege", .permission },
    .{ "Elevation", .permission },
    .{ "Bootstrap", .bootstrap_pending },
    .{ "Platform", .unsupported_platform },
    .{ "Capability", .unsupported_platform },
};

pub fn fromName(name: []const u8) ExitCode {
    if (exact.get(name)) |code| return code;
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix[0])) return prefix[1];
    }
    return .internal;
}

/// Classify any error value. Generic so pub signatures stay free of `anyerror`.
pub fn fromError(err: anytype) ExitCode {
    comptime std.debug.assert(@typeInfo(@TypeOf(err)) == .error_set);
    return fromName(@errorName(err));
}

/// Writes `<category>.<snake_case_name>` (e.g. `trust.hash_mismatch` for TrustHashMismatch).
pub fn eventCode(writer: *std.Io.Writer, err_name: []const u8) std.Io.Writer.Error!void {
    const code = fromName(err_name);
    try writer.writeAll(code.category());
    try writer.writeByte('.');
    const stem = stripCategoryPrefix(err_name);
    for (stem, 0..) |char, index| {
        if (std.ascii.isUpper(char)) {
            if (index > 0) try writer.writeByte('_');
            try writer.writeByte(std.ascii.toLower(char));
        } else {
            try writer.writeByte(char);
        }
    }
}

fn stripCategoryPrefix(name: []const u8) []const u8 {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix[0]) and name.len > prefix[0].len) {
            return name[prefix[0].len..];
        }
    }
    return name;
}

test "N1-AC-09 exit codes follow the stable table" {
    try std.testing.expectEqual(ExitCode.trust, fromError(error.TrustHashMismatch));
    try std.testing.expectEqual(ExitCode.validation, fromError(error.ManifestForbiddenField));
    try std.testing.expectEqual(ExitCode.filesystem, fromError(error.NoSpaceLeft));
    try std.testing.expectEqual(ExitCode.permission, fromError(error.AccessDenied));
    try std.testing.expectEqual(ExitCode.cancelled, fromError(error.Canceled));
    try std.testing.expectEqual(ExitCode.busy, fromError(error.TransactionBusy));
    try std.testing.expectEqual(ExitCode.internal, fromError(error.SomethingNobodyClassified));
    try std.testing.expectEqual(@as(u8, 4), @backingInt(ExitCode.trust));
    try std.testing.expectEqual(@as(u8, 13), @backingInt(ExitCode.unsupported_platform));
    try std.testing.expectEqual(@as(i32, -4), ExitCode.trust.abiStatus());
}

test "event code is category plus snake case" {
    var buffer: [64]u8 = undefined; // SAFETY: fixed writer scratch.
    var writer: std.Io.Writer = .fixed(&buffer);
    try eventCode(&writer, "TrustHashMismatch");
    try std.testing.expectEqualStrings("trust.hash_mismatch", writer.buffered());
}
