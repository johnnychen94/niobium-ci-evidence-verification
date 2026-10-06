//! Broker side of IPC v1: a `platform.Platform` whose mutations run in the privileged helper.
//! The executor and transaction cannot tell it from the host backend. If the helper dies, every
//! call returns error.PrivilegeHelperLost; the transaction stops and recovery runs later with a
//! fresh helper (docs/architecture/transaction-model.md).

const std = @import("std");
const contracts = @import("contracts");
const platform_mod = @import("platform");

const ipc = contracts.ipc;
const platform_api = platform_mod.api;
const Error = platform_mod.Error;
const Allocator = std.mem.Allocator;

pub const Session = struct {
    /// `tx-<seq>-<hex>`; also part of the Windows pipe name.
    tx: []const u8,
    /// 32 lowercase hex characters from the OS CSPRNG.
    nonce: []const u8,

    pub const nonce_len = 32;

    pub fn generate(io: std.Io, buffer: *[nonce_len]u8) []const u8 {
        var raw: [nonce_len / 2]u8 = undefined; // SAFETY: filled by random.
        io.random(&raw);
        const hex = std.fmt.bytesToHex(raw, .lower);
        buffer.* = hex;
        return buffer;
    }
};

pub const Broker = struct {
    gpa: Allocator,
    io: std.Io,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    session: Session,
    next_id: u64 = 1,
    lost: bool = false,
    scratch: std.heap.ArenaAllocator,

    pub fn init(
        gpa: Allocator,
        io: std.Io,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        session: Session,
    ) Broker {
        return .{
            .gpa = gpa,
            .io = io,
            .reader = reader,
            .writer = writer,
            .session = session,
            .scratch = .init(gpa),
        };
    }

    pub fn deinit(b: *Broker) void {
        b.scratch.deinit();
    }

    pub fn platform(b: *Broker) platform_api.Platform {
        return .{ .ptr = b, .vtable = &vtable };
    }

    fn exchange(b: *Broker, message: ipc.Message) Error!ipc.Message {
        if (b.lost) return error.PrivilegeHelperLost;
        const arena = b.scratch.allocator();
        const payload = try ipc.encode(arena, message);
        ipc.writeFrame(b.writer, payload) catch |err| switch (err) {
            error.IpcFrameTooLarge => return error.FsIo,
            else => return b.lose(),
        };
        const bytes = ipc.readFrame(arena, b.reader) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return b.lose(),
        };
        const reply = ipc.decode(arena, bytes) catch return b.lose();
        if (reply.type != .response) return b.lose();
        if (reply.ok orelse false) return reply;
        return failure(reply.@"error" orelse "");
    }

    fn release(b: *Broker) void {
        // lint-allow(no-discard-call): reset reports whether capacity was kept; either is fine.
        _ = b.scratch.reset(.retain_capacity);
    }

    fn lose(b: *Broker) Error {
        b.lost = true;
        return error.PrivilegeHelperLost;
    }

    /// Helper errors arrive by name; protocol violations mean the session is unusable.
    fn failure(name: []const u8) Error {
        inline for (@typeInfo(Error).error_set.error_names.?) |known| {
            if (std.mem.eql(u8, name, known)) return @field(Error, known);
        }
        if (std.mem.eql(u8, name, "path_outside_managed_root")) return error.FsAccessDenied;
        if (std.mem.eql(u8, name, "scope_not_machine")) return error.CapabilityUnsupported;
        return error.PrivilegeHelperLost;
    }

    /// Handshake: declares the roots this transaction may mutate and read from.
    pub fn hello(
        b: *Broker,
        managed_roots: []const []const u8,
        source_roots: []const []const u8,
    ) Error!void {
        defer b.release();
        const reply = try b.exchange(.{
            .v = ipc.version,
            .type = .hello,
            .tx = b.session.tx,
            .nonce = b.session.nonce,
            .managed_roots = managed_roots,
            .source_roots = source_roots,
        });
        std.debug.assert(reply.ok.?);
    }

    /// Ends the session; the helper exits after answering.
    pub fn bye(b: *Broker) Error!void {
        defer b.release();
        const id = b.next_id;
        b.next_id += 1;
        const reply = try b.exchange(.{
            .v = ipc.version,
            .type = .bye,
            .tx = b.session.tx,
            .nonce = b.session.nonce,
            .id = id,
        });
        std.debug.assert(reply.ok.?);
    }

    fn call(b: *Broker, op: ipc.Op, args: ipc.Args) Error!ipc.Message {
        const id = b.next_id;
        b.next_id += 1;
        return b.exchange(.{
            .v = ipc.version,
            .type = .request,
            .tx = b.session.tx,
            .nonce = b.session.nonce,
            .id = id,
            .op = op,
            .args = args,
        });
    }

    fn simple(b: *Broker, op: ipc.Op, args: ipc.Args) Error!void {
        defer b.release();
        const reply = try b.call(op, args);
        std.debug.assert(reply.ok.?);
    }

    fn encodeBytes(b: *Broker, bytes: []const u8) Error![]const u8 {
        const encoder = std.base64.standard.Encoder;
        const out = try b.scratch.allocator().alloc(u8, encoder.calcSize(bytes.len));
        return encoder.encode(out, bytes);
    }

    const vtable: platform_api.VTable = .{
        .createDirPath = createDirPath,
        .writeFile = writeFile,
        .appendFile = appendFile,
        .copyFile = copyFile,
        .rename = rename,
        .deleteFile = deleteFile,
        .deleteTree = deleteTree,
        .setPointer = setPointer,
        .deletePointer = deletePointer,
        .prepareIntegration = prepareIntegration,
        .discardIntegration = discardIntegration,
        .activateIntegration = activateIntegration,
        .removeIntegration = removeIntegration,
        .freeSpace = freeSpace,
        .now = now,
    };

    fn self(ptr: *anyopaque) *Broker {
        return @ptrCast(@alignCast(ptr));
    }

    fn createDirPath(ptr: *anyopaque, path: []const u8) Error!void {
        return self(ptr).simple(.create_directory, .{ .path = path });
    }

    fn writeFile(
        ptr: *anyopaque,
        path: []const u8,
        bytes: []const u8,
        executable: bool,
    ) Error!void {
        const b = self(ptr);
        const contents = try b.encodeBytes(bytes);
        return b.simple(
            .write_file,
            .{ .path = path, .contents = contents, .executable = executable },
        );
    }

    fn appendFile(ptr: *anyopaque, path: []const u8, bytes: []const u8) Error!void {
        const b = self(ptr);
        return b.simple(.append_file, .{ .path = path, .contents = try b.encodeBytes(bytes) });
    }

    fn copyFile(
        ptr: *anyopaque,
        source: []const u8,
        target: []const u8,
        executable: bool,
    ) Error!void {
        return self(ptr).simple(
            .copy_file,
            .{ .source = source, .target = target, .executable = executable },
        );
    }

    fn rename(ptr: *anyopaque, from: []const u8, to: []const u8) Error!void {
        return self(ptr).simple(.rename, .{ .source = from, .target = to });
    }

    fn deleteFile(ptr: *anyopaque, path: []const u8) Error!void {
        return self(ptr).simple(.remove_file, .{ .path = path });
    }

    fn deleteTree(ptr: *anyopaque, path: []const u8) Error!void {
        return self(ptr).simple(.remove_tree, .{ .path = path });
    }

    fn setPointer(ptr: *anyopaque, link: []const u8, target: []const u8) Error!void {
        return self(ptr).simple(.set_pointer, .{ .path = link, .target = target });
    }

    fn deletePointer(ptr: *anyopaque, link: []const u8) Error!void {
        return self(ptr).simple(.remove_pointer, .{ .path = link });
    }

    fn integrationArgs(request: *const platform_api.IntegrationRequest) ipc.Args {
        return .{ .integration = .{
            .integration = request.integration,
            .product_id = request.product_id,
            .product_name = request.product_name,
            .scope = request.scope,
            .root = request.root,
            .tx = request.tx,
        } };
    }

    fn prepareIntegration(
        ptr: *anyopaque,
        request: *const platform_api.IntegrationRequest,
    ) Error!void {
        return self(ptr).simple(.prepare_integration, integrationArgs(request));
    }

    fn discardIntegration(
        ptr: *anyopaque,
        request: *const platform_api.IntegrationRequest,
    ) Error!void {
        return self(ptr).simple(.discard_integration, integrationArgs(request));
    }

    fn activateIntegration(
        ptr: *anyopaque,
        arena: Allocator,
        request: *const platform_api.IntegrationRequest,
    ) Error![]const u8 {
        const b = self(ptr);
        defer b.release();
        const reply = try b.call(.activate_integration, integrationArgs(request));
        const location = reply.location orelse return b.lose();
        return arena.dupe(u8, location);
    }

    fn removeIntegration(
        ptr: *anyopaque,
        installed: contracts.installation.Integration,
    ) Error!void {
        return self(ptr).simple(.remove_integration, .{ .installed = installed });
    }

    fn freeSpace(ptr: *anyopaque, path: []const u8) Error!u64 {
        const b = self(ptr);
        defer b.release();
        const reply = try b.call(.free_space, .{ .path = path });
        return reply.free_bytes orelse b.lose();
    }

    fn now(ptr: *anyopaque) i64 {
        return std.Io.Clock.real.now(self(ptr).io).toSeconds();
    }
};
