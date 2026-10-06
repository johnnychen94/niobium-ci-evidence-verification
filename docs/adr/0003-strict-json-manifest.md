# ADR-0003: Strict JSON product manifest

- **Status:** Accepted
- **Date:** 2026-10-07

## Context

The source architecture examples use YAML, but Zig std has no YAML parser, and a home-grown YAML parser would widen the attack surface.

## Decision

- The product manifest and component metadata are JSON, schema version 1; see [manifest-v1](../spec/manifest-v1.md).
- Parsing fails closed: unknown fields, duplicate keys, invalid UTF-8 and input over `contracts.Limits` are all errors.
- The forbidden fields `pre_install`, `post_install`, `script`, `exec`, `shell` and `command` get a dedicated error at any nesting level instead of the generic unknown-field error.
- A `schema` newer than this installer supports fails closed with a hint to upgrade the framework runtime first.

## Consequences

- Product packagers write manifests in JSON; `nbpack product validate` reports located errors.
