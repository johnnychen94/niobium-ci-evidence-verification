//! Markdown link targets to the repository paths that must exist. Relative links name files;
//! pages of the user documentation site link to site routes (`/guides/package/`), which map to
//! content files the way Starlight builds them; links to this repository on GitHub must name a
//! file that exists on the branch being checked.

const std = @import("std");

/// Starlight content collection of apps/user-docs: route `/a/b/` is `a/b.md` or `a/b/index.md`.
pub const site_content = "apps/user-docs/src/content/docs";

/// Prefixes of links to this repository's default branch; the rest is a repository path.
pub const repo_prefixes = [_][]const u8{
    "https://github.com/niobium-project/niobium/blob/main/",
    "https://github.com/niobium-project/niobium/tree/main/",
};

pub const Target = union(enum) {
    skip,
    /// Repository path that must exist.
    file: []const u8,
    /// Route base under `site_content`; one of `routeCandidates` must exist.
    route: []const u8,
};

pub fn classify(arena: std.mem.Allocator, from: []const u8, raw: []const u8) !Target {
    std.debug.assert(from.len > 0);
    const target = if (std.mem.findScalar(u8, raw, '#')) |hash| raw[0..hash] else raw;
    for (repo_prefixes) |prefix| {
        if (std.mem.startsWith(u8, target, prefix)) {
            return .{ .file = std.mem.trimEnd(u8, target[prefix.len..], "/") };
        }
    }
    const schemes = [_][]const u8{ "http://", "https://", "mailto:", "#", "<" };
    for (schemes) |scheme| {
        if (std.mem.startsWith(u8, raw, scheme)) return .skip;
    }
    if (target.len == 0) return .skip;
    if (target[0] == '/' and std.mem.startsWith(u8, from, site_content ++ "/")) {
        const route = std.mem.trim(u8, target, "/");
        if (route.len == 0) return .{ .route = site_content };
        return .{ .route = try std.mem.concat(arena, u8, &.{ site_content, "/", route }) };
    }
    const dir = std.fs.path.dirnamePosix(from) orelse "";
    return .{ .file = try std.fs.path.resolveAllocPosix(arena, &.{ dir, target }) };
}

/// Content files that render to the route at `base`, in Starlight's lookup order.
pub fn routeCandidates(arena: std.mem.Allocator, base: []const u8) ![4][]const u8 {
    std.debug.assert(base.len > 0);
    const suffixes = [_][]const u8{ ".md", ".mdx", "/index.md", "/index.mdx" };
    var out: [suffixes.len][]const u8 = undefined; // SAFETY: every slot is written below.
    for (suffixes, &out) |suffix, *slot| slot.* = try std.mem.concat(arena, u8, &.{ base, suffix });
    return out;
}

fn expectFile(want: []const u8, from: []const u8, raw: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try classify(arena.allocator(), from, raw);
    try std.testing.expectEqualStrings(want, got.file);
}

fn expectRoute(want: []const u8, from: []const u8, raw: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try classify(arena.allocator(), from, raw);
    try std.testing.expectEqualStrings(want, got.route);
}

const page = "apps/user-docs/src/content/docs/start/index.md";

test "relative links resolve against the linking file" {
    try expectFile("docs/spec/cli-v1.md", "docs/README.md", "spec/cli-v1.md#exit-codes");
    try expectFile("README.md", "docs/adr/0001-x.md", "../../README.md");
    try expectFile("apps/user-docs/src/content/docs/a.png", page, "../a.png");
}

test "external links and pure anchors are skipped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(Target.skip, try classify(a, "README.md", "https://example.com/"));
    try std.testing.expectEqual(Target.skip, try classify(a, "README.md", "#usage"));
    try std.testing.expectEqual(Target.skip, try classify(a, page, "mailto:a@example.com"));
}

test "site pages link to routes under the content directory" {
    const docs = "apps/user-docs/src/content/docs";
    try expectRoute(docs ++ "/concepts/transactions", page, "/concepts/transactions/");
    try expectRoute(docs ++ "/reference/cli", page, "/reference/cli/#exit-codes");
    try expectRoute(docs ++ "/guides/package", page, "/guides/package");
    try expectRoute(docs, page, "/");
}

test "root-relative links outside the site stay plain files" {
    try expectFile("/guides/package", "docs/README.md", "/guides/package/");
}

test "links to this repository on GitHub must name a file on main" {
    const blob = "https://github.com/niobium-project/niobium/blob/main/";
    const tree = "https://github.com/niobium-project/niobium/tree/main/";
    try expectFile("docs/spec/cli-v1.md", page, blob ++ "docs/spec/cli-v1.md#exit-codes");
    try expectFile("examples/hello", page, tree ++ "examples/hello");
    try expectFile("examples/hello", "README.md", tree ++ "examples/hello/");
}

test "route candidates follow Starlight's file lookup" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try routeCandidates(arena.allocator(), "d/guides");
    try std.testing.expectEqualStrings("d/guides.md", got[0]);
    try std.testing.expectEqualStrings("d/guides/index.md", got[2]);
}
