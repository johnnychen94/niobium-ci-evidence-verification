//! What a product's setup ships with: the product config compiled into it
//! (`-Dproduct-config`, docs/spec/cli-v1.md) and the offline bundle directory
//! (docs/runbooks/offline-bundle.md).

const std = @import("std");
const contracts = @import("contracts");

const installation = contracts.installation;
const Dir = std.Io.Dir;

pub const ConfigInput = struct {
    product_id: []const u8,
    /// Newest `<N>.root.json` of the repository.
    root_bytes: []const u8,
    /// URL or directory; null when setup only ships offline (a sibling `repository/`).
    repository: ?[]const u8 = null,
    channel: contracts.Channel = .stable,
    default_scope: ?contracts.Scope = null,
    /// `branding.json`: contracts.installation.Branding without the logo.
    branding_json: ?[]const u8 = null,
    logo_png: ?[]const u8 = null,
};

pub fn config(arena: std.mem.Allocator, in: ConfigInput) ![]const u8 {
    var branding: installation.Branding = .{};
    if (in.branding_json) |text| {
        branding = try contracts.json.decode(installation.Branding, arena, text, .{
            .max_bytes = 1 << 20,
        });
    }
    if (in.logo_png) |png| {
        if (png.len > installation.max_logo_bytes) return error.PackLogoTooLarge;
        const encoder = std.base64.standard.Encoder;
        const out = try arena.alloc(u8, encoder.calcSize(png.len));
        branding.logo_png = encoder.encode(out, png);
    }
    const value: installation.ProductConfig = .{
        .schema = 1,
        .mode = .branded,
        .product_id = in.product_id,
        .channel = in.channel,
        .repository = in.repository,
        .trust_root = in.root_bytes,
        .default_scope = in.default_scope,
        .branding = branding,
    };
    const bytes = try std.json.Stringify.valueAlloc(arena, value, .{
        .emit_null_optional_fields = false,
    });
    const decoded = try installation.decodeProductConfig(arena, bytes);
    std.debug.assert(decoded.mode == .branded);
    return bytes;
}

/// `<out>/<setup name>` and `<out>/repository/` (a copy of `repo`). `out` must be empty.
pub fn bundle(
    io: std.Io,
    arena: std.mem.Allocator,
    repo: Dir,
    setup_dir: Dir,
    setup_name: []const u8,
    out: Dir,
) !void {
    var existing = out.iterate();
    if (try existing.next(io) != null) return error.PackBundleNotEmpty;
    try Dir.copyFile(setup_dir, setup_name, out, setup_name, io, .{});
    try out.createDirPath(io, "repository");
    var walker = try repo.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const target = try std.fs.path.join(arena, &.{ "repository", entry.path });
        switch (entry.kind) {
            .directory => try out.createDirPath(io, target),
            .file => {
                if (std.mem.endsWith(u8, entry.path, ".tmp")) continue;
                try Dir.copyFile(repo, entry.path, out, target, io, .{});
            },
            else => return error.PackUnsupportedEntry,
        }
    }
}
