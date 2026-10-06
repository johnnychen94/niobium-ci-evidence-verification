//! `setup` command line (docs/spec/cli-v1.md#commands). Parsing is pure so every rule is tested:
//! unknown commands and options, missing values and repeated options are usage errors (exit 2).

const std = @import("std");
const contracts = @import("contracts");

pub const Error = error{
    UsageUnknownCommand,
    UsageUnknownOption,
    UsageMissingValue,
    UsageBadValue,
    UsageRepeatedOption,
    UsageUnexpectedArgument,
    OutOfMemory,
};

pub const Verb = enum { gui, install, update, repair, uninstall, run, status, version, help };

/// Each field is the option `--<field name with '-' for '_'>`; bools are flags.
pub const Options = struct {
    silent: bool = false,
    json: bool = false,
    scope: ?contracts.Scope = null,
    channel: ?contracts.Channel = null,
    product: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    trust_root: ?[]const u8 = null,
    config: ?[]const u8 = null,
    install_dir: ?[]const u8 = null,
    components: ?[]const []const u8 = null,
};

pub const Command = struct {
    verb: Verb,
    options: Options = .{},
    /// `run`: `<product>[:<component>.<entrypoint>]`.
    target: ?[]const u8 = null,
    /// `run`: everything after `--`, passed to the program untouched.
    args: []const []const u8 = &.{},
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

fn parseList(arena: std.mem.Allocator, text: []const u8) Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |item| {
        if (!contracts.ids.isComponentId(item)) return error.UsageBadValue;
        try list.append(arena, item);
    }
    return list.items;
}

fn parseValue(comptime T: type, arena: std.mem.Allocator, text: []const u8) Error!T {
    if (text.len == 0) return error.UsageBadValue;
    return switch (T) {
        ?contracts.Scope, ?contracts.Channel => std.meta.stringToEnum(
            @typeInfo(T).optional.child,
            text,
        ) orelse
            error.UsageBadValue,
        ?[]const []const u8 => try parseList(arena, text),
        ?[]const u8 => text,
        else => comptime unreachable,
    };
}

const option_info = @typeInfo(Options).@"struct";
const Seen = std.StaticBitSet(option_info.field_names.len);

/// Consumes `argv[index.*]` (and its value); `index` is left on the last consumed argument.
fn option(
    arena: std.mem.Allocator,
    options: *Options,
    seen: *Seen,
    argv: []const []const u8,
    index: *usize,
) Error!void {
    const arg = argv[index.*];
    inline for (option_info.field_names, option_info.field_types, 0..) |name, T, bit| {
        if (std.mem.eql(u8, arg, comptime flagName(name))) {
            if (seen.isSet(bit)) return error.UsageRepeatedOption;
            seen.set(bit);
            if (T == bool) {
                @field(options, name) = true;
                return;
            }
            index.* += 1;
            if (index.* >= argv.len) return error.UsageMissingValue;
            @field(options, name) = try parseValue(T, arena, argv[index.*]);
            return;
        }
    }
    return error.UsageUnknownOption;
}

/// `argv` without the program name.
pub fn parse(arena: std.mem.Allocator, argv: []const []const u8) Error!Command {
    if (argv.len == 0) return .{ .verb = .gui };
    const first = argv[0];
    const verb: Verb = if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h"))
        .help
    else if (std.mem.eql(u8, first, "--version"))
        .version
    else
        std.meta.stringToEnum(Verb, first) orelse return error.UsageUnknownCommand;
    if (verb == .gui) return error.UsageUnknownCommand;
    var command: Command = .{ .verb = verb };
    var index: usize = 1;
    if (verb == .run) {
        if (argv.len < 2 or std.mem.startsWith(u8, argv[1], "-")) return error.UsageMissingValue;
        command.target = argv[1];
        index = 2;
    }
    var seen: Seen = .empty;
    while (index < argv.len) : (index += 1) {
        if (std.mem.eql(u8, argv[index], "--")) {
            if (verb != .run) return error.UsageUnexpectedArgument;
            command.args = argv[index + 1 ..];
            break;
        }
        if (!std.mem.startsWith(u8, argv[index], "--")) return error.UsageUnexpectedArgument;
        try option(arena, &command.options, &seen, argv, &index);
    }
    if (command.options.product) |id| if (!contracts.ids.isProductId(id)) {
        return error.UsageBadValue;
    };
    return command;
}

pub const usage =
    \\usage: setup                                   open the installer window
    \\       setup install   [options]
    \\       setup update    [options]
    \\       setup repair    [options]
    \\       setup uninstall [options]
    \\       setup run <product>[:<component>.<entrypoint>] [options] [-- args...]
    \\       setup status    [options]
    \\       setup version
    \\
    \\options: --silent --json --scope user|machine --channel stable|beta|nightly
    \\         --product <id> --repo <url|dir> --trust-root <file> --config <file>
    \\         --install-dir <dir> --components a,b
    \\
;

test "N1-AC-09 cli parses commands and options" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(Verb.gui, (try parse(a, &.{})).verb);
    try std.testing.expectEqual(Verb.version, (try parse(a, &.{"--version"})).verb);
    const install = try parse(a, &.{
        "install",     "--silent",  "--json",            "--scope",               "machine",
        "--channel",   "beta",      "--repo",            "https://example.com/y", "--components",
        "runtime,cli", "--product", "com.example.hello", "--install-dir",         "/opt/h",
    });
    try std.testing.expectEqual(Verb.install, install.verb);
    try std.testing.expect(install.options.silent and install.options.json);
    try std.testing.expectEqual(contracts.Scope.machine, install.options.scope.?);
    try std.testing.expectEqual(contracts.Channel.beta, install.options.channel.?);
    try std.testing.expectEqualStrings("cli", install.options.components.?[1]);
    try std.testing.expectEqualStrings("/opt/h", install.options.install_dir.?);
    const run = try parse(a, &.{ "run", "com.example.hello:runtime.main", "--json", "--", "-x" });
    try std.testing.expectEqualStrings("com.example.hello:runtime.main", run.target.?);
    try std.testing.expectEqualStrings("-x", run.args[0]);
}

test "N1-AC-09 cli usage errors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { Error, []const []const u8 }{
        .{ error.UsageUnknownCommand, &.{"frobnicate"} },
        .{ error.UsageUnknownCommand, &.{"gui"} },
        .{ error.UsageUnknownOption, &.{ "install", "--force" } },
        .{ error.UsageMissingValue, &.{ "install", "--scope" } },
        .{ error.UsageBadValue, &.{ "install", "--scope", "global" } },
        .{ error.UsageBadValue, &.{ "install", "--components", "a,,b" } },
        .{ error.UsageBadValue, &.{ "install", "--product", "Not An Id" } },
        .{ error.UsageRepeatedOption, &.{ "install", "--json", "--json" } },
        .{ error.UsageUnexpectedArgument, &.{ "install", "extra" } },
        .{ error.UsageUnexpectedArgument, &.{ "install", "--", "x" } },
        .{ error.UsageMissingValue, &.{"run"} },
        .{ error.UsageMissingValue, &.{ "run", "--json" } },
    };
    for (cases) |case| try std.testing.expectError(case[0], parse(a, case[1]));
}
