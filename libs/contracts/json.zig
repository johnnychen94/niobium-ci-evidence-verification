//! Strict JSON decode for every wire contract (ADR-0003): bounded size, depth and string length;
//! unknown fields, duplicate keys and forbidden fields rejected at any level; a newer top-level
//! `schema` fails closed with UnsupportedSchema before field-level errors.

const std = @import("std");
const limits_mod = @import("limits.zig");

pub const DecodeError = error{
    JsonTooLarge,
    JsonTooDeep,
    JsonStringTooLong,
    JsonSyntax,
    JsonUnknownField,
    JsonDuplicateField,
    JsonMissingField,
    JsonType,
    ForbiddenField,
    UnsupportedSchema,
    OutOfMemory,
};

/// Field names no contract may carry, at any depth (manifest-v1, component-v1). Same list as
/// tools/check/schemas.zig, which applies it to api/schema and examples/.
pub const forbidden_fields = [_][]const u8{
    "post_install",  "pre_install",  "post_uninstall", "pre_uninstall", "script", "scripts",
    "hook",          "hooks",        "command",        "commands",      "exec",   "shell",
    "custom_action", "run_as_admin", "eval",
};

pub const Options = struct {
    max_bytes: u32,
    /// Highest supported top-level `schema` (or `protocol` / `v`) value; null skips the check.
    max_schema: ?u32 = null,
    schema_field: []const u8 = "schema",
    limits: limits_mod.Limits = limits_mod.default,
};

/// Decode `bytes` into `T`. All allocations go to `arena`; the result borrows nothing from `bytes`.
pub fn decode(
    comptime T: type,
    arena: std.mem.Allocator,
    bytes: []const u8,
    options: Options,
) DecodeError!T {
    if (bytes.len > options.max_bytes) return error.JsonTooLarge;
    try prescan(arena, bytes, options);
    return std.json.parseFromSliceLeaky(T, arena, bytes, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .max_value_len = options.limits.json_string_bytes,
    }) catch |err| return mapError(err);
}

/// Parse into a dynamic value (TUF canonicalization) with the same prescan guarantees.
pub fn decodeValue(
    arena: std.mem.Allocator,
    bytes: []const u8,
    options: Options,
) DecodeError!std.json.Value {
    if (bytes.len > options.max_bytes) return error.JsonTooLarge;
    try prescan(arena, bytes, options);
    return std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{
        .duplicate_field_behavior = .@"error",
        .allocate = .alloc_always,
        .parse_numbers = true,
    }) catch |err| return mapError(err);
}

fn mapError(err: anyerror) DecodeError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnknownField => error.JsonUnknownField,
        error.DuplicateField => error.JsonDuplicateField,
        error.MissingField => error.JsonMissingField,
        error.ValueTooLong => error.JsonStringTooLong,
        error.SyntaxError, error.UnexpectedEndOfInput, error.BufferUnderrun => error.JsonSyntax,
        else => error.JsonType,
    };
}

const Frame = enum { object, array };

fn prescan(arena: std.mem.Allocator, bytes: []const u8, options: Options) DecodeError!void {
    var scanner = std.json.Scanner.initCompleteInput(arena, bytes);
    defer scanner.deinit();
    var stack: [256]Frame = undefined; // SAFETY: entries below `depth` are always written first.
    var depth: usize = 0;
    var expect_key = false;
    var schema_next = false;
    const max_depth = @min(options.limits.json_depth, stack.len);
    // loop-bound: every iteration consumes at least one token of the bounded input.
    while (true) {
        const token = scanner.nextAllocMax(
            arena,
            .alloc_if_needed,
            options.limits.json_string_bytes,
        ) catch |err|
            return mapError(err);
        const is_key = expect_key and depth > 0 and stack[depth - 1] == .object;
        switch (token) {
            .end_of_document => return,
            .object_begin, .array_begin => {
                if (depth >= max_depth) return error.JsonTooDeep;
                stack[depth] = if (token == .object_begin) .object else .array;
                depth += 1;
                expect_key = token == .object_begin;
                schema_next = false;
                continue;
            },
            .object_end, .array_end => depth -= 1,
            .string, .allocated_string => |text| if (is_key) {
                try checkKey(text);
                schema_next = depth == 1 and std.mem.eql(u8, text, options.schema_field);
                expect_key = false;
                continue;
            },
            .number, .allocated_number => |text| if (schema_next) try checkSchema(
                text,
                options.max_schema,
            ),
            else => {},
        }
        schema_next = false;
        expect_key = depth > 0 and stack[depth - 1] == .object;
    }
}

fn checkKey(key: []const u8) DecodeError!void {
    for (forbidden_fields) |name| {
        if (std.mem.eql(u8, key, name)) return error.ForbiddenField;
    }
}

fn checkSchema(text: []const u8, max_schema: ?u32) DecodeError!void {
    const max = max_schema orelse return;
    const value = std.fmt.parseInt(u64, text, 10) catch return error.JsonType;
    if (value > max) return error.UnsupportedSchema;
}

const Sample = struct {
    schema: u32,
    name: []const u8,
    nested: struct { value: u8 } = .{ .value = 0 },
    tags: []const []const u8 = &.{},
};

fn decodeSample(bytes: []const u8) DecodeError!Sample {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const sample = try decode(
        Sample,
        arena.allocator(),
        bytes,
        .{ .max_bytes = 1024, .max_schema = 1 },
    );
    return .{ .schema = sample.schema, .name = "", .nested = sample.nested };
}

test "N1-AC-01 strict decode rejects unknown, duplicate, forbidden, deep, newer schema" {
    _ = try decodeSample("{\"schema\":1,\"name\":\"a\"}");
    try std.testing.expectError(
        error.JsonUnknownField,
        decodeSample("{\"schema\":1,\"name\":\"a\",\"x\":1}"),
    );
    try std.testing.expectError(
        error.JsonDuplicateField,
        decodeSample("{\"schema\":1,\"name\":\"a\",\"name\":\"b\"}"),
    );
    try std.testing.expectError(
        error.ForbiddenField,
        decodeSample("{\"schema\":1,\"name\":\"a\",\"nested\":{\"post_install\":1}}"),
    );
    try std.testing.expectError(
        error.UnsupportedSchema,
        decodeSample("{\"schema\":2,\"name\":\"a\",\"future\":true}"),
    );
    try std.testing.expectError(error.JsonMissingField, decodeSample("{\"schema\":1}"));
    try std.testing.expectError(error.JsonType, decodeSample("{\"schema\":true,\"name\":\"a\"}"));
    try std.testing.expectError(error.JsonSyntax, decodeSample("{\"schema\":1,"));
    const prefix = "{\"schema\":1,\"name\":\"a\",\"tags\":";
    var deep: [prefix.len + 81]u8 = undefined; // SAFETY: every byte is written below.
    @memcpy(deep[0..prefix.len], prefix);
    @memset(deep[prefix.len..][0..40], '[');
    @memset(deep[prefix.len + 40 ..][0..40], ']');
    deep[deep.len - 1] = '}';
    try std.testing.expectError(error.JsonTooDeep, decodeSample(&deep));
}

test "N1-INV-03 forbidden field in a nested array object" {
    try std.testing.expectError(
        error.ForbiddenField,
        decodeSample(
            "{\"schema\":1,\"name\":\"a\",\"z\":[{\"script\":\"rm\"}]}",
        ),
    );
}

test "N1-AC-21 decode returns OutOfMemory on every allocation failure" {
    const input = "{\"schema\":1,\"name\":\"abc\",\"nested\":{\"value\":3},\"tags\":[\"x\",\"y\"]}";
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator, bytes: []const u8) !void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            _ = try decode(Sample, arena.allocator(), bytes, .{ .max_bytes = 1024 });
        }
    }.run, .{input});
}
