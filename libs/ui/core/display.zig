//! DisplayList: the only thing a rasterizer sees. Device-pixel integers, token colors, and
//! text runs that the renderer shapes with the embedded font.

const std = @import("std");
const tokens = @import("ui_tokens");
const geometry = @import("geometry.zig");
const ir = @import("ir.zig");
const env_mod = @import("env.zig");

const Rect = geometry.Rect;
pub const Color = tokens.Color;

pub const Icon = enum { check, chevron, folder, warning, failure, success };

pub const Command = union(enum) {
    fill: struct { rect: Rect, radius: i32 = 0, color: Color },
    stroke: struct { rect: Rect, radius: i32 = 0, width: i32, color: Color },
    /// One line of text; `y` is the top of a line box `line_height` tall.
    text: struct {
        x: i32,
        y: i32,
        line_height: i32,
        font: env_mod.Font,
        color: Color,
        text: []const u8,
        underline: bool = false,
    },
    image: struct { rect: Rect, source: ir.ImageSource },
    icon: struct { rect: Rect, icon: Icon, color: Color },
    /// Indeterminate spinner; `phase` is the rotation in thousandths of a turn.
    ring: struct { rect: Rect, width: i32, phase: u16, color: Color },
    clip: Rect,
    unclip,
};

pub const DisplayList = struct {
    arena: std.mem.Allocator,
    commands: std.ArrayList(Command) = .empty,

    pub fn init(arena: std.mem.Allocator) DisplayList {
        return .{ .arena = arena };
    }

    pub fn add(l: *DisplayList, command: Command) error{OutOfMemory}!void {
        try l.commands.append(l.arena, command);
    }

    pub fn items(l: *const DisplayList) []const Command {
        return l.commands.items;
    }

    /// Textual snapshot, one command per line.
    pub fn write(l: *const DisplayList, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var depth: usize = 0;
        for (l.commands.items) |c| {
            if (c == .unclip) depth -|= 1;
            try w.splatByteAll(' ', 2 * depth);
            try writeCommand(w, c);
            try w.writeByte('\n');
            if (c == .clip) depth += 1;
        }
    }
};

fn writeColor(w: *std.Io.Writer, c: Color) std.Io.Writer.Error!void {
    try w.print("#{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{ c.r, c.g, c.b, c.a });
}

fn writeCommand(w: *std.Io.Writer, command: Command) std.Io.Writer.Error!void {
    switch (command) {
        .fill => |f| {
            try w.print("fill {f} r{d} ", .{ f.rect, f.radius });
            try writeColor(w, f.color);
        },
        .stroke => |s| {
            try w.print("stroke {f} r{d} w{d} ", .{ s.rect, s.radius, s.width });
            try writeColor(w, s.color);
        },
        .text => |t| {
            try w.print(
                "text {d},{d} lh{d} {t}/{d} ",
                .{ t.x, t.y, t.line_height, t.font.style, t.font.size },
            );
            try writeColor(w, t.color);
            if (t.underline) try w.writeAll(" underline");
            try w.print(" \"{f}\"", .{std.zig.fmtString(t.text)});
        },
        .image => |i| try w.print("image {f} {t}", .{ i.rect, i.source }),
        .icon => |i| {
            try w.print("icon {f} {t} ", .{ i.rect, i.icon });
            try writeColor(w, i.color);
        },
        .ring => |r| {
            try w.print("ring {f} w{d} p{d} ", .{ r.rect, r.width, r.phase });
            try writeColor(w, r.color);
        },
        .clip => |r| try w.print("clip {f}", .{r}),
        .unclip => try w.writeAll("unclip"),
    }
}

test "display list snapshot" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var list: DisplayList = .init(arena_state.allocator());
    const red: Color = .{ .r = 255, .g = 0, .b = 0 };
    try list.add(.{ .clip = .{ .x = 0, .y = 0, .w = 10, .h = 10 } });
    try list.add(
        .{ .fill = .{ .rect = .{ .x = 1, .y = 2, .w = 3, .h = 4 }, .radius = 2, .color = red } },
    );
    try list.add(.unclip);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try list.write(&out.writer);
    try std.testing.expectEqualStrings(
        "clip 0,0 10x10\n  fill 1,2 3x4 r2 #FF0000FF\nunclip\n",
        out.written(),
    );
}
