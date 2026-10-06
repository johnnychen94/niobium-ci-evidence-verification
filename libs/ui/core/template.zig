//! Screen templates (docs/spec/ui-ir-v1.md). A `.zon` screen is `@import`ed with
//! `TemplateNode` as its result type, so unknown fields and nodes already fail to compile;
//! `compile` adds the per-kind rules and the ViewModel binding checks at comptime. `check` is
//! the same validation callable at runtime, which is how the rules are tested.

const std = @import("std");
const ir = @import("ir.zig");

pub const Option = struct {
    value: []const u8,
    label: []const u8,
};

/// Every field except `kind` is optional so that "present" is observable per kind.
pub const TemplateNode = struct {
    kind: ir.Kind,
    id: ?[]const u8 = null,
    /// Literal copy; `{field}` substitutes a ViewModel string.
    text: ?[]const u8 = null,
    label: ?[]const u8 = null,
    title: ?[]const u8 = null,
    bind: ?[]const u8 = null,
    enabled_bind: ?[]const u8 = null,
    visible_bind: ?[]const u8 = null,
    style: ?ir.TextStyle = null,
    tone: ?ir.Tone = null,
    variant: ?ir.Variant = null,
    action: ?ir.Action = null,
    axis: ?ir.Axis = null,
    gap: ?ir.Token = null,
    padding: ?ir.Token = null,
    alignment: ?ir.Align = null,
    width: ?ir.Extent = null,
    height: ?ir.Extent = null,
    max_height: ?ir.Token = null,
    source: ?ir.ImageSource = null,
    fallback: ?ir.Fallback = null,
    options: []const Option = &.{},
    children: []const TemplateNode = &.{},
};

pub const Field = std.meta.FieldEnum(TemplateNode);

pub const Problem = enum {
    root_not_window,
    nested_window,
    radio_option_in_template,
    missing_id,
    bad_id,
    duplicate_id,
    missing_field,
    field_not_allowed,
    unknown_binding,
    binding_type,
    bad_placeholder,
    unknown_option,
    too_few_options,
    scroll_child_count,
    modal_placement,
    missing_fallback,
    too_many_nodes,
    too_deep,
};

pub const Diagnostic = struct {
    problem: Problem,
    kind: ir.Kind,
    /// The node id when it has one.
    id: []const u8 = "",
    /// Field, binding, placeholder or option involved.
    name: []const u8 = "",
};

pub const max_nodes = 512;
pub const max_depth = 24;
const max_ids = 128;

/// What a ViewModel field can feed.
pub const Binding = enum { text, flag, number, choice };

pub fn bindingOf(comptime VM: type, name: []const u8) ?Binding {
    const info = @typeInfo(VM).@"struct";
    inline for (info.field_names, info.field_types) |field_name, T| {
        if (std.mem.eql(u8, field_name, name)) return classify(T);
    }
    return null;
}

fn classify(comptime T: type) ?Binding {
    if (T == []const u8) return .text;
    if (T == bool) return .flag;
    if (T == f32) return .number;
    if (@typeInfo(T) == .@"enum") return .choice;
    return null;
}

fn hasChoice(comptime VM: type, name: []const u8, value: []const u8) bool {
    const info = @typeInfo(VM).@"struct";
    inline for (info.field_names, info.field_types) |field_name, T| {
        if (@typeInfo(T) == .@"enum" and std.mem.eql(u8, field_name, name)) {
            inline for (@typeInfo(T).@"enum".field_names) |tag| {
                if (std.mem.eql(u8, tag, value)) return true;
            }
        }
    }
    return false;
}

const Rule = struct {
    allowed: []const Field,
    required: []const Field = &.{},
    needs_id: bool = false,
};

fn rule(kind: ir.Kind) Rule {
    return switch (kind) {
        .window => .{ .allowed = &.{ .title, .children }, .required = &.{ .title, .children } },
        .stack => .{
            .allowed = &.{ .axis, .gap, .padding, .alignment, .width, .height, .children },
        },
        .card => .{ .allowed = &.{ .gap, .padding, .alignment, .width, .height, .children } },
        .text => .{ .allowed = &.{ .text, .style, .tone, .width }, .required = &.{.text} },
        .image => .{ .allowed = &.{ .source, .label, .width, .height }, .required = &.{.source} },
        .button => .{
            .allowed = &.{ .id, .label, .variant, .action, .enabled_bind, .width },
            .required = &.{ .label, .action },
            .needs_id = true,
        },
        .checkbox => .{
            .allowed = &.{ .id, .label, .bind, .enabled_bind },
            .required = &.{ .label, .bind },
            .needs_id = true,
        },
        .radio_group => .{
            .allowed = &.{ .id, .label, .bind, .options, .enabled_bind, .gap },
            .required = &.{ .label, .bind, .options },
            .needs_id = true,
        },
        .link => .{
            .allowed = &.{ .id, .label, .action },
            .required = &.{ .label, .action },
            .needs_id = true,
        },
        .progress_bar => .{
            .allowed = &.{ .bind, .label, .width },
            .required = &.{ .bind, .label },
        },
        .progress_ring => .{ .allowed = &.{.label}, .required = &.{.label} },
        .scroll => .{
            .allowed = &.{ .id, .max_height, .width, .height, .children },
            .required = &.{.children},
            .needs_id = true,
        },
        .modal => .{ .allowed = &.{ .title, .children }, .required = &.{ .title, .children } },
        .divider => .{ .allowed = &.{} },
        .spacer => .{ .allowed = &.{ .width, .height } },
        .folder_picker => .{
            .allowed = &.{ .id, .label, .bind, .fallback, .enabled_bind, .width },
            .required = &.{ .label, .bind },
            .needs_id = true,
        },
        .radio_option => .{ .allowed = &.{} },
    };
}

fn present(node: *const TemplateNode, comptime field: Field) bool {
    const value = @field(node, @tagName(field));
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => value != null,
        .pointer => value.len > 0,
        else => true,
    };
}

fn contains(fields: []const Field, field: Field) bool {
    for (fields) |f| if (f == field) return true;
    return false;
}

const Checker = struct {
    ids: [max_ids][]const u8 = @splat(""),
    id_count: usize = 0,
    nodes: usize = 0,

    fn fail(problem: Problem, node: *const TemplateNode, name: []const u8) Diagnostic {
        return .{ .problem = problem, .kind = node.kind, .id = node.id orelse "", .name = name };
    }

    fn fields(node: *const TemplateNode) ?Diagnostic {
        const r = rule(node.kind);
        inline for (comptime std.enums.values(Field)) |field| {
            if (field == .kind) continue;
            const allowed = contains(
                r.allowed,
                field,
            ) or (field == .visible_bind and node.kind != .window);
            const is_present = present(node, field);
            if (is_present and !allowed) return fail(.field_not_allowed, node, @tagName(field));
            if (!is_present and contains(r.required, field)) {
                return fail(.missing_field, node, @tagName(field));
            }
        }
        return null;
    }

    fn identity(c: *Checker, node: *const TemplateNode) ?Diagnostic {
        const id = node.id orelse {
            return if (rule(node.kind).needs_id) fail(.missing_id, node, "id") else null;
        };
        if (id.len == 0 or id.len > 64) return fail(.bad_id, node, id);
        for (id) |ch| {
            if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_')) {
                return fail(.bad_id, node, id);
            }
        }
        for (c.ids[0..c.id_count]) |seen| {
            if (std.mem.eql(u8, seen, id)) return fail(.duplicate_id, node, id);
        }
        if (c.id_count == max_ids) return fail(.too_many_nodes, node, id);
        c.ids[c.id_count] = id;
        c.id_count += 1;
        return null;
    }

    fn visit(
        c: *Checker,
        comptime VM: type,
        node: *const TemplateNode,
        parent: ?ir.Kind,
        depth: usize,
    ) ?Diagnostic {
        c.nodes += 1;
        if (c.nodes > max_nodes) return fail(.too_many_nodes, node, "");
        if (depth > max_depth) return fail(.too_deep, node, "");
        if (node.kind == .radio_option) return fail(.radio_option_in_template, node, "");
        if (node.kind == .window and parent != null) return fail(.nested_window, node, "");
        if (node.kind == .modal and parent != .window) return fail(.modal_placement, node, "");
        if (fields(node)) |d| return d;
        if (c.identity(node)) |d| return d;
        if (bindings(VM, node)) |d| return d;
        return structure(node);
    }
};

fn structure(node: *const TemplateNode) ?Diagnostic {
    switch (node.kind) {
        .scroll => if (node.children.len != 1) {
            return Checker.fail(.scroll_child_count, node, "children");
        },
        .radio_group => if (node.options.len < 2) {
            return Checker.fail(.too_few_options, node, "options");
        },
        .folder_picker => if (node.fallback == null) {
            return Checker.fail(.missing_fallback, node, "fallback");
        },
        .window => for (node.children, 0..) |child, i| {
            if (child.kind == .modal and i + 1 != node.children.len) {
                return Checker.fail(.modal_placement, &child, "");
            }
        },
        else => {},
    }
    return null;
}

fn expect(
    comptime VM: type,
    node: *const TemplateNode,
    name: ?[]const u8,
    wanted: Binding,
) ?Diagnostic {
    const field = name orelse return null;
    const got = bindingOf(VM, field) orelse return Checker.fail(.unknown_binding, node, field);
    return if (got == wanted) null else Checker.fail(.binding_type, node, field);
}

fn bindings(comptime VM: type, node: *const TemplateNode) ?Diagnostic {
    if (expect(VM, node, node.enabled_bind, .flag)) |d| return d;
    if (expect(VM, node, node.visible_bind, .flag)) |d| return d;
    const value: ?Binding = switch (node.kind) {
        .checkbox => .flag,
        .radio_group => .choice,
        .progress_bar => .number,
        .folder_picker => .text,
        else => null,
    };
    if (value) |wanted| if (expect(VM, node, node.bind, wanted)) |d| return d;
    for ([_]?[]const u8{ node.text, node.label, node.title }) |copy| {
        if (placeholders(VM, node, copy orelse continue)) |d| return d;
    }
    for (node.options) |option| {
        if (placeholders(VM, node, option.label)) |d| return d;
        if (!hasChoice(VM, node.bind.?, option.value)) {
            return Checker.fail(.unknown_option, node, option.value);
        }
    }
    return null;
}

/// `{name}` must name a string field; any other brace is an error.
fn placeholders(comptime VM: type, node: *const TemplateNode, copy: []const u8) ?Diagnostic {
    var i: usize = 0;
    while (i < copy.len) : (i += 1) {
        if (copy[i] == '}') return Checker.fail(.bad_placeholder, node, copy);
        if (copy[i] != '{') continue;
        const close = std.mem.findScalarPos(u8, copy, i, '}') orelse {
            return Checker.fail(.bad_placeholder, node, copy);
        };
        const name = copy[i + 1 .. close];
        if (name.len == 0 or std.mem.findScalar(u8, name, '{') != null) {
            return Checker.fail(.bad_placeholder, node, copy);
        }
        if (expect(VM, node, name, .text)) |d| return d;
        i = close;
    }
    return null;
}

/// Validates a template against the per-kind rules and the ViewModel. Usable at comptime.
pub fn check(comptime VM: type, root: *const TemplateNode) ?Diagnostic {
    if (root.kind != .window) return Checker.fail(.root_not_window, root, "");
    var c: Checker = .{};
    if (c.visit(VM, root, null, 0)) |d| return d;
    const Frame = struct { t: *const TemplateNode, next: usize = 0 };
    var stack: [max_depth + 1]Frame = undefined; // SAFETY: only stack[0..len] is read.
    stack[0] = .{ .t = root };
    var len: usize = 1;
    // loop-bound: each iteration visits a child or pops a frame; nodes are capped by max_nodes.
    while (len > 0) {
        const top = &stack[len - 1];
        if (top.next == top.t.children.len) {
            len -= 1;
            continue;
        }
        const child = &top.t.children[top.next];
        top.next += 1;
        if (c.visit(VM, child, top.t.kind, len)) |d| return d;
        if (len == stack.len) return Checker.fail(.too_deep, child, "");
        stack[len] = .{ .t = child };
        len += 1;
    }
    return null;
}

/// A validated template. Any rule violation is a compile error naming the node and field.
pub fn compile(comptime VM: type, comptime root: TemplateNode) TemplateNode {
    comptime {
        @setEvalBranchQuota(2_000_000);
        if (check(VM, &root)) |d| @compileError(std.fmt.comptimePrint(
            "ui template: {s} on {s} '{s}' ({s})",
            .{ @tagName(d.problem), @tagName(d.kind), d.id, d.name },
        ));
    }
    return root;
}
