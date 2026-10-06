//! `nbpack`: the publisher's tool (docs/runbooks/release-signing.md, offline-bundle.md).
//! Process assembly only; the work is libs/packager.

const std = @import("std");
const build_options = @import("build_options");
const contracts = @import("contracts");
const core = @import("core");
const packager = @import("packager");
const cli = @import("cli.zig");

pub const panic = std.debug.FullPanic(core.crash.panic);
pub const debug = struct {
    pub const handleSegfault = core.crash.handleSegfault;
};

const Dir = std.Io.Dir;
const max_input = 1 << 20;
const max_artifact = 4 << 30;

const Ctx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    out: *std.Io.Writer,
    command: cli.Command,

    fn read(c: *const Ctx, path: []const u8, max: usize) ![]const u8 {
        return Dir.cwd().readFileAlloc(c.io, path, c.arena, .limited(max));
    }

    fn write(c: *const Ctx, path: []const u8, bytes: []const u8) !void {
        if (std.fs.path.dirname(path)) |parent| try Dir.cwd().createDirPath(c.io, parent);
        try Dir.cwd().writeFile(c.io, .{ .sub_path = path, .data = bytes });
    }

    fn openDir(c: *const Ctx, path: []const u8, create: bool) !Dir {
        if (create) return Dir.cwd().createDirPathOpen(c.io, path, .{
            .open_options = .{ .iterate = true },
        });
        return Dir.cwd().openDir(c.io, path, .{ .iterate = true });
    }

    fn clock(c: *const Ctx) packager.repo.Clock {
        const o = c.command.options;
        return .{
            .now = o.now orelse std.Io.Clock.real.now(c.io).toSeconds(),
            .days = o.days orelse 30,
            .timestamp_days = o.timestamp_days orelse 1,
        };
    }
};

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const raw = init.minimal.args.toSlice(arena) catch return 1;
    var out_buffer: [4096]u8 = undefined; // SAFETY: writer scratch.
    var err_buffer: [1024]u8 = undefined; // SAFETY: writer scratch.
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    var stderr = std.Io.File.stderr().writerStreaming(io, &err_buffer);
    const argv = if (raw.len > 0) raw[1..] else raw;
    const command = cli.parse(arena, argv) catch |err| {
        stderr.interface.print("nbpack: {t}\n\n{s}", .{ err, cli.usage }) catch return 1;
        stderr.interface.flush() catch return 1;
        return @backingInt(core.ExitCode.usage);
    };
    var c: Ctx = .{
        .io = io,
        .gpa = init.gpa,
        .arena = arena,
        .out = &stdout.interface,
        .command = command,
    };
    run(&c) catch |err| {
        stderr.interface.print("nbpack: {t}\n", .{err}) catch return 1;
        stderr.interface.flush() catch return 1;
        return @backingInt(core.exit_code.fromError(err));
    };
    stdout.interface.flush() catch return 1;
    return 0;
}

fn run(c: *Ctx) !void {
    switch (c.command.verb) {
        .help => try c.out.writeAll(cli.usage),
        .keygen => {
            var dir = try c.openDir(c.command.options.out.?, true);
            defer dir.close(c.io);
            try packager.keys.generate(c.io, c.arena, dir);
        },
        .component_build => try componentBuild(c),
        .component_validate => {
            const path = c.command.target.?;
            const meta = try check(c, try c.read(path, max_artifact), path);
            try c.out.print("{s} {s} {t}\n", .{ meta.id, meta.version, meta.platform });
        },
        .product_compose => {
            const manifest, _ = try compose(c);
            try c.write(c.command.options.out.?, manifest);
        },
        .publish => try publish(c),
        .promote, .sign => try resign(c),
        .config => try config(c),
        .bundle => try bundle(c),
    }
}

fn componentBuild(c: *Ctx) !void {
    const o = c.command.options;
    var files = try c.openDir(o.files.?, false);
    defer files.close(c.io);
    const platform = o.platform orelse contracts.Platform.current() orelse
        return error.PlatformUnsupported;
    const bytes = try packager.component.build(c.io, c.gpa, c.arena, try c.read(
        o.source.?,
        max_input,
    ), files, .{
        .platform = platform,
        .version = o.version.?,
    });
    const meta = try check(c, bytes, o.out.?);
    try c.write(o.out.?, bytes);
    try c.out.print(
        "{s} {s} {t}: {d} bytes\n",
        .{ meta.id, meta.version, meta.platform, bytes.len },
    );
}

/// Runs the runtime's extractor over `bytes` in a scratch directory next to `near`.
fn check(c: *Ctx, bytes: []const u8, near: []const u8) !contracts.manifest.ComponentMeta {
    const scratch_path = try std.fmt.allocPrint(c.arena, "{s}.nbpack-check", .{near});
    if (std.fs.path.dirname(scratch_path)) |parent| try Dir.cwd().createDirPath(c.io, parent);
    try Dir.cwd().deleteTree(c.io, scratch_path);
    var scratch = try Dir.cwd().createDirPathOpen(c.io, scratch_path, .{});
    defer {
        scratch.close(c.io);
        Dir.cwd().deleteTree(c.io, scratch_path) catch |err| {
            std.log.warn("{s}: {t}", .{ scratch_path, err });
        };
    }
    return packager.component.validate(
        c.io,
        c.gpa,
        c.arena,
        bytes,
        scratch,
        c.command.options.platform,
    );
}

/// The manifest for `--product` over every `--artifact`, and the artifact bytes.
fn compose(c: *Ctx) !struct { []const u8, []const []const u8 } {
    const o = c.command.options;
    const artifacts = try c.arena.alloc(packager.compose.Artifact, o.artifact.len);
    const bytes = try c.arena.alloc([]const u8, o.artifact.len);
    for (artifacts, bytes, o.artifact) |*a, *raw, path| {
        raw.* = try c.read(path, max_artifact);
        a.* = .{ .bytes = raw.*, .meta = try check(c, raw.*, path) };
    }
    const manifest = try packager.compose.compose(
        c.arena,
        try c.read(o.product.?, max_input),
        artifacts,
        .{ .version = o.version, .sequence = o.sequence },
        build_options.version,
    );
    return .{ manifest, bytes };
}

fn publish(c: *Ctx) !void {
    const o = c.command.options;
    const manifest, const artifacts = try compose(c);
    var repo = try c.openDir(o.repo.?, o.init);
    defer repo.close(c.io);
    var keys = try c.openDir(o.keys.?, false);
    defer keys.close(c.io);
    var state = try packager.repo.load(c.io, c.arena, repo);
    if (o.init and state.root_version != 0) return error.PackRepoNotEmpty;
    if (!o.init and state.root_version == 0) return error.PackRepoEmpty;
    const channel = o.channel orelse .stable;
    try packager.repo.addRelease(c.arena, &state, manifest, artifacts, channel);
    const set = try packager.keys.loadSet(c.io, c.arena, keys);
    try packager.repo.write(c.io, c.arena, repo, &state, set, c.clock());
    try c.out.print(
        "published to {t} (timestamp {d})\n",
        .{ channel, state.timestamp_version + 1 },
    );
}

/// `promote` (serve a release on another channel) and `sign` (refresh expiry).
fn resign(c: *Ctx) !void {
    const o = c.command.options;
    var repo = try c.openDir(o.repo.?, false);
    defer repo.close(c.io);
    var keys = try c.openDir(o.keys.?, false);
    defer keys.close(c.io);
    var state = try packager.repo.load(c.io, c.arena, repo);
    if (state.root_version == 0) return error.PackRepoEmpty;
    if (c.command.verb == .promote) {
        try packager.repo.promote(c.arena, &state, o.product_id.?, o.sequence.?, o.channel.?);
    }
    const set = try packager.keys.loadSet(c.io, c.arena, keys);
    try packager.repo.write(c.io, c.arena, repo, &state, set, c.clock());
}

fn config(c: *Ctx) !void {
    const o = c.command.options;
    var repo = try c.openDir(o.repo.?, false);
    defer repo.close(c.io);
    const template = try packager.compose.parseTemplate(
        c.arena,
        try c.read(o.product.?, max_input),
    );
    const bytes = try packager.setup.config(c.arena, .{
        .product_id = template.product.id,
        .root_bytes = try packager.repo.rootBytes(c.io, c.arena, repo),
        .repository = o.repository,
        .channel = o.channel orelse .stable,
        .branding_json = if (o.branding) |path| try c.read(path, max_input) else null,
        .logo_png = if (o.logo) |path| try c.read(path, max_input) else null,
    });
    try c.write(o.out.?, bytes);
}

fn bundle(c: *Ctx) !void {
    const o = c.command.options;
    var repo = try c.openDir(o.repo.?, false);
    defer repo.close(c.io);
    const setup_path = o.setup.?;
    var setup_dir = try c.openDir(std.fs.path.dirname(setup_path) orelse ".", false);
    defer setup_dir.close(c.io);
    var out = try c.openDir(o.out.?, true);
    defer out.close(c.io);
    try packager.setup.bundle(
        c.io,
        c.arena,
        repo,
        setup_dir,
        std.fs.path.basename(setup_path),
        out,
    );
}

test {
    _ = cli;
}
