//! Docs lint (zig build check-docs): relative links resolve, ADR fields, acceptance IDs, spec
//! filenames carry a version, docs are English, URLs only name public allowed hosts, and every
//! build target has a tier on the Platform support page.

const std = @import("std");
const repo = @import("repo");
const links = @import("links.zig");
const locales = @import("locales.zig");
const targets = @import("targets.zig");

pub const acceptance_path = "docs/acceptance-plan-v0.1.md";

/// Public hosts the repository may reference; adding one is a reviewed change.
/// `example.com` and its subdomains are always allowed for fixtures.
pub const allowed_hosts = [_][]const u8{
    "127.0.0.1",
    "cdn.jsdelivr.net",
    "cmake.org",
    "codecov.io",
    "codeload.github.com",
    "discourse.cmake.org",
    "docs.virustotal.com",
    "github.com",
    "json-schema.org",
    "niobium-project.dev",
    "niobium.dev",
    "nsis.sourceforge.io",
    "raw.githubusercontent.com",
    "registry.npmjs.org",
    "schemas.microsoft.com",
    "sourceforge.net",
    "www.apple.com",
    "www.freedesktop.org",
};

/// Text files scanned for URL hosts.
pub const text_suffixes = [_][]const u8{
    ".md",  ".mdx", ".zig",   ".zon", ".json", ".manifest", ".h", ".c", ".gitignore", ".yml",
    ".mjs", ".ts",  ".astro",
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const files = try repo.list(arena, io);
    var report: repo.Report = .{ .arena = arena, .tool = "check-docs" };
    for (files.paths) |path| {
        const markdown = isMarkdown(path);
        if (!isText(path) and !markdown) continue;
        const bytes = try repo.read(arena, io, path);
        try checkHosts(&report, path, bytes);
        try checkLanguage(&report, io, path, bytes, markdown);
        if (!markdown) continue;
        try checkLinks(&report, io, path, bytes);
        if (isAdr(path)) try checkAdr(&report, path, bytes);
        if (std.mem.startsWith(u8, path, "docs/spec/") and !hasVersion(path)) {
            try report.add("{s}: spec filename must end with -v<N>.md", .{path});
        }
    }
    try checkAcceptance(&report, io, files);
    try checkPlatforms(&report, io);
    try report.finish(io);
}

/// English only outside `locales.cjkAllowed`; the site's two locales mirror each other.
fn checkLanguage(
    report: *repo.Report,
    io: std.Io,
    path: []const u8,
    bytes: []const u8,
    markdown: bool,
) !void {
    if (locales.cjkChecked(path, markdown) and !locales.cjkAllowed(path)) {
        if (cjkLine(bytes)) |line| try report.add("{s}:{d}: must be English (ADR-0017)", .{
            path,
            line,
        });
    }
    const other = try locales.counterpart(report.arena, path) orelse return;
    if (repo.exists(io, other)) return;
    if (std.mem.startsWith(u8, path, locales.zh_content)) {
        try report.add("{s}: Chinese page has no English page at {s}", .{ path, other });
    } else {
        try report.add("{s}: English page has no Chinese translation at {s}", .{ path, other });
    }
}

/// Every build target has a tier on the Platform support page (ADR-0014).
fn checkPlatforms(report: *repo.Report, io: std.Io) !void {
    const source = try repo.read(report.arena, io, targets.targets_path);
    const page = try repo.read(report.arena, io, targets.platforms_page);
    switch (targets.check(source, page)) {
        .ok => {},
        .no_targets => try report.add("{s}: no `.name = \"...\"` target found", .{
            targets.targets_path,
        }),
        .missing => |name| try report.add("{s}: target `{s}` from {s} has no tier", .{
            targets.platforms_page,
            name,
            targets.targets_path,
        }),
    }
}

fn isAdr(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "docs/adr/")) return false;
    const name = path["docs/adr/".len..];
    return name.len > 5 and std.ascii.isDigit(name[0]) and name[4] == '-';
}

pub fn hasVersion(path: []const u8) bool {
    const stem = path[0 .. path.len - ".md".len];
    const dash = std.mem.findScalarLast(u8, stem, '-') orelse return false;
    const tail = stem[dash + 1 ..];
    if (tail.len < 2 or tail[0] != 'v') return false;
    for (tail[1..]) |c| {
        if (!std.ascii.isDigit(c) and c != '.') return false;
    }
    return true;
}

fn checkAdr(report: *repo.Report, path: []const u8, bytes: []const u8) !void {
    const fields = [_][]const u8{ "Status", "Date" };
    for (fields) |field| {
        const marker = try report.arena.print("**{s}:**", .{field});
        if (std.mem.find(u8, bytes, marker) == null) try report.add(
            "{s}: ADR missing {s}",
            .{ path, field },
        );
    }
}

fn isText(path: []const u8) bool {
    for (text_suffixes) |suffix| {
        if (std.mem.endsWith(u8, path, suffix)) return true;
    }
    return false;
}

fn isMarkdown(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".mdx");
}

fn isLockfile(path: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basenamePosix(path), "package-lock.json");
}

fn checkHosts(report: *repo.Report, path: []const u8, bytes: []const u8) !void {
    const found = if (isLockfile(path)) forbiddenLockfileHost(bytes) else forbiddenHost(bytes);
    if (found) |host| try report.add(
        "{s}: URL host '{s}' is not in allowed_hosts",
        .{ path, host },
    );
}

/// Markdown links `](target)`, resolved by `links.classify`.
fn checkLinks(report: *repo.Report, io: std.Io, path: []const u8, bytes: []const u8) !void {
    var rest = bytes;
    while (std.mem.find(u8, rest, "](")) |start| {
        rest = rest[start + 2 ..];
        const end = std.mem.findAny(u8, rest, ") \n") orelse break;
        const target_raw = rest[0..end];
        rest = rest[end..];
        const found = switch (try links.classify(report.arena, path, target_raw)) {
            .skip => true,
            .file => |file| repo.exists(io, file),
            .route => |base| routeExists(io, try links.routeCandidates(report.arena, base)),
        };
        if (!found) try report.add("{s}: broken link '{s}'", .{ path, target_raw });
        if (locales.crossesLocale(path, target_raw)) try report.add(
            "{s}: link '{s}' leaves the page's locale",
            .{ path, target_raw },
        );
    }
}

fn routeExists(io: std.Io, candidates: [4][]const u8) bool {
    for (candidates) |candidate| {
        if (repo.exists(io, candidate)) return true;
    }
    return false;
}

pub const IdSet = std.StringArrayHashMapUnmanaged(void);

/// Collects `N1-(UJ|INV|AC)-NN` identifiers.
pub fn collectIds(arena: std.mem.Allocator, bytes: []const u8, set: *IdSet) !void {
    var index: usize = 0;
    while (std.mem.findPos(u8, bytes, index, "N1-")) |start| {
        index = start + 3;
        var end = index;
        while (end < bytes.len and std.ascii.isUpper(bytes[end])) end += 1;
        const family = bytes[index..end];
        const known = std.mem.eql(u8, family, "UJ") or std.mem.eql(
            u8,
            family,
            "INV",
        ) or std.mem.eql(u8, family, "AC");
        if (!known or end + 3 > bytes.len or bytes[end] != '-') continue;
        if (!std.ascii.isDigit(bytes[end + 1]) or !std.ascii.isDigit(bytes[end + 2])) continue;
        try set.put(arena, bytes[start .. end + 3], {});
    }
}

/// Plan rows covered by `zig test` must be cited by a test name; cited IDs must exist.
fn checkAcceptance(report: *repo.Report, io: std.Io, files: repo.Files) !void {
    const plan = try repo.read(report.arena, io, acceptance_path);
    var planned: IdSet = .empty;
    var needs_test: IdSet = .empty;
    var lines = std.mem.splitScalar(u8, plan, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "| N1-")) continue;
        try collectIds(report.arena, line[0..@min(line.len, 16)], &planned);
        if (std.mem.find(u8, line, "| zig test |") != null) {
            try collectIds(report.arena, line[0..@min(line.len, 16)], &needs_test);
        }
    }
    var cited: IdSet = .empty;
    for (files.paths) |path| {
        if (!std.mem.endsWith(u8, path, ".zig")) continue;
        const bytes = try repo.read(report.arena, io, path);
        try collectTestIds(report.arena, bytes, &cited);
    }
    for (cited.keys()) |id| {
        if (!planned.contains(id)) try report.add("test cites unknown acceptance ID {s}", .{id});
    }
    for (needs_test.keys()) |id| {
        if (!cited.contains(id)) try report.add(
            "{s}: {s} is 'zig test' but no test cites it",
            .{ acceptance_path, id },
        );
    }
}

fn collectTestIds(arena: std.mem.Allocator, bytes: []const u8, set: *IdSet) !void {
    var rest = bytes;
    while (std.mem.find(u8, rest, "test \"N1-")) |start| {
        rest = rest[start + "test \"".len ..];
        const end = std.mem.findScalar(u8, rest, '"') orelse break;
        try collectIds(arena, rest[0..end], set);
        rest = rest[end..];
    }
}

test "collectIds finds all families" {
    var set: IdSet = .empty;
    defer set.deinit(std.testing.allocator);
    try collectIds(std.testing.allocator, "N1-UJ-01 and N1-INV-08, N1-AC-21, N1-XX-01", &set);
    try std.testing.expectEqual(@as(usize, 3), set.count());
}

/// Returns the 1-based line of the first CJK code point, or of invalid UTF-8.
pub fn cjkLine(bytes: []const u8) ?usize {
    var line: usize = 1;
    var index: usize = 0;
    while (index < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return line;
        if (index + len > bytes.len) return line;
        const point = std.unicode.utf8Decode(bytes[index..][0..len]) catch return line;
        if (isCjk(point)) return line;
        if (point == '\n') line += 1;
        index += len;
    }
    return null;
}

fn isCjk(point: u21) bool {
    return (point >= 0x3000 and point <= 0x303F) or // CJK symbols and punctuation
        (point >= 0x3400 and point <= 0x9FFF) or // CJK ideographs
        (point >= 0xF900 and point <= 0xFAFF) or // compatibility ideographs
        (point >= 0xFF00 and point <= 0xFFEF) or // full-width forms
        (point >= 0x20000 and point <= 0x2FFFF); // supplementary ideographs
}

/// Returns the first URL host in `bytes` that is not on `allowed_hosts`.
pub fn forbiddenHost(bytes: []const u8) ?[]const u8 {
    var rest = bytes;
    while (std.mem.find(u8, rest, "://")) |start| {
        const scheme_ok = std.mem.endsWith(u8, rest[0..start], "http") or
            std.mem.endsWith(u8, rest[0..start], "https");
        rest = rest[start + 3 ..];
        if (!scheme_ok) continue;
        var end: usize = 0;
        while (end < rest.len and isHostByte(rest[end])) end += 1;
        // A URL that ends a sentence is followed by a period that is not part of the host.
        const host = std.mem.trimEnd(u8, rest[0..end], ".");
        // Empty hosts are scheme prefixes and format strings such as "http://{s}".
        if (host.len > 0 and !isAllowedHost(host)) return host;
    }
    return null;
}

/// npm lockfiles also carry upstream `funding` links; only `resolved` URLs say where packages
/// are downloaded from, which is where a private registry mirror would show up.
pub fn forbiddenLockfileHost(bytes: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.find(u8, line, "\"resolved\":") == null) continue;
        if (forbiddenHost(line)) |host| return host;
    }
    return null;
}

fn isHostByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '-';
}

fn isAllowedHost(host: []const u8) bool {
    if (std.mem.eql(u8, host, "example.com") or std.mem.endsWith(u8, host, ".example.com")) {
        return true;
    }
    for (allowed_hosts) |allowed| {
        if (std.mem.eql(u8, host, allowed)) return true;
    }
    return false;
}

test "cjk text is located by line" {
    try std.testing.expectEqual(@as(?usize, null), cjkLine("plain English -> ok, a <= b\n"));
    try std.testing.expectEqual(@as(?usize, 2), cjkLine("ok\n\xe4\xb8\xad\xe6\x96\x87\n"));
    try std.testing.expectEqual(@as(?usize, 1), cjkLine("full-width colon\xef\xbc\x9a"));
    try std.testing.expectEqual(@as(?usize, 3), cjkLine("a\nb\n\xff\n"));
}

test "only allowed url hosts" {
    try std.testing.expectEqual(@as(?[]const u8, null), forbiddenHost(
        "see https://github.com/niobium-project/niobium and http://127.0.0.1:8080/x",
    ));
    try std.testing.expectEqual(@as(?[]const u8, null), forbiddenHost("https://dl.example.com/a"));
    const placeholders = "\"https://\", \"http://{s}\"";
    try std.testing.expectEqual(@as(?[]const u8, null), forbiddenHost(placeholders));
    // Split so this file does not trip its own scan.
    try std.testing.expectEqualStrings("git.corp.internal", forbiddenHost(
        "clone https:" ++ "//git.corp.internal/team/repo.git",
    ).?);
    try std.testing.expectEqualStrings("mirror.example.net", forbiddenHost(
        "[m](http:" ++ "//mirror.example.net/)",
    ).?);
}

test {
    _ = links;
    _ = locales;
    _ = targets;
}

test "the user documentation site host is allowed" {
    try std.testing.expectEqual(@as(?[]const u8, null), forbiddenHost(
        "site: 'https://niobium-project.dev', see https://niobium-project.dev/start/",
    ));
}

test "a sentence-ending period is not part of the host" {
    try std.testing.expectEqual(@as(?[]const u8, null), forbiddenHost(
        "It is published at https://niobium-project.dev. Maintainer docs stay here.",
    ));
    // Split so this file does not trip its own scan.
    try std.testing.expectEqualStrings("git.corp.internal", forbiddenHost(
        "the mirror is https:" ++ "//git.corp.internal.",
    ).?);
}

test "npm lockfiles are checked by resolved URLs only" {
    // Split so this file does not trip its own scan.
    const lock = "\"node_modules/a\": {\n" ++
        "  \"resolved\": \"https://registry.npmjs.org/a/-/a-1.0.0.tgz\",\n" ++
        "  \"funding\": { \"url\": \"https:" ++ "//opencollective.com/a\" }\n";
    try std.testing.expectEqual(@as(?[]const u8, null), forbiddenLockfileHost(lock));
    const mirror = "  \"resolved\": \"https:" ++ "//npm.corp.internal/a/-/a-1.0.0.tgz\",\n";
    try std.testing.expectEqualStrings("npm.corp.internal", forbiddenLockfileHost(mirror).?);
    try std.testing.expect(isLockfile("apps/user-docs/package-lock.json"));
    try std.testing.expect(!isLockfile("apps/user-docs/package.json"));
}

test "site sources and workflows are scanned, mdx is markdown" {
    try std.testing.expect(isText(".github/workflows/user-docs.yml"));
    try std.testing.expect(isText("apps/user-docs/astro.config.mjs"));
    try std.testing.expect(isText("apps/user-docs/src/components/VersionSelect.astro"));
    try std.testing.expect(isText("apps/user-docs/src/content.config.ts"));
    try std.testing.expect(isMarkdown("apps/user-docs/src/content/docs/index.mdx"));
    try std.testing.expect(!isMarkdown("apps/user-docs/package.json"));
}

test "spec filenames need a version" {
    try std.testing.expect(hasVersion("docs/spec/manifest-v1.md"));
    try std.testing.expect(!hasVersion("docs/spec/manifest.md"));
}
