//! `nbpack` command line (docs/runbooks/release-signing.md). Parsing is pure: unknown commands
//! and options, missing values and repeated options are usage errors (exit 2).

const std = @import("std");
const contracts = @import("contracts");

pub const Error = error{
    UsageUnknownCommand,
    UsageUnknownOption,
    UsageMissingValue,
    UsageBadValue,
    UsageRepeatedOption,
    UsageUnexpectedArgument,
    UsageMissingOption,
    OutOfMemory,
};

pub const Verb = enum {
    keygen,
    component_build,
    component_validate,
    product_compose,
    publish,
    promote,
    sign,
    config,
    bundle,
    help,
};

/// Each field is the option `--<field name with '-' for '_'>`; bools are flags. `artifact`
/// may repeat.
pub const Options = struct {
    out: ?[]const u8 = null,
    source: ?[]const u8 = null,
    files: ?[]const u8 = null,
    platform: ?contracts.Platform = null,
    version: ?[]const u8 = null,
    sequence: ?u64 = null,
    product: ?[]const u8 = null,
    product_id: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    keys: ?[]const u8 = null,
    channel: ?contracts.Channel = null,
    init: bool = false,
    now: ?i64 = null,
    days: ?u32 = null,
    timestamp_days: ?u32 = null,
    branding: ?[]const u8 = null,
    logo: ?[]const u8 = null,
    repository: ?[]const u8 = null,
    setup: ?[]const u8 = null,
    artifact: []const []const u8 = &.{},
};

pub const Command = struct {
    verb: Verb,
    options: Options = .{},
    /// `component validate <artifact>`.
    target: ?[]const u8 = null,
};

fn flagName(comptime field: []const u8) []const u8 {
    comptime {
        var name: [field.len + 2]u8 = undefined; // SAFETY: every byte is written below.
        name[0] = '-';
        name[1] = '-';
        for (field, 2..) |c, i| name[i] = if (c == '_') '-' else c;
        const final = name;
        return &final;
    }
}

fn parseValue(comptime T: type, text: []const u8) Error!T {
    if (text.len == 0) return error.UsageBadValue;
    const Child = @typeInfo(T).optional.child;
    return switch (Child) {
        []const u8 => text,
        u64, u32, i64 => std.fmt.parseInt(Child, text, 10) catch error.UsageBadValue,
        else => std.meta.stringToEnum(Child, text) orelse error.UsageBadValue,
    };
}

const info = @typeInfo(Options).@"struct";
const Seen = std.StaticBitSet(info.field_names.len);

fn option(
    arena: std.mem.Allocator,
    o: *Options,
    seen: *Seen,
    argv: []const []const u8,
    index: *usize,
) Error!void {
    const arg = argv[index.*];
    inline for (info.field_names, info.field_types, 0..) |name, T, bit| {
        if (std.mem.eql(u8, arg, comptime flagName(name))) {
            if (T == bool) {
                if (seen.isSet(bit)) return error.UsageRepeatedOption;
                seen.set(bit);
                @field(o, name) = true;
                return;
            }
            index.* += 1;
            if (index.* >= argv.len) return error.UsageMissingValue;
            const value = argv[index.*];
            if (T == []const []const u8) {
                if (value.len == 0) return error.UsageBadValue;
                const list = try arena.alloc([]const u8, @field(o, name).len + 1);
                @memcpy(list[0 .. list.len - 1], @field(o, name));
                list[list.len - 1] = value;
                @field(o, name) = list;
                return;
            }
            if (seen.isSet(bit)) return error.UsageRepeatedOption;
            seen.set(bit);
            @field(o, name) = try parseValue(T, value);
            return;
        }
    }
    return error.UsageUnknownOption;
}

fn verbOf(argv: []const []const u8) Error!struct { Verb, usize } {
    const first = argv[0];
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "help")) return .{ .help, 1 };
    const pairs = .{ .{ "component", "build", Verb.component_build }, .{
        "component", "validate", Verb.component_validate,
    }, .{ "product", "compose", Verb.product_compose } };
    inline for (pairs) |pair| {
        if (std.mem.eql(u8, first, pair[0])) {
            if (argv.len > 1 and std.mem.eql(u8, argv[1], pair[1])) return .{ pair[2], 2 };
        }
    }
    const verb = std.meta.stringToEnum(Verb, first) orelse return error.UsageUnknownCommand;
    return switch (verb) {
        .component_build, .component_validate, .product_compose => error.UsageUnknownCommand,
        else => .{ verb, 1 },
    };
}

/// `argv` without the program name.
pub fn parse(arena: std.mem.Allocator, argv: []const []const u8) Error!Command {
    if (argv.len == 0) return .{ .verb = .help };
    const verb, var index = try verbOf(argv);
    var command: Command = .{ .verb = verb };
    if (verb == .component_validate) {
        if (index >= argv.len or std.mem.startsWith(u8, argv[index], "-")) {
            return error.UsageMissingValue;
        }
        command.target = argv[index];
        index += 1;
    }
    var seen: Seen = .empty;
    while (index < argv.len) : (index += 1) {
        if (!std.mem.startsWith(u8, argv[index], "--")) return error.UsageUnexpectedArgument;
        try option(arena, &command.options, &seen, argv, &index);
    }
    try required(command);
    return command;
}

fn required(c: Command) Error!void {
    const o = c.options;
    const needs: []const ?[]const u8 = switch (c.verb) {
        .keygen => &.{o.out},
        .component_build => &.{ o.source, o.files, o.version, o.out },
        .component_validate, .help => &.{},
        .product_compose => &.{ o.product, o.out },
        .publish => &.{ o.repo, o.keys, o.product },
        .promote => &.{ o.repo, o.keys, o.product_id },
        .sign => &.{ o.repo, o.keys },
        .config => &.{ o.repo, o.product, o.out },
        .bundle => &.{ o.repo, o.setup, o.out },
    };
    for (needs) |value| if (value == null) return error.UsageMissingOption;
    if (c.verb == .promote and (o.sequence == null or o.channel == null)) {
        return error.UsageMissingOption;
    }
    const artifacts = c.verb == .product_compose or c.verb == .publish;
    if (artifacts and o.artifact.len == 0) return error.UsageMissingOption;
}

pub const usage =
    \\usage: nbpack keygen --out <dir>
    \\       nbpack component build --source <component.json> --files <dir> --version <x.y.z>
    \\                              [--platform <os-arch>] --out <artifact.tar.zst>
    \\       nbpack component validate <artifact.tar.zst> [--platform <os-arch>]
    \\       nbpack product compose --product <product.json> --artifact <file>...
    \\                              [--version <x.y.z>] [--sequence <n>] --out <manifest.json>
    \\       nbpack publish --repo <dir> --keys <dir> --product <product.json> --artifact <file>...
    \\                      [--channel <c>] [--version <x.y.z>] [--sequence <n>] [--init] [clock]
    \\       nbpack promote --repo <dir> --keys <dir> --product-id <id> --sequence <n>
    \\                      --channel <c> [clock]
    \\       nbpack sign --repo <dir> --keys <dir> [clock]
    \\       nbpack config --repo <dir> --product <product.json> [--branding <file>]
    \\                     [--logo <png>] [--repository <url|dir>] [--channel <c>] --out <file>
    \\       nbpack bundle --repo <dir> --setup <exe> --out <dir>
    \\
    \\clock: --now <unix seconds> --days <n> (default 30) --timestamp-days <n> (default 1)
    \\
;

test "nbpack parses commands, repeated artifacts and required options" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const publish = try parse(a, &.{
        "publish",    "--repo", "r",          "--keys", "k",      "--product", "p.json",
        "--artifact", "a.zst",  "--artifact", "b.zst",  "--init", "--days",    "365",
    });
    try std.testing.expectEqual(Verb.publish, publish.verb);
    try std.testing.expectEqual(@as(usize, 2), publish.options.artifact.len);
    try std.testing.expectEqualStrings("b.zst", publish.options.artifact[1]);
    try std.testing.expectEqual(@as(u32, 365), publish.options.days.?);
    const validate = try parse(a, &.{ "component", "validate", "x.tar.zst" });
    try std.testing.expectEqualStrings("x.tar.zst", validate.target.?);
    const cases = [_]struct { Error, []const []const u8 }{
        .{ error.UsageUnknownCommand, &.{"frobnicate"} },
        .{ error.UsageUnknownCommand, &.{"component_build"} },
        .{ error.UsageMissingOption, &.{ "sign", "--repo", "r" } },
        .{
            error.UsageMissingOption,
            &.{ "publish", "--repo", "r", "--keys", "k", "--product", "p" },
        },
        .{ error.UsageBadValue, &.{ "sign", "--repo", "r", "--keys", "k", "--days", "x" } },
        .{ error.UsageRepeatedOption, &.{ "keygen", "--out", "a", "--out", "b" } },
        .{ error.UsageMissingValue, &.{ "component", "validate" } },
    };
    for (cases) |case| try std.testing.expectError(case[0], parse(a, case[1]));
}
