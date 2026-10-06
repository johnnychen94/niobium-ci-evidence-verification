//! Semantic rules of manifest-v1 and component-v1 on top of the strict wire decode.

const std = @import("std");
const contracts = @import("contracts");

const ids = contracts.ids;
const wire = contracts.manifest;

pub const Error = contracts.json.DecodeError || error{
    InstallerTooOld,
    ManifestInvalidVersion,
    ManifestInvalidProductId,
    ManifestInvalidReleaseSequence,
    ManifestInvalidScope,
    ManifestInvalidComponent,
    ManifestDuplicateComponent,
    ManifestReservedComponent,
    ManifestNoRequiredComponent,
    ManifestInvalidArtifact,
    ManifestInvalidEntrypoint,
    ManifestTooManyItems,
    ManifestInvalidIntegration,
    ManifestInvalidExperience,
    ManifestInvalidBootstrap,
    ComponentInvalidMetadata,
    ComponentInvalidPath,
    ComponentPlatformMismatch,
    ComponentMissingEntrypoint,
};

pub fn manifestRules(
    m: wire.Manifest,
    installer_version: []const u8,
    limits: contracts.Limits,
) Error!void {
    const installer = ids.parseSemver(installer_version) orelse return error.ManifestInvalidVersion;
    const minimum = ids.parseSemver(m.min_installer) orelse return error.ManifestInvalidVersion;
    if (minimum.order(installer) == .gt) return error.InstallerTooOld;
    try productRules(m.product);
    try scopes(m.install);
    try components(m.components, limits);
    try integrations(m, limits);
    if (m.bootstrap) |b| {
        if (b.protocol != contracts.bootstrap.protocol) return error.ManifestInvalidBootstrap;
        try entrypointRef(m, b.entrypoint);
    }
    try experience(m.experience, limits);
}

fn productRules(p: wire.Product) Error!void {
    if (!ids.isProductId(p.id)) return error.ManifestInvalidProductId;
    if (p.release_sequence == 0) return error.ManifestInvalidReleaseSequence;
    if (ids.parseSemver(p.version) == null) return error.ManifestInvalidVersion;
    if (p.name.len == 0 or p.name.len > 128) return error.ManifestInvalidProductId;
    if (p.publisher.len > 128) return error.ManifestInvalidProductId;
}

fn scopes(install: wire.Install) Error!void {
    if (install.allowed_scopes.len == 0 or install.allowed_scopes.len > 2) {
        return error.ManifestInvalidScope;
    }
    const allowed = install.allowed_scopes;
    if (allowed.len == 2 and allowed[0] == allowed[1]) {
        return error.ManifestInvalidScope;
    }
    for (install.allowed_scopes) |scope| {
        if (scope == install.default_scope) return;
    }
    return error.ManifestInvalidScope;
}

fn components(list: []const wire.Component, limits: contracts.Limits) Error!void {
    if (list.len == 0 or list.len > limits.components) return error.ManifestTooManyItems;
    var required = false;
    for (list, 0..) |component, index| {
        if (std.mem.eql(
            u8,
            component.id,
            ids.reserved_component,
        )) return error.ManifestReservedComponent;
        if (!ids.isComponentId(component.id)) return error.ManifestInvalidComponent;
        if (component.title.len == 0 or component.title.len > 128) {
            return error.ManifestInvalidComponent;
        }
        for (list[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.id, component.id)) return error.ManifestDuplicateComponent;
        }
        if (component.artifacts.map.count() == 0) return error.ManifestInvalidArtifact;
        var it = component.artifacts.map.iterator();
        while (it.next()) |entry| {
            if (std.meta.stringToEnum(
                ids.Platform,
                entry.key_ptr.*,
            ) == null) return error.ManifestInvalidArtifact;
            if (ids.parseDigest(entry.value_ptr.*) == null) return error.ManifestInvalidArtifact;
        }
        required = required or component.required;
    }
    if (!required) return error.ManifestNoRequiredComponent;
}

fn entrypointRef(m: wire.Manifest, text: []const u8) Error!void {
    const ref = ids.parseEntrypointRef(text) orelse return error.ManifestInvalidEntrypoint;
    for (m.components) |component| {
        if (std.mem.eql(u8, component.id, ref.component)) return;
    }
    return error.ManifestInvalidEntrypoint;
}

fn integrations(m: wire.Manifest, limits: contracts.Limits) Error!void {
    const i = m.integrations;
    const max = limits.integrations_per_kind;
    if (i.shortcuts.len > max or i.file_associations.len > max or i.services.len > max) {
        return error.ManifestTooManyItems;
    }
    for (i.shortcuts) |shortcut| {
        try label(shortcut.name);
        try entrypointRef(m, shortcut.entrypoint);
    }
    for (i.file_associations) |association| {
        const ext = association.extension;
        if (ext.len < 2 or ext.len > 17 or ext[0] != '.') return error.ManifestInvalidIntegration;
        for (ext[1..]) |char| {
            if (!std.ascii.isLower(
                char,
            ) and !std.ascii.isDigit(char)) return error.ManifestInvalidIntegration;
        }
        try label(association.description);
        try entrypointRef(m, association.entrypoint);
    }
    for (i.services) |service| {
        if (!ids.isComponentId(service.id)) return error.ManifestInvalidIntegration;
        try entrypointRef(m, service.entrypoint);
    }
}

/// Display names become file names (shortcut, .desktop): printable, no path separators.
fn label(text: []const u8) Error!void {
    if (text.len == 0 or text.len > 64) return error.ManifestInvalidIntegration;
    const unsafe = "/\\:*?\"<>|\x00";
    if (std.mem.findAny(u8, text, unsafe) != null) return error.ManifestInvalidIntegration;
    if (text[0] == '.' or text[0] == ' ') return error.ManifestInvalidIntegration;
}

fn experience(e: wire.Experience, limits: contracts.Limits) Error!void {
    if (e.accent) |accent| {
        if (ids.parseColor(accent) == null) return error.ManifestInvalidExperience;
    }
    if (e.icon_png) |icon| {
        if (icon.len > limits.icon_png_bytes / 3 * 4 + 4) return error.ManifestInvalidExperience;
    }
}

pub fn componentMeta(
    meta: wire.ComponentMeta,
    expected: ?ids.Platform,
    limits: contracts.Limits,
) Error!void {
    if (!ids.isComponentId(meta.id)) return error.ComponentInvalidMetadata;
    if (ids.parseSemver(meta.version) == null) return error.ComponentInvalidMetadata;
    if (expected) |platform| {
        if (platform != meta.platform) return error.ComponentPlatformMismatch;
    }
    var it = meta.entrypoints.map.iterator();
    while (it.next()) |entry| {
        if (!ids.isComponentId(entry.key_ptr.*)) return error.ComponentInvalidMetadata;
        ids.checkRelativePath(
            entry.value_ptr.path,
            limits.path_bytes,
        ) catch return error.ComponentInvalidPath;
    }
    for (meta.executables) |path| {
        ids.checkRelativePath(path, limits.path_bytes) catch return error.ComponentInvalidPath;
    }
}

/// Cross-check manifest entrypoint references against the component metadata of the release.
pub fn entrypoints(m: wire.Manifest, metas: []const wire.ComponentMeta) Error!void {
    for (m.integrations.shortcuts) |s| try checkEntrypoint(metas, s.entrypoint);
    for (m.integrations.file_associations) |a| try checkEntrypoint(metas, a.entrypoint);
    for (m.integrations.services) |s| try checkEntrypoint(metas, s.entrypoint);
    if (m.bootstrap) |b| {
        const entry = try resolveEntrypoint(metas, b.entrypoint);
        if (!entry.bootstrap) return error.ManifestInvalidBootstrap;
    }
}

fn checkEntrypoint(metas: []const wire.ComponentMeta, text: []const u8) Error!void {
    const entry = try resolveEntrypoint(metas, text);
    if (entry.path.len == 0) return error.ComponentInvalidPath;
}

pub fn resolveEntrypoint(
    metas: []const wire.ComponentMeta,
    text: []const u8,
) Error!wire.Entrypoint {
    const ref = ids.parseEntrypointRef(text) orelse return error.ManifestInvalidEntrypoint;
    for (metas) |meta| {
        if (!std.mem.eql(u8, meta.id, ref.component)) continue;
        return meta.entrypoints.map.get(ref.name) orelse error.ComponentMissingEntrypoint;
    }
    return error.ComponentMissingEntrypoint;
}
