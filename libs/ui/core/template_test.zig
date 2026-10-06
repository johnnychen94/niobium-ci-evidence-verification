const std = @import("std");
const template = @import("template.zig");
const fixture = @import("fixture.zig");

const Problem = template.Problem;

fn parse(arena: std.mem.Allocator, source: [:0]const u8) !template.TemplateNode {
    var diagnostics: std.zon.parse.Diagnostics = undefined; // SAFETY: initialized by fromSlice.
    return std.zon.parse.fromSlice(template.TemplateNode, .{
        .gpa = arena,
        .arena = arena,
        .source = source,
        .diagnostics = &diagnostics,
    });
}

/// Wraps `children` in a window and returns the first problem `check` reports.
fn problemOf(comptime children: []const u8) !?Problem {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const source = ".{ .kind = .window, .title = \"T\", .children = .{" ++ children ++ "} }";
    const root = try parse(arena_state.allocator(), source);
    const d = template.check(fixture.ViewModel, &root) orelse return null;
    return d.problem;
}

fn expectProblem(expected: Problem, comptime children: []const u8) !void {
    try std.testing.expectEqual(@as(?Problem, expected), try problemOf(children));
}

test "templates parse with the TemplateNode schema; unknown fields and kinds are rejected" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ok = try parse(
        a,
        ".{ .kind = .window, .title = \"T\", .children = .{ .{ .kind = .divider } } }",
    );
    try std.testing.expectEqual(
        @as(?template.Diagnostic, null),
        template.check(fixture.ViewModel, &ok),
    );
    try std.testing.expectError(
        error.ParseZon,
        parse(a, ".{ .kind = .window, .colour = \"red\" }"),
    );
    try std.testing.expectError(error.ParseZon, parse(a, ".{ .kind = .textbox }"));
    try std.testing.expectError(error.ParseZon, parse(a, ".{ .kind = .text, .width = 120 }"));
    try std.testing.expectError(
        error.ParseZon,
        parse(a, ".{ .kind = .text, .width = .{ .fixed = .huge } }"),
    );
}

test "template structure rules" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const not_window = try parse(a, ".{ .kind = .stack }");
    try std.testing.expectEqual(
        Problem.root_not_window,
        template.check(fixture.ViewModel, &not_window).?.problem,
    );

    try expectProblem(
        .nested_window,
        ".{ .kind = .window, .title = \"x\", .children = .{ .{ .kind = .divider } } }",
    );
    try expectProblem(.radio_option_in_template, ".{ .kind = .radio_option }");
    try expectProblem(
        .scroll_child_count,
        ".{ .kind = .scroll, .id = \"s\", .children = .{ .{ .kind = .divider }, " ++
            ".{ .kind = .divider } } }",
    );
    try expectProblem(
        .modal_placement,
        ".{ .kind = .modal, .title = \"m\", " ++
            ".children = .{ .{ .kind = .divider } } }, .{ .kind = .divider }",
    );
    try expectProblem(
        .modal_placement,
        ".{ .kind = .stack, .children = .{ .{ .kind = .modal, .title = \"m\", " ++
            ".children = .{ .{ .kind = .divider } } } } }",
    );
    try expectProblem(
        .missing_fallback,
        ".{ .kind = .folder_picker, .id = \"f\", .label = \"L\", .bind = \"location\" }",
    );
    try expectProblem(
        .too_few_options,
        ".{ .kind = .radio_group, .id = \"r\", .label = \"L\", .bind = \"scope\", " ++
            ".options = .{ .{ .value = \"user\", .label = \"U\" } } }",
    );
}

test "template field and id rules" {
    try expectProblem(.missing_id, ".{ .kind = .button, .label = \"Go\", .action = .next }");
    try expectProblem(
        .bad_id,
        ".{ .kind = .button, .id = \"Go-Now\", .label = \"Go\", .action = .next }",
    );
    try expectProblem(
        .duplicate_id,
        ".{ .kind = .button, .id = \"go\", .label = \"A\", .action = .next }, " ++
            ".{ .kind = .link, .id = \"go\", .label = \"B\", .action = .back }",
    );
    try expectProblem(.missing_field, ".{ .kind = .button, .id = \"go\", .label = \"Go\" }");
    try expectProblem(.missing_field, ".{ .kind = .text }");
    try expectProblem(.field_not_allowed, ".{ .kind = .text, .text = \"t\", .action = .next }");
    try expectProblem(.field_not_allowed, ".{ .kind = .divider, .id = \"d\" }");
    try expectProblem(.field_not_allowed, ".{ .kind = .text, .text = \"t\", .padding = .lg }");
}

test "template bindings are checked against the ViewModel" {
    try expectProblem(
        .unknown_binding,
        ".{ .kind = .checkbox, .id = \"c\", .label = \"L\", .bind = \"nope\" }",
    );
    try expectProblem(
        .binding_type,
        ".{ .kind = .checkbox, .id = \"c\", .label = \"L\", .bind = \"product_name\" }",
    );
    try expectProblem(
        .binding_type,
        ".{ .kind = .progress_bar, .label = \"L\", .bind = \"busy\" }",
    );
    try expectProblem(.binding_type, ".{ .kind = .divider, .visible_bind = \"progress\" }");
    try expectProblem(.unknown_binding, ".{ .kind = .text, .text = \"Hi {nobody}\" }");
    try expectProblem(.binding_type, ".{ .kind = .text, .text = \"{busy}\" }");
    try expectProblem(.bad_placeholder, ".{ .kind = .text, .text = \"open { brace\" }");
    try expectProblem(.bad_placeholder, ".{ .kind = .text, .text = \"stray } brace\" }");
    try expectProblem(.bad_placeholder, ".{ .kind = .text, .text = \"{}\" }");
    try expectProblem(
        .unknown_option,
        ".{ .kind = .radio_group, .id = \"r\", .label = \"L\", .bind = \"scope\", " ++
            ".options = .{ .{ .value = \"user\", .label = \"U\" }, " ++
            ".{ .value = \"global\", .label = \"G\" } } }",
    );
    try std.testing.expectEqual(
        @as(?Problem, null),
        try problemOf(".{ .kind = .text, .text = \"{product_name} {summary}\" }"),
    );
}

test "bind refuses a template that fails check" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bad = try parse(
        a,
        ".{ .kind = .window, .title = \"{nobody}\", .children = .{ .{ .kind = .divider } } }",
    );
    const vm: fixture.ViewModel = .{};
    try std.testing.expectError(
        error.UiTemplateInvalid,
        @import("bind.zig").bind(fixture.ViewModel, a, &bad, &vm, .{}),
    );
}
