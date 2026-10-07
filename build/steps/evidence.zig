const std = @import("std");
pub const catalog = @import("../test_catalog.zig");
pub const Config = struct {
    exe: *std.Build.Step.Compile,
    filter: ?[]const u8 = null,
    seeds: u32 = 500,
    seed_start: u64 = 0,
    tsan: bool = false,
    coverage: bool = false,
    r2_live: bool = false,
};

pub fn addRun(
    b: *std.Build,
    config: Config,
    suite: catalog.Suite,
    exe: *std.Build.Step.Compile,
    coverage: ?[]const u8,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(config.exe);
    const target = exe.root_module.resolved_target.?.result;
    run.addArgs(&.{
        "run",
        @tagName(suite),
        exe.name,
        target.zigTriple(b.allocator) catch @panic("OOM"),
        config.filter orelse "",
        b.fmt("seeds={d}", .{config.seeds}),
        b.fmt("seed-start={d}", .{config.seed_start}),
        b.fmt("tsan={}", .{config.tsan}),
        b.fmt("coverage={}", .{config.coverage}),
    });
    if (coverage) |dir| {
        const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", dir });
        mkdir.has_side_effects = true;
        run.step.dependOn(&mkdir.step);
        run.addArgs(&.{ "kcov", "--include-pattern=libs/|apps/|tools/|build/", dir });
    }
    run.addArtifactArg(exe);
    run.setEnvironmentVariable(
        "NIOBIUM_R2_LIVE_VERIFY",
        if (config.r2_live and std.mem.eql(u8, exe.name, "tool-evidence")) "1" else "0",
    );
    run.has_side_effects = true;
    run.setCwd(b.path("."));
    return run;
}

pub fn addModule(b: *std.Build, module: *std.Build.Module) void {
    const evidence = b.createModule(.{
        .root_source_file = b.path("tools/evidence/records.zig"),
        .target = module.resolved_target,
        .optimize = module.optimize,
    });
    evidence.addImport("contracts", module.import_table.get("contracts").?);
    evidence.addImport("test_catalog", b.createModule(.{
        .root_source_file = b.path("build/test_catalog.zig"),
    }));
    module.addImport("test_evidence", evidence);
}

pub const Selection = struct {
    config: Config,
    selection: catalog.Selection,
    narrowed: bool,
};

pub fn options(b: *std.Build, initial: Config) error{InvalidSelection}!Selection {
    const suite = b.option([]const u8, "suite", "Comma-separated registered suites");
    const case = b.option([]const u8, "case", "Stable case ID within selected suites");
    const selection = catalog.Selection.parse(suite, case) catch {
        std.debug.print(
            "Invalid suite/case selection: unknown, duplicate, empty or no match\n",
            .{},
        );
        b.invalid_user_input = true;
        return error.InvalidSelection;
    };
    const r2_live = b.option(
        bool,
        "r2-live",
        "Explicit live R2 protocol verification",
    ) orelse false;
    if (r2_live and (!selection.suites.contains(.unit) or case != null)) {
        std.debug.print("Live R2 verification requires the unfiltered unit suite\n", .{});
        b.invalid_user_input = true;
        return error.InvalidSelection;
    }
    if (!catalog.validSeedRange(initial.seeds, initial.seed_start)) {
        std.debug.print("Invalid simulation seed range\n", .{});
        b.invalid_user_input = true;
        return error.InvalidSelection;
    }
    const action = b.option([]const u8, "action", "Evidence action: validate or publish") orelse
        "validate";
    const input = b.option([]const u8, "input", "Saved evidence directory") orelse ".evidence";
    const run = b.addRunArtifact(initial.exe);
    run.addArgs(&.{ action, input });
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    b.step("evidence", "Validate or publish saved results").dependOn(&run.step);
    var config = initial;
    config.filter = case;
    config.r2_live = r2_live;
    return .{ .config = config, .selection = selection, .narrowed = suite != null or case != null };
}

pub fn select(
    b: *std.Build,
    selected: Selection,
    steps: []const *std.Build.Step,
    tsan: ?*std.Build.Step,
) void {
    const step = b.step("test", "Selected suites (default: unit,conformance)");
    for (std.enums.values(catalog.Suite), steps) |suite, suite_step| {
        if (selected.selection.suites.contains(suite)) step.dependOn(suite_step);
    }
    if (selected.config.tsan) step.dependOn(tsan.?);
}
