---
title: Manifest and component schema
description: Fields of the product manifest (product.json) and component metadata (component.json).
---

Canonical sources: the [manifest-v1](https://github.com/niobium-project/niobium/blob/main/docs/spec/manifest-v1.md) and [component-v1](https://github.com/niobium-project/niobium/blob/main/docs/spec/component-v1.md) specifications and their JSON Schemas, [manifest-v1.schema.json](https://github.com/niobium-project/niobium/blob/main/api/schema/manifest-v1.schema.json) and [component-v1.schema.json](https://github.com/niobium-project/niobium/blob/main/api/schema/component-v1.schema.json). This page summarizes them.

Both documents are parsed strictly: unknown fields at any level, duplicate keys and nesting deeper than 32 are errors, and the fields `pre_install`, `post_install`, `script`, `exec`, `shell` and `command` are rejected wherever they appear.

## Product manifest

| Field | Type | Rules |
|---|---|---|
| `schema` | integer | Must be `1`; a higher value fails closed (exit code 11) |
| `min_installer` | string | Oldest `setup` version that may install this release; a newer value fails with exit code 11 |
| `product.id` | string | Reverse domain name, `[a-z0-9.-]`, 3 to 128 bytes; names the install directory |
| `product.name` | string | Display name |
| `product.publisher` | string | Display publisher |
| `product.version` | string | Application version (semver); may go down between releases |
| `product.release_sequence` | integer | At least 1; must strictly increase with every release |
| `install.default_scope` | `user` or `machine` | Must be one of `allowed_scopes` |
| `install.allowed_scopes` | array | Non-empty, unique values from `user`, `machine` |
| `components[]` | array | 1 to 64 components, at least one with `required: true` |
| `components[].id` | string | `[a-z0-9_-]`, 1 to 64 bytes, unique; `__installer_runtime` is reserved |
| `components[].title` | string | Display title |
| `components[].required` | boolean | Always installed |
| `components[].default` | boolean | Installed when the user does not choose components |
| `components[].artifacts` | object | Key `<os>-<arch>`, value `sha256:` and 64 lowercase hex digits. Empty `{}` in the template `nbpack` fills |
| `integrations.shortcuts[]` | array | `name`, `entrypoint`; at most 32 |
| `integrations.file_associations[]` | array | `extension` (`.` and 1 to 16 of `[a-z0-9]`), `entrypoint`, `description`; at most 32 |
| `integrations.services[]` | array | `id`, `entrypoint`, `start` (`auto` or `manual`); at most 32 |
| `bootstrap` | object | `entrypoint` and `protocol` (`1`) |
| `experience` | object | Only `accent` (`#RRGGBB`), `license_text`, `welcome_text`, `icon_png` (base64 PNG, at most 256 KiB) |

Platform keys are `macos-aarch64`, `macos-x86_64`, `windows-x86_64`, `windows-aarch64`, `linux-x86_64` and `linux-aarch64`. An `entrypoint` reference is `<component id>.<entrypoint name>` and must name an entrypoint declared in that component's metadata. The whole manifest is limited to 1 MiB.

## Component metadata

The `component.json` inside an artifact:

| Field | Type | Rules |
|---|---|---|
| `schema` | integer | `1` |
| `id` | string | Same as the manifest component id |
| `version` | string | Added by `nbpack component build` |
| `platform` | string | `<os>-<arch>`; added by `nbpack component build`; must match the manifest key that references the artifact |
| `entrypoints` | object | Name (`[a-z0-9_-]`, 1 to 64 bytes) to `{ "path": ..., "bootstrap": true? }` |
| `executables` | array | Paths that get the executable bit; modes in the archive are ignored |

Paths are normalized relative paths under the component's files and must exist in the payload. When you write `component.json` for `nbpack component build`, leave out `version` and `platform`.

## Product configuration

`nbpack config` writes the configuration compiled into a branded `setup`: product id, channel, repository address, trust root, default scope and branding (`product_name`, `publisher`, `accent`, `welcome_title`, `welcome_body`, `complete_body`, `license`, `logo_png`). Schema: [product-config-v1.schema.json](https://github.com/niobium-project/niobium/blob/main/api/schema/product-config-v1.schema.json).
