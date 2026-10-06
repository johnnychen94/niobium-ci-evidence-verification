//! Language rules (docs/adr/0017-chinese-user-documentation.md): text is English except
//! README.zh.md and the Simplified Chinese mirror of the user documentation site, which has a
//! page for every English page and links only within its own locale.

const std = @import("std");
const links = @import("links.zig");

pub const chinese_readme = "README.zh.md";
/// Every text file under this directory is checked for CJK text, not only Markdown.
pub const site_root = "apps/user-docs/";
/// Content directory of the `zh` locale; mirrors `links.site_content` page for page.
pub const zh_content = links.site_content ++ "/zh/";
/// Chinese UI strings, sidebar labels and version strings of the site.
pub const zh_strings = "apps/user-docs/src/content/i18n/zh-CN.json";
/// The site README, which holds the English-Chinese term table for translators.
pub const site_readme = "apps/user-docs/README.md";

/// Whether CJK text in a text file is reported: all Markdown, and every site source.
pub fn cjkChecked(path: []const u8, markdown: bool) bool {
    return markdown or std.mem.startsWith(u8, path, site_root);
}

/// The enumerated files and the one directory that may contain CJK text.
pub fn cjkAllowed(path: []const u8) bool {
    const files = [_][]const u8{ chinese_readme, zh_strings, site_readme };
    for (files) |file| {
        if (std.mem.eql(u8, path, file)) return true;
    }
    return std.mem.startsWith(u8, path, zh_content);
}

/// The other locale's page for a site page, or null for any other file.
pub fn counterpart(arena: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const en_content = links.site_content ++ "/";
    if (!std.mem.startsWith(u8, path, en_content)) return null;
    const page = std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".mdx");
    if (!page) return null;
    if (std.mem.startsWith(u8, path, zh_content)) {
        return try std.mem.concat(arena, u8, &.{ en_content, path[zh_content.len..] });
    }
    return try std.mem.concat(arena, u8, &.{ zh_content, path[en_content.len..] });
}

/// A root-relative site link that crosses from one locale to the other.
pub fn crossesLocale(from: []const u8, raw: []const u8) bool {
    if (!std.mem.startsWith(u8, from, links.site_content ++ "/")) return false;
    if (raw.len == 0 or raw[0] != '/' or std.mem.startsWith(u8, raw, "//")) return false;
    const from_zh = std.mem.startsWith(u8, from, zh_content);
    const to_zh = std.mem.eql(u8, raw, "/zh") or std.mem.startsWith(u8, raw, "/zh/") or
        std.mem.startsWith(u8, raw, "/zh#");
    return from_zh != to_zh;
}

const docs = links.site_content;

test "CJK is allowed only in the enumerated paths" {
    try std.testing.expect(cjkAllowed("README.zh.md"));
    try std.testing.expect(cjkAllowed(docs ++ "/zh/guides/package.md"));
    try std.testing.expect(cjkAllowed(docs ++ "/zh/index.md"));
    try std.testing.expect(cjkAllowed("apps/user-docs/src/content/i18n/zh-CN.json"));
    try std.testing.expect(!cjkAllowed("README.md"));
    try std.testing.expect(!cjkAllowed("docs/README.md"));
    try std.testing.expect(!cjkAllowed("docs/zh/guide.md"));
    try std.testing.expect(!cjkAllowed(docs ++ "/guides/package.md"));
    try std.testing.expect(!cjkAllowed(docs ++ "/zhx/page.md"));
    try std.testing.expect(!cjkAllowed(docs ++ "/zh.md"));
    try std.testing.expect(!cjkAllowed("apps/user-docs/astro.config.mjs"));
    try std.testing.expect(!cjkAllowed("apps/user-docs/src/content/i18n/en.json"));
    try std.testing.expect(cjkAllowed("apps/user-docs/README.md"));
    try std.testing.expect(!cjkAllowed("apps/user-docs/README.zh.md"));
    try std.testing.expect(!cjkAllowed("apps/user-docs/scripts/build-versions.mjs"));
}

test "site sources are checked for CJK, other non-Markdown files are not" {
    try std.testing.expect(cjkChecked("docs/README.md", true));
    try std.testing.expect(cjkChecked("apps/user-docs/astro.config.mjs", false));
    try std.testing.expect(cjkChecked("apps/user-docs/src/components/VersionSelect.astro", false));
    try std.testing.expect(cjkChecked("apps/user-docs/src/content/i18n/zh-CN.json", false));
    try std.testing.expect(!cjkChecked("libs/ui/core/text.zig", false));
}

fn expectCounterpart(want: ?[]const u8, path: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try counterpart(arena.allocator(), path);
    if (want) |expected| {
        try std.testing.expectEqualStrings(expected, got.?);
    } else {
        try std.testing.expectEqual(@as(?[]const u8, null), got);
    }
}

test "every site page has a counterpart at the same path in the other locale" {
    try expectCounterpart(docs ++ "/zh/guides/package.md", docs ++ "/guides/package.md");
    try expectCounterpart(docs ++ "/guides/package.md", docs ++ "/zh/guides/package.md");
    try expectCounterpart(docs ++ "/zh/index.md", docs ++ "/index.md");
    try expectCounterpart(docs ++ "/index.mdx", docs ++ "/zh/index.mdx");
    try expectCounterpart(null, "docs/README.md");
    try expectCounterpart(null, "apps/user-docs/README.md");
    try expectCounterpart(null, docs ++ "/guides/diagram.png");
}

test "site links stay within the page's locale" {
    const en = docs ++ "/guides/package.md";
    const zh = docs ++ "/zh/guides/package.md";
    try std.testing.expect(!crossesLocale(en, "/concepts/trust/"));
    try std.testing.expect(!crossesLocale(zh, "/zh/concepts/trust/#keys"));
    try std.testing.expect(!crossesLocale(zh, "/zh/"));
    try std.testing.expect(crossesLocale(zh, "/concepts/trust/"));
    try std.testing.expect(crossesLocale(zh, "/"));
    try std.testing.expect(crossesLocale(en, "/zh/concepts/trust/"));
    try std.testing.expect(!crossesLocale(en, "/zhx/"));
    try std.testing.expect(!crossesLocale(zh, "https://github.com/niobium-project/niobium"));
    try std.testing.expect(!crossesLocale(zh, "#keys"));
    try std.testing.expect(!crossesLocale("docs/README.md", "/zh/"));
}
