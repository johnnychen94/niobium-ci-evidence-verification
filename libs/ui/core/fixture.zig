//! Shared by ui_core tests: a ViewModel, the compiled sample template and a frame builder.

const std = @import("std");
const template = @import("template.zig");
const bind_mod = @import("bind.zig");
const env_mod = @import("env.zig");
const frame = @import("frame.zig");
const input = @import("input.zig");
const testing = @import("testing.zig");

pub const Scope = enum { user, machine };

pub const ViewModel = struct {
    product_name: []const u8 = "Hello",
    summary: []const u8 = "Installs into your user folder.",
    shortcut: bool = true,
    scope: Scope = .user,
    location: []const u8 = "/Apps/Hello",
    progress: f32 = 0.37,
    busy: bool = false,
    can_install: bool = true,
    confirm_cancel: bool = false,
    details: []const u8 = "Files copied so far are removed. Nothing outside the install " ++
        "folder changes. Downloaded packages stay in the cache, so the next attempt " ++
        "reuses them instead of downloading again.",
};

pub const options = template.compile(ViewModel, @import("testdata/options.zon"));

pub const viewport: @import("geometry.zig").Size = .{ .w = 640, .h = 460 };

pub const World = struct {
    arena_state: std.heap.ArenaAllocator,

    pub fn init() World {
        return .{ .arena_state = .init(std.testing.allocator) };
    }

    pub fn deinit(w: *World) void {
        w.arena_state.deinit();
    }

    pub fn arena(w: *World) std.mem.Allocator {
        return w.arena_state.allocator();
    }

    pub fn frameOf(
        w: *World,
        vm: ViewModel,
        o: testing.EnvOptions,
        s: *const input.Interaction,
    ) !frame.Frame {
        const env = testing.env(o);
        const bound = try bind_mod.bind(ViewModel, w.arena(), &options, &vm, o.capabilities);
        const size: @import("geometry.zig").Size = .{
            .w = env.px(viewport.w),
            .h = env.px(viewport.h),
        };
        return frame.build(testing.Kit, w.arena(), &env, bound.tree, size, s);
    }

    pub fn snapshot(
        w: *World,
        comptime what: enum { tree, display, semantics },
        f: frame.Frame,
    ) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(w.arena());
        switch (what) {
            .tree => try f.tree.write(&out.writer),
            .display => try f.display.write(&out.writer),
            .semantics => try f.semantics.write(&out.writer),
        }
        return out.written();
    }
};

pub fn rectOf(f: frame.Frame, id: []const u8) @import("geometry.zig").Rect {
    return f.layout.rects[f.tree.find(id).?];
}

pub const native: env_mod.Capabilities = .{ .native_folder_picker = true };
