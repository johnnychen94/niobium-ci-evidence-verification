//! CLI / ABI progress events (docs/spec/cli-v1.md#events): one JSON object per line, `schema: 1`.

const std = @import("std");

pub const Phase = enum {
    recover,
    discover,
    validate,
    resolve,
    plan,
    prepare,
    download,
    verify,
    execute,
    commit,
    bootstrap,
    verify_install,
    finalize,
    complete,
    @"error",
};

pub const Event = struct {
    phase: Phase,
    /// 0–1; null omits the field.
    progress: ?f32 = null,
    code: ?[]const u8 = null,
    message: ?[]const u8 = null,
    exit_code: ?u8 = null,
};

pub fn write(writer: *std.Io.Writer, event: Event) std.Io.Writer.Error!void {
    try writer.print("{{\"schema\":1,\"phase\":\"{s}\"", .{@tagName(event.phase)});
    if (event.progress) |progress| {
        const clamped = std.math.clamp(progress, 0, 1);
        try writer.print(",\"progress\":{d:.3}", .{clamped});
    }
    if (event.code) |code| {
        try writer.writeAll(",\"code\":");
        try std.json.Stringify.encodeJsonString(code, .{}, writer);
    }
    if (event.message) |message| {
        try writer.writeAll(",\"message\":");
        try std.json.Stringify.encodeJsonString(message, .{}, writer);
    }
    if (event.exit_code) |code| try writer.print(",\"exit_code\":{d}", .{code});
    try writer.writeAll("}\n");
}

test "N1-AC-09 events carry schema and phase" {
    var buffer: [256]u8 = undefined; // SAFETY: fixed writer scratch.
    var writer: std.Io.Writer = .fixed(&buffer);
    try write(&writer, .{ .phase = .download, .progress = 0.37 });
    try write(
        &writer,
        .{ .phase = .@"error", .code = "trust.hash_mismatch", .message = "m", .exit_code = 4 },
    );
    try std.testing.expectEqualStrings(
        \\{"schema":1,"phase":"download","progress":0.370}
        \\{"schema":1,"phase":"error","code":"trust.hash_mismatch","message":"m","exit_code":4}
        \\
    , writer.buffered());
}
