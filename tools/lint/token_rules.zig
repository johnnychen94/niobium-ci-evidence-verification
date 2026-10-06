//! Token-sequence rules (crash safety, allowlists, boundaries).

const std = @import("std");
const specs = @import("module_specs");
const context = @import("context.zig");

const Ctx = context.Ctx;
const Tag = std.zig.Token.Tag;

/// Files whose job is panicking/asserting, plus build-time code.
const panic_owners = [_][]const u8{
    "libs/core/assert.zig", "libs/core/crash.zig", "third_party/", "tools/", "build/", "build.zig",
};

/// Modules that parse untrusted bytes: no @intCast/@truncate (use std.math.cast).
const parser_paths = [_][]const u8{
    "libs/contracts/",
    "libs/manifest/",
    "libs/trust/",
    "libs/package/",
    "libs/repository/",
    "libs/privilege/ipc",
    "libs/ui/render/png",
    "libs/ui/backend/x11",
};

/// Hot loops allowed to disable runtime safety (each must also be fuzzed).
const runtime_safety_allowlist = [_][]const u8{"libs/ui/render/raster.zig"};

const print_allowed = [_][]const u8{ "tools/", "tests/", "build/", "build.zig" };

pub fn run(ctx: *Ctx) !void {
    const tags = ctx.tree.tokens.items(.tag);
    const starts = ctx.tree.tokens.items(.start);
    for (tags, starts, 0..) |tag, start, index| {
        switch (tag) {
            .keyword_catch => try checkCatch(ctx, index),
            .keyword_orelse => if (tagAt(ctx, index + 1) == .keyword_unreachable) {
                try reportUnlessTest(
                    ctx,
                    start,
                    "no-orelse-unreachable",
                    "orelse unreachable",
                    .{},
                );
            },
            .keyword_while => try checkWhileTrue(ctx, index),
            .keyword_var => try checkGlobalVar(ctx, start),
            .builtin => try checkBuiltin(ctx, index),
            .identifier => try checkIdentifier(ctx, index),
            else => {},
        }
    }
}

fn tagAt(ctx: *const Ctx, index: usize) ?Tag {
    const tags = ctx.tree.tokens.items(.tag);
    return if (index < tags.len) tags[index] else null;
}

fn sliceAt(ctx: *const Ctx, index: usize) []const u8 {
    if (index >= ctx.tree.tokens.len) return "";
    return ctx.tree.tokenSlice(@intCast(index));
}

fn reportUnlessTest(
    ctx: *Ctx,
    offset: u32,
    rule: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    if (ctx.inTest(offset)) return;
    try ctx.report(offset, rule, fmt, args);
}

/// Index of the token after an optional `|payload|`.
fn skipPayload(ctx: *const Ctx, index: usize) usize {
    if (tagAt(ctx, index) != .pipe) return index;
    var cursor = index + 1;
    while (cursor < index + 4) : (cursor += 1) {
        if (tagAt(ctx, cursor) == .pipe) return cursor + 1;
    }
    return index;
}

fn checkCatch(ctx: *Ctx, index: usize) !void {
    const start = ctx.tree.tokens.items(.start)[index];
    const next = skipPayload(ctx, index + 1);
    if (tagAt(ctx, next) == .keyword_unreachable) {
        try reportUnlessTest(ctx, start, "no-catch-unreachable", "catch unreachable", .{});
    }
    if (tagAt(ctx, next) == .l_brace and tagAt(ctx, next + 1) == .r_brace) {
        try reportUnlessTest(
            ctx,
            start,
            "no-empty-catch",
            "empty catch block swallows errors",
            .{},
        );
    }
}

fn checkWhileTrue(ctx: *Ctx, index: usize) !void {
    if (tagAt(ctx, index + 1) != .l_paren) return;
    if (!std.mem.eql(u8, sliceAt(ctx, index + 2), "true")) return;
    if (tagAt(ctx, index + 3) != .r_paren) return;
    const start = ctx.tree.tokens.items(.start)[index];
    if (ctx.hasMarker(ctx.lineOf(start), "// loop-bound:")) return;
    try ctx.report(
        start,
        "bounded-loop",
        "while (true) needs a '// loop-bound:' justification",
        .{},
    );
}

/// `extern var` names a symbol another image owns (a framework constant), not our state.
fn isExtern(ctx: *Ctx, start: u32) bool {
    const before = std.mem.trimEnd(u8, ctx.source[0..start], " \t");
    return std.mem.endsWith(u8, before, "extern");
}

fn checkGlobalVar(ctx: *Ctx, start: u32) !void {
    if (!std.mem.startsWith(u8, ctx.path, "libs/")) return;
    if (ctx.inFn(start) or ctx.inTest(start)) return;
    if (isExtern(ctx, start)) return;
    try ctx.report(start, "no-global-var", "container-level mutable var in libs/", .{});
}

fn checkBuiltin(ctx: *Ctx, index: usize) !void {
    const name = sliceAt(ctx, index);
    const start = ctx.tree.tokens.items(.start)[index];
    if (std.mem.eql(u8, name, "@panic") and !ctx.pathIn(&panic_owners)) {
        try reportUnlessTest(ctx, start, "panic-owner", "@panic outside core/assert.zig", .{});
    }
    const narrowing = std.mem.eql(u8, name, "@intCast") or std.mem.eql(u8, name, "@truncate");
    if (narrowing and ctx.pathIn(&parser_paths)) {
        try reportUnlessTest(
            ctx,
            start,
            "parser-int-cast",
            "{s} in a parser module; use std.math.cast",
            .{name},
        );
    }
    if (std.mem.eql(u8, name, "@setRuntimeSafety") and std.mem.eql(
        u8,
        sliceAt(ctx, index + 2),
        "false",
    )) {
        if (!ctx.pathIn(&runtime_safety_allowlist)) {
            try ctx.report(
                start,
                "runtime-safety-allowlist",
                "@setRuntimeSafety(false) not allowlisted",
                .{},
            );
        }
    }
    const pointer_casts = [_][]const u8{ "@ptrCast", "@alignCast", "@intFromPtr", "@ptrFromInt" };
    for (pointer_casts) |cast| {
        if (std.mem.eql(u8, name, cast) and !ctx.pathIn(&specs.ptr_cast_allowlist)) {
            try reportUnlessTest(
                ctx,
                start,
                "ptr-cast-allowlist",
                "{s} outside allowlisted modules",
                .{name},
            );
        }
    }
}

fn checkIdentifier(ctx: *Ctx, index: usize) !void {
    const name = sliceAt(ctx, index);
    const start = ctx.tree.tokens.items(.start)[index];
    const after_dot = index > 0 and tagAt(ctx, index - 1) == .period;
    if (std.mem.eql(u8, name, "undefined") and index > 0 and tagAt(ctx, index - 1) == .equal) {
        if (!ctx.inTest(start) and !ctx.hasMarker(ctx.lineOf(start), "// SAFETY:")) {
            try ctx.report(
                start,
                "undefined-safety",
                "'= undefined' needs a '// SAFETY:' comment",
                .{},
            );
        }
    }
    if (std.mem.eql(u8, name, "process") and tagAt(ctx, index + 1) == .period) {
        const verbs = [_][]const u8{ "spawn", "run", "replace", "execv", "execve" };
        for (verbs) |verb| {
            if (std.mem.eql(
                u8,
                sliceAt(ctx, index + 2),
                verb,
            ) and !ctx.pathIn(&specs.spawn_allowlist)) {
                try ctx.report(
                    start,
                    "spawn-allowlist",
                    "process.{s} outside allowlisted modules",
                    .{verb},
                );
            }
        }
    }
    try checkBoundaryIdentifier(ctx, name, start, after_dot, index);
}

fn checkBoundaryIdentifier(
    ctx: *Ctx,
    name: []const u8,
    start: u32,
    after_dot: bool,
    index: usize,
) !void {
    const libs = std.mem.startsWith(u8, ctx.path, "libs/");
    const banned_allocators = [_][]const u8{ "page_allocator", "c_allocator", "raw_c_allocator" };
    for (banned_allocators) |banned| {
        if (libs and after_dot and std.mem.eql(u8, name, banned)) {
            try reportUnlessTest(ctx, start, "no-page-allocator", "{s} in libs/", .{name});
        }
    }
    if (std.mem.eql(u8, name, "debug") and tagAt(ctx, index + 1) == .period) {
        if (std.mem.eql(u8, sliceAt(ctx, index + 2), "print") and !ctx.pathIn(&print_allowed)) {
            try reportUnlessTest(
                ctx,
                start,
                "no-debug-print",
                "std.debug.print outside tools/tests",
                .{},
            );
        }
    }
    if (std.mem.eql(u8, name, "sleep") and after_dot and ctx.inTest(start)) {
        try ctx.report(start, "no-sleep-in-tests", "sleep in tests; use the controlled clock", .{});
    }
    const wire = std.mem.startsWith(u8, ctx.path, "libs/contracts/");
    const is_size = std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize");
    if (wire and is_size and index > 0 and tagAt(ctx, index - 1) == .colon and !ctx.inFn(start)) {
        try reportUnlessTest(
            ctx,
            start,
            "no-usize-contracts",
            "{s} in a contracts wire type",
            .{name},
        );
    }
}
