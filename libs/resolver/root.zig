//! Resolve channel -> release -> manifest -> component artifacts (docs/spec/tuf-profile-v1.md
//! #client-workflow, steps 1-6). Everything returned here is authorized by verified TUF metadata;
//! nothing is downloaded beyond metadata and the manifest.

const std = @import("std");
const contracts = @import("contracts");
const manifest = @import("manifest");
const trust = @import("trust");

pub const Error = trust.client.Error || manifest.Error || error{
    ResolveProductMismatch,
    ResolveUnknownComponent,
    ResolveScopeNotAllowed,
    PlatformUnsupported,
};

/// How the offered release relates to the installed one.
pub const Relation = enum { fresh, newer, same };

pub const Request = struct {
    product_id: []const u8,
    /// Trusted root envelope bytes (embedded, or `trust/root.json` from the installation).
    root_bytes: []const u8,
    channel: contracts.Channel = .stable,
    platform: contracts.Platform,
    installer_version: []const u8,
    now: i64,
    /// Trust versions persisted by the previous refresh.
    trusted: ?contracts.installation.TrustState = null,
    /// `release_sequence` of the installed release; offering an older one is rejected.
    installed_sequence: ?u64 = null,
    scope: ?contracts.Scope = null,
    /// Optional component ids to add to the required ones; null selects the defaults.
    components: ?[]const []const u8 = null,
    limits: contracts.Limits = .{},
};

pub const Artifact = struct {
    component: []const u8,
    digest: contracts.Digest,
    length: u64,
};

pub const Resolution = struct {
    verified: trust.client.Verified,
    trust_state: contracts.installation.TrustState,
    manifest: manifest.Manifest,
    manifest_bytes: []const u8,
    manifest_sha256: [64]u8,
    relation: Relation,
    scope: contracts.Scope,
    artifacts: []const Artifact,
};

pub fn resolve(arena: std.mem.Allocator, source: anytype, request: Request) Error!Resolution {
    const verified = try trust.client.refresh(arena, source, request.root_bytes, .{
        .now = request.now,
        .channel = request.channel,
        .trusted = request.trusted,
        .limits = request.limits,
    });
    const target = try verified.manifestTarget(arena, request.product_id);
    if (request.installed_sequence) |installed| {
        if (target.release_sequence < installed) return error.ReleaseSequenceRegression;
    }
    const bytes = try trust.client.fetchTarget(arena, source, target.digest, target.length);
    const m = try manifest.parse(arena, bytes, request.installer_version, request.limits);
    if (!std.mem.eql(u8, m.product.id, request.product_id)) return error.ResolveProductMismatch;
    if (m.product.release_sequence != target.release_sequence) {
        return error.TrustReleaseSequenceMismatch;
    }
    const scope = try pickScope(m, request.scope);
    const artifacts = try pickArtifacts(arena, verified, m, request);
    return .{
        .verified = verified,
        .trust_state = verified.state(target.release_sequence),
        .manifest = m,
        .manifest_bytes = bytes,
        .manifest_sha256 = contracts.ids.hexDigest(target.digest),
        .relation = relation(target.release_sequence, request.installed_sequence),
        .scope = scope,
        .artifacts = artifacts,
    };
}

fn relation(offered: u64, installed: ?u64) Relation {
    const current = installed orelse return .fresh;
    return if (offered > current) .newer else .same;
}

pub fn pickScope(m: manifest.Manifest, requested: ?contracts.Scope) Error!contracts.Scope {
    const scope = requested orelse m.install.default_scope;
    for (m.install.allowed_scopes) |allowed| {
        if (allowed == scope) return scope;
    }
    return error.ResolveScopeNotAllowed;
}

fn findComponent(m: manifest.Manifest, id: []const u8) ?contracts.manifest.Component {
    for (m.components) |component| {
        if (std.mem.eql(u8, component.id, id)) return component;
    }
    return null;
}

fn isRequested(list: ?[]const []const u8, id: []const u8) bool {
    const ids = list orelse return false;
    for (ids) |item| {
        if (std.mem.eql(u8, item, id)) return true;
    }
    return false;
}

/// Required components always; then the explicit list, or `default` ones when there is none.
/// Optional default components that do not ship for the platform are skipped silently.
pub fn pickArtifacts(
    arena: std.mem.Allocator,
    verified: trust.client.Verified,
    m: manifest.Manifest,
    request: Request,
) Error![]const Artifact {
    if (request.components) |list| {
        for (list) |id| {
            if (findComponent(m, id) == null) return error.ResolveUnknownComponent;
        }
    }
    var out: std.ArrayList(Artifact) = .empty;
    for (m.components) |component| {
        const explicit = isRequested(request.components, component.id);
        const wanted = component.required or explicit or
            (request.components == null and component.default);
        if (!wanted) continue;
        const digest = manifest.artifactFor(component, request.platform) orelse {
            if (component.required or explicit) return error.PlatformUnsupported;
            continue;
        };
        const length = try verified.authorizeArtifact(digest);
        try out.append(arena, .{ .component = component.id, .digest = digest, .length = length });
    }
    return out.items;
}

test {
    _ = @import("resolver_test.zig");
}
