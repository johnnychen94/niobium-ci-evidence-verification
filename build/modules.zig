//! Single source of truth for the module graph and its dependency direction.
//! Pure data: imported by build.zig and by tools/check, so it must not depend on std.Build.

pub const Layer = enum(u8) {
    core = 0,
    contracts = 1,
    platform = 2,
    service = 3,
    flow = 4,
    orchestration = 5,
    ui_base = 10,
    ui_kit = 11,
    ui_screens = 12,
    ui_render = 13,
    ui_backend = 14,
    third_party = 20,
};

pub const CLibrary = enum { none, stb_truetype, zstd_compress };

pub const ModuleSpec = struct {
    name: []const u8,
    root: []const u8,
    layer: Layer,
    imports: []const []const u8,
    c_library: CLibrary = .none,
    /// Linked when the target is macOS (system frameworks referenced by `extern` declarations).
    macos_frameworks: []const []const u8 = &.{},
    /// System libraries linked per target OS (`extern "lib"` declarations).
    macos_libraries: []const []const u8 = &.{},
    windows_libraries: []const []const u8 = &.{},
    /// Generated modules have no source root in the repository.
    generated: bool = false,
};

pub const specs = [_]ModuleSpec{
    .{ .name = "core", .root = "libs/core/root.zig", .layer = .core, .imports = &.{} },
    .{
        .name = "contracts",
        .root = "libs/contracts/root.zig",
        .layer = .contracts,
        .imports = &.{"core"},
    },
    .{
        .name = "platform",
        .root = "libs/platform/root.zig",
        .layer = .platform,
        .imports = &.{ "core", "contracts" },
    },
    .{
        .name = "manifest",
        .root = "libs/manifest/root.zig",
        .layer = .service,
        .imports = &.{ "core", "contracts" },
    },
    .{
        .name = "trust",
        .root = "libs/trust/root.zig",
        .layer = .service,
        .imports = &.{ "core", "contracts" },
    },
    .{
        .name = "repository",
        .root = "libs/repository/root.zig",
        .layer = .service,
        .imports = &.{ "core", "contracts" },
    },
    .{
        .name = "package",
        .root = "libs/package/root.zig",
        .layer = .service,
        .imports = &.{ "core", "contracts", "platform" },
    },
    .{
        .name = "executor",
        .root = "libs/executor/root.zig",
        .layer = .service,
        .imports = &.{ "core", "contracts", "platform" },
    },
    .{
        .name = "resolver",
        .root = "libs/resolver/root.zig",
        .layer = .flow,
        .imports = &.{ "core", "contracts", "manifest", "trust", "repository" },
    },
    .{
        .name = "planner",
        .root = "libs/planner/root.zig",
        .layer = .flow,
        .imports = &.{ "core", "contracts", "manifest", "platform" },
    },
    .{
        .name = "privilege",
        .root = "libs/privilege/root.zig",
        .layer = .flow,
        .imports = &.{ "core", "contracts", "platform", "executor" },
        .macos_frameworks = &.{"Security"},
    },
    .{
        .name = "bootstrap",
        .root = "libs/bootstrap/root.zig",
        .layer = .flow,
        .imports = &.{ "core", "contracts", "platform" },
    },
    .{
        .name = "transaction",
        .root = "libs/transaction/root.zig",
        .layer = .flow,
        .imports = &.{ "core", "contracts", "platform", "executor", "package", "planner" },
    },
    .{
        .name = "portable",
        .root = "libs/portable/root.zig",
        .layer = .flow,
        .imports = &.{
            "core",
            "contracts",
            "platform",
            "manifest",
            "trust",
            "repository",
            "package",
            "resolver",
        },
    },
    .{
        .name = "engine",
        .root = "libs/engine/root.zig",
        .layer = .orchestration,
        .imports = &.{
            "core",
            "contracts",
            "platform",
            "manifest",
            "trust",
            "repository",
            "package",
            "executor",
            "resolver",
            "planner",
            "transaction",
            "privilege",
            "bootstrap",
            "portable",
        },
    },
    .{
        .name = "packager",
        .root = "libs/packager/root.zig",
        .layer = .orchestration,
        .imports = &.{ "core", "contracts", "manifest", "package", "trust", "zstd" },
    },
    .{
        .name = "conformance",
        .root = "libs/conformance/root.zig",
        .layer = .orchestration,
        .imports = &.{ "core", "contracts", "platform" },
    },
    .{ .name = "ui_tokens", .root = "", .layer = .ui_base, .imports = &.{}, .generated = true },
    .{
        .name = "ui_core",
        .root = "libs/ui/core/root.zig",
        .layer = .ui_base,
        .imports = &.{"ui_tokens"},
    },
    .{
        .name = "ui_kit",
        .root = "libs/ui/kit/root.zig",
        .layer = .ui_kit,
        .imports = &.{ "ui_core", "ui_tokens" },
    },
    .{
        .name = "ui_screens",
        .root = "libs/ui/screens/root.zig",
        .layer = .ui_screens,
        .imports = &.{ "ui_core", "ui_kit", "ui_tokens", "contracts", "core" },
    },
    .{
        .name = "ui_render",
        .root = "libs/ui/render/root.zig",
        .layer = .ui_render,
        .imports = &.{ "ui_core", "ui_tokens", "stb_truetype" },
    },
    .{
        .name = "ui_backend",
        .root = "libs/ui/backend/root.zig",
        .layer = .ui_backend,
        .imports = &.{ "ui_core", "ui_kit", "ui_screens", "ui_render", "ui_tokens", "contracts" },
        .macos_frameworks = &.{ "AppKit", "Foundation", "CoreGraphics" },
        .macos_libraries = &.{"objc"},
        .windows_libraries = &.{ "user32", "gdi32", "ole32", "dwmapi", "advapi32" },
    },
    .{
        .name = "stb_truetype",
        .root = "third_party/stb_truetype/bindings.zig",
        .layer = .third_party,
        .imports = &.{},
        .c_library = .stb_truetype,
    },
    .{
        .name = "zstd",
        .root = "third_party/zstd/bindings.zig",
        .layer = .third_party,
        .imports = &.{},
        .c_library = .zstd_compress,
    },
};

/// Modules allowed to spawn processes (enforced by tools/lint, rule spawn-allowlist).
pub const spawn_allowlist = [_][]const u8{
    "libs/bootstrap/",
    "libs/portable/",
    "libs/privilege/",
    "libs/platform/",
    "tools/",
    "tests/",
    "apps/",
};

/// Paths allowed to use @ptrCast/@alignCast/@intFromPtr (rule ptr-cast-allowlist).
pub const ptr_cast_allowlist = [_][]const u8{
    "libs/platform/",
    "libs/privilege/",
    "libs/engine/events.zig",
    "libs/ui/backend/",
    "libs/ui/render/",
    "apps/libdistribution/",
    "third_party/",
};

pub fn find(name: []const u8) ?ModuleSpec {
    for (specs) |spec| {
        if (eql(spec.name, name)) return spec;
    }
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}
