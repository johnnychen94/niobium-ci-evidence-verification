//! `setup --priv-helper-v1` (ADR-0007, docs/spec/ipc-v1.md): a closed-op server over one
//! length-prefixed JSON stream. Every request must carry the session's tx and nonce and a
//! strictly increasing id; every path must lie inside a managed root (or, for copy sources, a
//! declared staging root or the helper's own executable). Mutations go to `backend`, the host
//! platform. There is no op that executes a program, loads a library or opens a socket.
//!
//! The helper confines what a broker can touch; it does not judge content. Payload authenticity
//! is established by the broker (TUF) before anything reaches the helper.

const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts");
const platform = @import("platform");

const ipc = contracts.ipc;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;

pub const Expect = struct {
    tx: []const u8,
    nonce: []const u8,
};

/// Decided by `apps/setup` from the framework's path policy, never by the broker.
pub const Policy = struct {
    /// Machine install bases; a managed root must be `<base><sep><product id>`.
    install_bases: []const []const u8,
    /// Directories the host backend writes machine-scope integration files into.
    integration_dirs: []const []const u8,
    /// The helper's own executable, copied as the maintainer.
    self_exe: []const u8,
};

pub const Outcome = enum { bye, broker_gone, protocol_violation };

/// Wire error names beyond `platform.Error`.
pub const Violation = enum {
    tx_mismatch,
    replayed_id,
    bad_request,
    path_outside_managed_root,
    scope_not_machine,
    not_hello,
};

const max_requests: u64 = 1 << 24;
const max_roots = 16;

const Session = struct {
    io: std.Io,
    backend: platform.Platform,
    policy: Policy,
    managed: []const []const u8 = &.{},
    sources: []const []const u8 = &.{},
    last_id: u64 = 0,
};

const Reply = union(enum) {
    ok,
    location: []const u8,
    free_bytes: u64,
    failed: []const u8,
};

fn equalSecret(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

fn sep() u8 {
    return std.fs.path.sep;
}

fn eqlPath(a: []const u8, b: []const u8) bool {
    if (builtin.os.tag == .windows) return std.ascii.eqlIgnoreCase(a, b);
    return std.mem.eql(u8, a, b);
}

/// Absolute, no `.`/`..`/empty segments, no trailing separator, no NUL.
pub fn normalized(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path) or std.mem.findScalar(u8, path, 0) != null) return false;
    if (path.len > 1 and (path[path.len - 1] == '/' or path[path.len - 1] == '\\')) return false;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    var first = true;
    while (it.next()) |part| {
        defer first = false;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        if (builtin.os.tag == .windows and first and part.len == 2 and part[1] == ':') continue;
    }
    const doubled = std.mem.find(u8, path[1..], "//") != null or
        std.mem.find(u8, path[1..], "\\\\") != null;
    return !doubled;
}

/// `path` equals `root` or lies strictly beneath it.
pub fn within(root: []const u8, path: []const u8) bool {
    if (!normalized(path)) return false;
    if (path.len < root.len or !eqlPath(path[0..root.len], root)) return false;
    return path.len == root.len or path[root.len] == '/' or path[root.len] == '\\';
}

fn inAny(roots: []const []const u8, path: []const u8) bool {
    for (roots) |root| if (within(root, path)) return true;
    return false;
}

fn managedRoot(policy: Policy, root: []const u8) bool {
    if (!normalized(root)) return false;
    const parent = std.fs.path.dirname(root) orelse return false;
    const name = std.fs.path.basename(root);
    if (!contracts.ids.isProductId(name)) return false;
    for (policy.install_bases) |base| if (eqlPath(base, parent)) return true;
    return false;
}

fn checkHello(s: *Session, arena: Allocator, message: ipc.Message, expect: Expect) ?Violation {
    if (message.type != .hello) return .not_hello;
    if (!equalSecret(message.tx orelse "", expect.tx)) return .tx_mismatch;
    if (!equalSecret(message.nonce orelse "", expect.nonce)) return .tx_mismatch;
    const managed = message.managed_roots orelse return .bad_request;
    const sources = message.source_roots orelse &.{};
    if (managed.len == 0 or managed.len > max_roots or sources.len > max_roots) {
        return .bad_request;
    }
    for (managed) |root| if (!managedRoot(s.policy, root)) return .path_outside_managed_root;
    for (sources) |root| {
        if (!normalized(root) or inAny(managed, root)) return .path_outside_managed_root;
        // A staging root sits at least three levels down (`<cache>/<product>/staging/tx-n`).
        var depth: usize = 0;
        var it = std.mem.tokenizeAny(u8, root, "/\\");
        while (it.next()) |_| depth += 1;
        if (depth < 3) return .path_outside_managed_root;
    }
    s.managed = arena.dupe([]const u8, managed) catch return .bad_request;
    s.sources = arena.dupe([]const u8, sources) catch return .bad_request;
    return null;
}

fn managedPath(s: *const Session, path: ?[]const u8) error{Violation}![]const u8 {
    const p = path orelse return error.Violation;
    if (!inAny(s.managed, p)) return error.Violation;
    return p;
}

/// Opens `source` without following any symlink at or below its staging root and streams it
/// into `target` atomically. The executable copied as maintainer is the helper itself.
fn copyNoFollow(
    s: *const Session,
    source: []const u8,
    target: []const u8,
    executable: bool,
) platform.Error!void {
    const io = s.io;
    var file: std.Io.File = blk: {
        if (eqlPath(source, s.policy.self_exe)) {
            break :blk Dir.cwd().openFile(
                io,
                source,
                .{},
            ) catch |err| return platform.api.mapFs(err);
        }
        // Staging roots, plus copies inside the managed roots (maintainer, repair).
        for ([_][]const []const u8{ s.sources, s.managed }) |roots| for (roots) |root| {
            if (!within(root, source) or source.len == root.len) continue;
            var dir = Dir.cwd().openDir(io, root, .{ .follow_symlinks = false }) catch |err|
                return noFollowError(err);
            defer dir.close(io);
            const relative = source[root.len + 1 ..];
            var parts = std.mem.tokenizeAny(u8, relative, "/\\");
            var current = dir;
            var opened: ?Dir = null;
            defer if (opened) |*d| d.close(io);
            var name = parts.next() orelse return error.FsNotFound;
            while (parts.next()) |next| {
                const child = current.openDir(io, name, .{ .follow_symlinks = false }) catch |err|
                    return noFollowError(err);
                if (opened) |*d| d.close(io);
                opened = child;
                current = child;
                name = next;
            }
            break :blk current.openFile(io, name, .{ .follow_symlinks = false }) catch |err|
                return noFollowError(err);
        };
        return error.FsAccessDenied;
    };
    defer file.close(io);
    const stat = file.stat(io) catch |err| return platform.api.mapFs(err);
    // Extraction never creates hard links; a second link would alias a file elsewhere.
    if (stat.kind != .file or stat.nlink > 1) return error.FsAccessDenied;
    var atomic = Dir.cwd().createFileAtomic(io, target, .{
        .replace = true,
        .permissions = if (executable) .executable_file else .default_file,
    }) catch |err| return platform.api.mapFs(err);
    defer atomic.deinit(io);
    var read_buffer: [64 * 1024]u8 = undefined; // SAFETY: reader-owned scratch.
    var write_buffer: [64 * 1024]u8 = undefined; // SAFETY: writer-owned scratch.
    var reader = file.reader(io, &read_buffer);
    var writer = atomic.file.writer(io, &write_buffer);
    const copied = reader.interface.streamRemaining(&writer.interface) catch
        return error.FsIo;
    writer.interface.flush() catch return error.FsIo;
    if (copied != stat.size) return error.FsIo;
    atomic.file.sync(io) catch |err| return platform.api.mapFs(err);
    atomic.replace(io) catch |err| return platform.api.mapFs(err);
}

/// A symlink where a directory or file was expected is a refusal, not an I/O error.
// lint-allow(no-anyerror-pub): adapter over the open error sets; not public.
fn noFollowError(err: anyerror) platform.Error {
    return switch (err) {
        error.SymLinkLoop, error.NotDir, error.IsDir => error.FsAccessDenied,
        else => platform.api.mapFs(err),
    };
}

fn decodeContents(arena: Allocator, text: ?[]const u8) error{Violation}![]const u8 {
    const encoded = text orelse return error.Violation;
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(encoded) catch return error.Violation;
    const bytes = arena.alloc(u8, len) catch return error.Violation;
    decoder.decode(bytes, encoded) catch return error.Violation;
    return bytes;
}

fn integrationRequest(
    s: *const Session,
    args: ipc.Args,
) error{ Violation, NotMachine }!platform.api.IntegrationRequest {
    const i = args.integration orelse return error.Violation;
    if (i.scope != .machine) return error.NotMachine;
    if (!inAny(s.managed, i.root)) return error.Violation;
    return .{
        .integration = i.integration,
        .product_id = i.product_id,
        .product_name = i.product_name,
        .scope = i.scope,
        .root = i.root,
        .tx = i.tx,
    };
}

fn integrationLocation(s: *const Session, location: []const u8) bool {
    // Registry keys and SCM names are validated (and ownership-checked) by the backend.
    if (!std.fs.path.isAbsolute(location)) return true;
    const parent = std.fs.path.dirname(location) orelse return false;
    if (!normalized(location)) return false;
    for (s.policy.integration_dirs) |dir| if (eqlPath(dir, parent)) return true;
    return inAny(s.managed, location);
}

fn dispatch(s: *Session, arena: Allocator, op: ipc.Op, args: ipc.Args) Reply {
    return run(s, arena, op, args) catch |err| switch (err) {
        error.Violation => .{ .failed = @tagName(Violation.path_outside_managed_root) },
        error.NotMachine => .{ .failed = @tagName(Violation.scope_not_machine) },
        else => |e| .{ .failed = @errorName(e) },
    };
}

fn run(
    s: *Session,
    arena: Allocator,
    op: ipc.Op,
    args: ipc.Args,
) (platform.Error || error{ Violation, NotMachine })!Reply {
    const b = s.backend;
    switch (op) {
        .create_directory => try b.createDirPath(try managedPath(s, args.path)),
        .write_file => try b.writeFile(
            try managedPath(s, args.path),
            try decodeContents(arena, args.contents),
            args.executable,
        ),
        .append_file => try b.appendFile(
            try managedPath(s, args.path),
            try decodeContents(arena, args.contents),
        ),
        .copy_file => {
            const target = try managedPath(s, args.target);
            const source = args.source orelse return error.Violation;
            if (!normalized(source)) return error.Violation;
            try copyNoFollow(s, source, target, args.executable);
        },
        .rename => try b.rename(try managedPath(s, args.source), try managedPath(s, args.target)),
        .remove_file => try b.deleteFile(try managedPath(s, args.path)),
        .remove_tree => try b.deleteTree(try managedPath(s, args.path)),
        .set_pointer => {
            const link = try managedPath(s, args.path);
            const target = args.target orelse return error.Violation;
            if (std.mem.find(u8, target, "..") != null or std.fs.path.isAbsolute(target)) {
                return error.Violation;
            }
            try b.setPointer(link, target);
        },
        .remove_pointer => try b.deletePointer(try managedPath(s, args.path)),
        .prepare_integration => {
            const r = try integrationRequest(s, args);
            try b.prepareIntegration(&r);
        },
        .discard_integration => {
            const r = try integrationRequest(s, args);
            try b.discardIntegration(&r);
        },
        .activate_integration => {
            const r = try integrationRequest(s, args);
            return .{ .location = try b.activateIntegration(arena, &r) };
        },
        .remove_integration => {
            const installed = args.installed orelse return error.Violation;
            if (!integrationLocation(s, installed.location)) return error.Violation;
            try b.removeIntegration(installed);
        },
        .free_space => return .{ .free_bytes = try b.freeSpace(try managedPath(s, args.path)) },
    }
    return .ok;
}

fn respond(writer: *std.Io.Writer, arena: Allocator, id: u64, reply: Reply) bool {
    var message: ipc.Message = .{ .v = ipc.version, .type = .response, .id = id, .ok = true };
    switch (reply) {
        .ok => {},
        .location => |text| message.location = text,
        .free_bytes => |n| message.free_bytes = n,
        .failed => |name| {
            message.ok = false;
            message.@"error" = name;
        },
    }
    const payload = ipc.encode(arena, message) catch return false;
    ipc.writeFrame(writer, payload) catch return false;
    return true;
}

/// Serve one transaction. Returns when the broker says bye, disappears, or breaks protocol.
pub fn serve(
    io: std.Io,
    gpa: Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    expect: Expect,
    policy: Policy,
    backend: platform.Platform,
) Outcome {
    var session_arena: std.heap.ArenaAllocator = .init(gpa);
    defer session_arena.deinit();
    var message_arena: std.heap.ArenaAllocator = .init(gpa);
    defer message_arena.deinit();
    var s: Session = .{ .io = io, .backend = backend, .policy = policy };

    const hello_bytes = ipc.readFrame(message_arena.allocator(), reader) catch return .broker_gone;
    const hello = ipc.decode(message_arena.allocator(), hello_bytes) catch {
        // lint-allow(no-discard-call): the broker may already be gone; we exit either way.
        _ = respond(writer, message_arena.allocator(), 0, .{ .failed = "bad_request" });
        return .protocol_violation;
    };
    if (checkHello(&s, session_arena.allocator(), hello, expect)) |violation| {
        // lint-allow(no-discard-call): the broker may already be gone; we exit either way.
        _ = respond(writer, message_arena.allocator(), 0, .{ .failed = @tagName(violation) });
        return .protocol_violation;
    }
    if (!respond(writer, message_arena.allocator(), 0, .ok)) return .broker_gone;

    for (0..max_requests) |_| {
        // lint-allow(no-discard-call): reset reports whether capacity was kept; either is fine.
        _ = message_arena.reset(.retain_capacity);
        const arena = message_arena.allocator();
        const bytes = ipc.readFrame(arena, reader) catch return .broker_gone;
        const message = ipc.decode(arena, bytes) catch {
            // lint-allow(no-discard-call): a malformed frame ends the session regardless.
            _ = respond(writer, arena, s.last_id, .{ .failed = "bad_request" });
            return .protocol_violation;
        };
        const authentic = equalSecret(message.tx orelse "", expect.tx) and
            equalSecret(message.nonce orelse "", expect.nonce);
        if (!authentic) {
            // lint-allow(no-discard-call): a forged frame ends the session regardless.
            _ = respond(writer, arena, message.id orelse 0, .{ .failed = "tx_mismatch" });
            return .protocol_violation;
        }
        switch (message.type) {
            .bye => {
                // lint-allow(no-discard-call): the session is over either way.
                _ = respond(writer, arena, message.id orelse s.last_id, .ok);
                return .bye;
            },
            .request => {},
            .hello, .response => {
                // lint-allow(no-discard-call): an out-of-order frame ends the session.
                _ = respond(writer, arena, message.id orelse 0, .{ .failed = "bad_request" });
                return .protocol_violation;
            },
        }
        const id = message.id orelse 0;
        if (id <= s.last_id) {
            // lint-allow(no-discard-call): a replayed id ends the session.
            _ = respond(writer, arena, id, .{ .failed = "replayed_id" });
            return .protocol_violation;
        }
        s.last_id = id;
        const op = message.op orelse {
            // lint-allow(no-discard-call): a request without an op ends the session.
            _ = respond(writer, arena, id, .{ .failed = "bad_request" });
            return .protocol_violation;
        };
        const reply = dispatch(&s, arena, op, message.args orelse .{});
        if (!respond(writer, arena, id, reply)) return .broker_gone;
    }
    return .protocol_violation;
}

test "path containment" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try std.testing.expect(within("/opt/com.example.hello", "/opt/com.example.hello/current"));
    try std.testing.expect(within("/opt/com.example.hello", "/opt/com.example.hello"));
    try std.testing.expect(!within("/opt/com.example.hello", "/opt/com.example.hello2/x"));
    try std.testing.expect(!within("/opt/com.example.hello", "/opt/com.example.hello/../x"));
    try std.testing.expect(!within("/opt/com.example.hello", "/opt/com.example.hello//x"));
    try std.testing.expect(!within("/opt/com.example.hello", "relative/x"));
    const policy: Policy = .{
        .install_bases = &.{"/opt"},
        .integration_dirs = &.{},
        .self_exe = "",
    };
    try std.testing.expect(managedRoot(policy, "/opt/com.example.hello"));
    try std.testing.expect(!managedRoot(policy, "/etc"));
    try std.testing.expect(!managedRoot(policy, "/opt/x/y"));
}
