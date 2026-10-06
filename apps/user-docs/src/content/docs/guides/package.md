---
title: Package your product
description: Write component metadata and the product manifest, declare integrations, and build component artifacts.
---

This guide turns the files your build produces into Niobium component artifacts and a product manifest template. It assumes a product repository that depends on Niobium as in the [tutorial](/start/).

## Describe each component

Split your product into components: units a user can install or leave out, such as a runtime, a command-line tool or documentation. At least one must be required. For each, write a `component.json`:

```json
{
  "schema": 1,
  "id": "runtime",
  "entrypoints": {
    "main": { "path": "bin/hello", "bootstrap": true },
    "agent": { "path": "bin/hello-agent" }
  },
  "executables": ["bin/hello", "bin/hello-agent"]
}
```

- `id` uses `[a-z0-9_-]`, at most 64 bytes, and must match the component id in the manifest.
- Paths are relative to the component's files and must exist in them.
- Only files in `executables` get the executable bit.
- Mark an entrypoint `"bootstrap": true` if it implements [App Bootstrap](/guides/app-bootstrap/).
- Do not write `version` or `platform`: the artifact build adds both.

When a path differs per platform, such as `bin/hello.exe` on Windows, keep one `component.json` per variant and pick it by target in `build.zig`, as `examples/hello` does with `component.windows.json`.

## Write the product manifest template

`product.json` is the release manifest with every component's `artifacts` left empty; `nbpack` fills in the digests when it publishes:

```json
{
  "schema": 1,
  "min_installer": "0.1.0",
  "product": {
    "id": "com.example.hello",
    "name": "Hello",
    "publisher": "Example Inc.",
    "version": "1.0.0",
    "release_sequence": 1
  },
  "install": { "default_scope": "user", "allowed_scopes": ["user", "machine"] },
  "components": [
    { "id": "runtime", "title": "Hello Runtime", "required": true, "default": true, "artifacts": {} }
  ],
  "bootstrap": { "entrypoint": "runtime.main", "protocol": 1 }
}
```

`product.id` is a reverse domain name in `[a-z0-9.-]`; it names the install directory and cannot change later without becoming a different product. Every field is listed in the [manifest reference](/reference/manifest/).

## Declare integrations

Integrations point at an entrypoint as `<component>.<entrypoint>`. Add the ones you need under `integrations`:

```json
"integrations": {
  "shortcuts": [{ "name": "Hello", "entrypoint": "runtime.main" }],
  "file_associations": [
    { "extension": ".hello", "entrypoint": "runtime.main", "description": "Hello Document" }
  ],
  "services": [{ "id": "hello-agent", "entrypoint": "runtime.agent", "start": "manual" }]
}
```

What each becomes depends on the platform and scope:

| Integration | macOS | Windows | Linux |
|---|---|---|---|
| Shortcut | link in `~/Applications` (user) or `/Applications` (machine) | Start Menu `.lnk` | `.desktop` file |
| File association | not registered at install time: declare it in your app bundle | `Classes` registry keys | `mimeapps.list` and `.desktop` MIME type |
| Service, machine scope | launchd daemon | Service Control Manager | systemd unit |
| Service, user scope | launchd agent | not available | systemd user unit |

In v0.1 the planner leaves out integrations that a platform and scope cannot provide (the two "not" cells above), and the install succeeds without them. Application registration is not declared: on Windows the framework writes the Uninstall registry entry itself. Each integration kind allows at most 32 entries.

## Build the artifacts

Inside `build.zig`, build one artifact per component and target:

```zig
const runtime = niobium.addComponent(b, target, .{
    .id = "runtime",
    .metadata = b.path("components/runtime/component.json"),
    .files = runtime_files.getDirectory(),
    .version = version,
});
```

`files` is the directory tree to install under the component root; it may contain only regular files and directories. Outside a build, the same is done with `nbpack component build`:

```sh
nbpack component build --source components/runtime/component.json --files payload/ \
  --version 1.2.0 --platform macos-aarch64 --out runtime-macos-aarch64.tar.zst
```

Before writing the file, `nbpack` runs the result through the same strict extractor the installer uses. To recheck an existing artifact: `nbpack component validate runtime-macos-aarch64.tar.zst`.

A release needs at least one artifact for every component in the manifest, and at most one per platform. If you sign your binaries with an OS code-signing certificate, do it before this step ([Sign and manage keys](/guides/sign-and-keys/#platform-code-signing)).

## Brand the installer window

`branding.json` sets the text and color of the graphical installer: `product_name`, `publisher`, `accent` (`#RRGGBB`), `welcome_title`, `welcome_body`, `complete_body` and `license`, all plain text. Pass a PNG logo with `nbpack config --logo`. If the accent cannot reach a 4.5:1 contrast ratio in both light and dark themes, the window refuses to start; the command line ignores branding.

Next: [Sign and manage keys](/guides/sign-and-keys/).
