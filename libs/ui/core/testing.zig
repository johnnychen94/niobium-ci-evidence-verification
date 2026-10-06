//! Deterministic stand-ins for tests in ui_core and its dependents: a monospace measurer
//! (Latin 0.6 em, CJK 1 em) and a minimal kit that draws boxes and text runs.

const std = @import("std");
const tokens = @import("ui_tokens");
const ir = @import("ir.zig");
const geometry = @import("geometry.zig");
const env_mod = @import("env.zig");
const text = @import("text.zig");
const display = @import("display.zig");
const frame = @import("frame.zig");

const Env = env_mod.Env;
const Size = geometry.Size;
const Rect = geometry.Rect;

/// Never written; the measurer only needs a non-null context.
const measurer_context: u8 = 0;

fn monospaceWidth(context: *anyopaque, font: env_mod.Font, run: []const u8) i32 {
    std.debug.assert(context == @as(*const anyopaque, &measurer_context));
    var width: i32 = 0;
    var i: usize = 0;
    while (i < run.len) {
        const len = std.unicode.utf8ByteSequenceLength(run[i]) catch 1;
        const cp = if (i + len <= run.len)
            std.unicode.utf8Decode(run[i..][0..len]) catch 0xFFFD
        else
            0xFFFD;
        width += if (cp >= 0x2E80) font.size else @divFloor(font.size * 3, 5);
        i += @min(len, run.len - i);
    }
    return width;
}

pub fn measurer() env_mod.TextMeasurer {
    return .{ .context = @constCast(&measurer_context), .width_fn = monospaceWidth };
}

pub const EnvOptions = struct {
    theme: tokens.ThemeName = .light,
    platform: tokens.Platform = .macos,
    scale: u16 = 100,
    direction: env_mod.Direction = .ltr,
    capabilities: env_mod.Capabilities = .{},
};

pub fn env(o: EnvOptions) Env {
    return .{
        .theme = tokens.theme(o.theme),
        .metrics = tokens.metrics(o.platform),
        .scale = o.scale,
        .direction = o.direction,
        .capabilities = o.capabilities,
        .text = measurer(),
    };
}

fn textSize(e: *const Env, style: ir.TextStyle, copy: []const u8, max_w: i32) Size {
    const extent = text.measure(e.text, e.font(style), copy, max_w);
    return .{ .w = extent.width, .h = e.lineHeight(style) * @as(i32, @intCast(extent.lines)) };
}

/// Minimal kit: sizes follow the tokens the real kit uses, drawing is boxes plus text.
pub const Kit = struct {
    pub fn measure(e: *const Env, n: *const ir.Node, max_w: i32) Size {
        const m = e.metrics;
        const control = e.px(m.control_height);
        return switch (n.kind) {
            .text => textSize(e, n.style, n.text, max_w),
            .link => textSize(e, .body, n.text, max_w),
            .button => .{
                .w = @max(
                    e.px(m.control_min_width),
                    textSize(e, .body, n.text, max_w).w + 2 * e.token(.lg),
                ),
                .h = control,
            },
            .checkbox, .radio_option => box: {
                const mark = e.px(tokens.checkbox_size) + e.token(.sm);
                const label = textSize(e, .body, n.text, max_w - mark);
                break :box .{ .w = mark + label.w, .h = @max(label.h, e.px(tokens.checkbox_size)) };
            },
            .progress_bar => .{ .w = max_w, .h = e.px(tokens.progress_height) },
            .progress_ring => .{ .w = e.px(24), .h = e.px(24) },
            .image => .{ .w = e.token(.logo), .h = e.token(.logo) },
            .divider => .{ .w = max_w, .h = e.px(1) },
            .folder_picker => .{ .w = max_w, .h = control },
            else => .zero,
        };
    }

    pub fn emit(
        e: *const Env,
        n: *const ir.Node,
        at: frame.Placement,
        state: frame.NodeState,
        list: *display.DisplayList,
    ) error{OutOfMemory}!void {
        const t = e.theme;
        const rect = at.rect;
        switch (n.kind) {
            .window => try list.add(.{ .fill = .{ .rect = rect, .color = t.bg } }),
            .card, .modal => try list.add(.{ .fill = .{ .rect = rect, .color = t.surface } }),
            .button => {
                const color = if (n.variant == .primary) t.accent else t.control;
                try list.add(
                    .{
                        .fill = .{
                            .rect = rect,
                            .radius = e.px(e.metrics.radius_control),
                            .color = color,
                        },
                    },
                );
                try line(e, list, rect.x + e.token(.lg), rect.y, .body, n.text);
            },
            .text => {
                const lines = try text.wrap(list.arena, e.text, e.font(n.style), n.text, rect.w);
                for (lines, 0..) |l, k| {
                    const y = rect.y + e.lineHeight(n.style) * @as(i32, @intCast(k));
                    try line(e, list, rect.x, y, n.style, n.text[l.start..l.end]);
                }
            },
            .checkbox, .radio_option, .link, .folder_picker => try line(
                e,
                list,
                rect.x,
                rect.y,
                .body,
                n.text,
            ),
            else => {},
        }
        if (state.focused) {
            try list.add(
                .{
                    .stroke = .{ .rect = rect.inset(-e.px(2)), .width = e.px(2), .color = t.focus },
                },
            );
        }
    }

    fn line(
        e: *const Env,
        list: *display.DisplayList,
        x: i32,
        y: i32,
        style: ir.TextStyle,
        run: []const u8,
    ) error{OutOfMemory}!void {
        try list.add(.{ .text = .{
            .x = x,
            .y = y,
            .line_height = e.lineHeight(style),
            .font = e.font(style),
            .color = e.theme.text,
            .text = run,
        } });
    }
};
