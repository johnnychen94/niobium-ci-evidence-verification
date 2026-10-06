//! RFC 3339 UTC timestamps as used in TUF `expires`: exactly `YYYY-MM-DDTHH:MM:SSZ`.

const std = @import("std");

pub const Error = error{InvalidTimestamp};

pub fn parseUtc(text: []const u8) Error!i64 {
    const layout_ok = text.len == 20 and text[4] == '-' and text[7] == '-' and text[10] == 'T' and
        text[13] == ':' and text[16] == ':' and text[19] == 'Z';
    if (!layout_ok) return error.InvalidTimestamp;
    const year = std.math.cast(u16, try digits(text[0..4])) orelse return error.InvalidTimestamp;
    const month = std.math.cast(u4, try digits(text[5..7])) orelse return error.InvalidTimestamp;
    const day = try digits(text[8..10]);
    const hour = try digits(text[11..13]);
    const minute = try digits(text[14..16]);
    const second = try digits(text[17..19]);
    if (year < 1970 or month < 1 or month > 12 or day < 1) return error.InvalidTimestamp;
    if (hour > 23 or minute > 59 or second > 59) return error.InvalidTimestamp;
    if (day > std.time.epoch.getDaysInMonth(year, monthOf(month))) return error.InvalidTimestamp;
    var days: i64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) days += std.time.epoch.getDaysInYear(y);
    var m: u4 = 1;
    while (m < month) : (m += 1) days += std.time.epoch.getDaysInMonth(year, monthOf(m));
    days += day - 1;
    return days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
}

fn monthOf(number: u4) std.time.epoch.Month {
    const months = std.enums.values(std.time.epoch.Month);
    return months[number - 1];
}

fn digits(text: []const u8) Error!u32 {
    var value: u32 = 0;
    for (text) |char| {
        if (!std.ascii.isDigit(char)) return error.InvalidTimestamp;
        value = value * 10 + (char - '0');
    }
    return value;
}

/// Writes `YYYY-MM-DDTHH:MM:SSZ`.
pub fn formatUtc(writer: *std.Io.Writer, unix_seconds: i64) std.Io.Writer.Error!void {
    const seconds = std.math.cast(u64, unix_seconds) orelse 0;
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const clock = epoch.getDaySeconds();
    try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        clock.getHoursIntoDay(),
        clock.getMinutesIntoHour(),
        clock.getSecondsIntoMinute(),
    });
}

test "timestamps round trip" {
    try std.testing.expectEqual(@as(i64, 0), try parseUtc("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(i64, 1_790_000_000), try parseUtc("2026-09-21T14:13:20Z"));
    try std.testing.expectError(error.InvalidTimestamp, parseUtc("2026-02-30T00:00:00Z"));
    try std.testing.expectError(error.InvalidTimestamp, parseUtc("2026-09-21 14:13:20Z"));
    var buffer: [32]u8 = undefined; // SAFETY: fixed writer scratch.
    var writer: std.Io.Writer = .fixed(&buffer);
    try formatUtc(&writer, 1_790_000_000);
    try std.testing.expectEqualStrings("2026-09-21T14:13:20Z", writer.buffered());
}
