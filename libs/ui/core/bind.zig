//! Template + ViewModel -> UiTree. Hidden subtrees (`visible_bind` false) are dropped, copy
//! placeholders are substituted, radio options become `radio_option` children, and nodes that
//! need a capability the backend lacks switch to their fallback with a diagnostic.

const std = @import("std");
const ir = @import("ir.zig");
const template = @import("template.zig");
const env_mod = @import("env.zig");

const TemplateNode = template.TemplateNode;
const Node = ir.Node;

pub const Error = error{ OutOfMemory, UiTemplateInvalid, UiTooManyNodes };

pub const CapabilityDiagnostic = struct {
    id: []const u8,
    capability: env_mod.Capability,
    resolution: ir.Fallback,
};

pub const Bound = struct {
    tree: ir.Tree,
    diagnostics: []const CapabilityDiagnostic,
};

pub fn bind(
    comptime VM: type,
    arena: std.mem.Allocator,
    root: *const TemplateNode,
    vm: *const VM,
    capabilities: env_mod.Capabilities,
) Error!Bound {
    if (template.check(VM, root) != null) return error.UiTemplateInvalid;
    var state: State = .{ .arena = arena, .capabilities = capabilities };
    try add(VM, &state, vm, root, ir.no_parent);
    return .{ .tree = .{ .nodes = state.nodes.items }, .diagnostics = state.diagnostics.items };
}

fn defaults(kind: ir.Kind) Node {
    var n: Node = .{ .kind = kind };
    switch (kind) {
        .window => {
            n.width = .fill;
            n.height = .fill;
        },
        .stack => {
            n.gap = .md;
            n.width = .fill;
        },
        .card => {
            n.gap = .md;
            n.padding = .lg;
            n.width = .fill;
        },
        .modal => {
            n.gap = .md;
            n.padding = .xl;
        },
        .radio_group => n.gap = .sm,
        .scroll, .progress_bar, .divider, .folder_picker => n.width = .fill,
        .button => n.variant = .secondary,
        else => {},
    }
    return n;
}

const State = struct {
    arena: std.mem.Allocator,
    capabilities: env_mod.Capabilities,
    nodes: std.ArrayList(Node) = .empty,
    diagnostics: std.ArrayList(CapabilityDiagnostic) = .empty,
};

/// The ViewModel field `name` when it has type `T`.
fn field(comptime VM: type, vm: *const VM, comptime T: type, name: []const u8) ?T {
    const info = @typeInfo(VM).@"struct";
    inline for (info.field_names, info.field_types) |field_name, F| {
        if (F == T and std.mem.eql(u8, field_name, name)) return @field(vm.*, field_name);
    }
    return null;
}

/// The tag name of the enum field `name`.
fn choice(comptime VM: type, vm: *const VM, name: []const u8) []const u8 {
    const info = @typeInfo(VM).@"struct";
    inline for (info.field_names, info.field_types) |field_name, F| {
        if (@typeInfo(F) == .@"enum" and std.mem.eql(u8, field_name, name)) {
            return @tagName(@field(vm.*, field_name));
        }
    }
    return "";
}

fn interpolate(comptime VM: type, s: *State, vm: *const VM, copy: []const u8) Error![]const u8 {
    if (std.mem.findScalar(u8, copy, '{') == null) return copy;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < copy.len) {
        if (copy[i] != '{') {
            try out.append(s.arena, copy[i]);
            i += 1;
            continue;
        }
        const close = std.mem.findScalarPos(u8, copy, i, '}') orelse
            return error.UiTemplateInvalid;
        try out.appendSlice(s.arena, field(VM, vm, []const u8, copy[i + 1 .. close]) orelse "");
        i = close + 1;
    }
    return out.items;
}

fn applyFields(n: *Node, t: *const TemplateNode) void {
    if (t.style) |v| n.style = v;
    if (t.tone) |v| n.tone = v;
    if (t.variant) |v| n.variant = v;
    if (t.action) |v| n.action = v;
    if (t.axis) |v| n.axis = v;
    if (t.gap) |v| n.gap = v;
    if (t.padding) |v| n.padding = v;
    if (t.alignment) |v| n.alignment = v;
    if (t.width) |v| n.width = v;
    if (t.height) |v| n.height = v;
    if (t.max_height) |v| n.max_height = v;
    if (t.source) |v| n.source = v;
}

fn resolve(comptime VM: type, s: *State, vm: *const VM, t: *const TemplateNode) Error!Node {
    var n = defaults(t.kind);
    n.id = t.id orelse "";
    n.text = try interpolate(VM, s, vm, t.text orelse t.label orelse t.title orelse "");
    applyFields(&n, t);
    if (t.enabled_bind) |name| n.enabled = field(VM, vm, bool, name) orelse true;
    switch (t.kind) {
        .checkbox => n.checked = field(VM, vm, bool, t.bind.?) orelse false,
        .progress_bar => n.value = std.math.clamp(field(VM, vm, f32, t.bind.?) orelse 0, 0, 1),
        .folder_picker => {
            n.detail = field(VM, vm, []const u8, t.bind.?) orelse "";
            if (!s.capabilities.native_folder_picker) {
                n.fallback_active = true;
                try s.diagnostics.append(s.arena, .{
                    .id = n.id,
                    .capability = .native_folder_picker,
                    .resolution = t.fallback.?,
                });
            }
        },
        else => {},
    }
    return n;
}

fn addOptions(
    comptime VM: type,
    s: *State,
    vm: *const VM,
    t: *const TemplateNode,
    group: u32,
) Error!void {
    const selected = choice(VM, vm, t.bind.?);
    const owner = s.nodes.items[group];
    for (t.options, 0..) |option, i| {
        const at: u32 = @intCast(s.nodes.items.len);
        try s.nodes.append(s.arena, .{
            .kind = .radio_option,
            .parent = group,
            .end = at + 1,
            .id = owner.id,
            .text = try interpolate(VM, s, vm, option.label),
            .selected = std.mem.eql(u8, selected, option.value),
            .index = @intCast(i),
            .enabled = owner.enabled,
        });
    }
}

fn emit(
    comptime VM: type,
    s: *State,
    vm: *const VM,
    t: *const TemplateNode,
    parent: u32,
) Error!?u32 {
    if (t.visible_bind) |name| if (!(field(VM, vm, bool, name) orelse true)) return null;
    if (s.nodes.items.len >= template.max_nodes) return error.UiTooManyNodes;
    const index: u32 = @intCast(s.nodes.items.len);
    var n = try resolve(VM, s, vm, t);
    n.parent = parent;
    try s.nodes.append(s.arena, n);
    if (t.kind == .radio_group) try addOptions(VM, s, vm, t, index);
    return index;
}

/// Preorder walk with an explicit stack; check() already bounded the depth.
fn add(
    comptime VM: type,
    s: *State,
    vm: *const VM,
    root: *const TemplateNode,
    parent: u32,
) Error!void {
    const Frame = struct { t: *const TemplateNode, index: u32, next: usize = 0 };
    var stack: [template.max_depth + 1]Frame = undefined; // SAFETY: only stack[0..len] is read.
    var len: usize = 0;
    const first = try emit(VM, s, vm, root, parent) orelse return;
    stack[0] = .{ .t = root, .index = first };
    len = 1;
    // loop-bound: each iteration emits a child or closes a node; both are finite.
    while (len > 0) {
        const top = &stack[len - 1];
        if (top.next == top.t.children.len) {
            s.nodes.items[top.index].end = @intCast(s.nodes.items.len);
            len -= 1;
            continue;
        }
        const child = &top.t.children[top.next];
        top.next += 1;
        const index = try emit(VM, s, vm, child, top.index) orelse continue;
        if (len == stack.len) return error.UiTemplateInvalid;
        stack[len] = .{ .t = child, .index = index };
        len += 1;
    }
}
