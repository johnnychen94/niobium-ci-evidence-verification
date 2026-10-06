# ADR-0004: Installer TUF profile v1

- **Status:** Accepted
- **Date:** 2026-10-07

## Context

Sections 12-13 of the source architecture require TUF instead of a home-made `manifest.sig`, while limiting TUF complexity and separating `release_sequence` from the application version.

## Decision

- Metadata is JSON and signatures cover canonical JSON (sorted keys, no whitespace); the signature algorithm is Ed25519, the hash is SHA-256, and thresholds are supported.
- Required roles: root, targets, snapshot, timestamp. There is exactly one level of delegation, used for the channel roles `stable`/`beta`/`nightly`.
- Root rotation is verified along the version chain N -> N+1 (both the old and the new root thresholds must be met).
- A channel target's `custom` carries `release_sequence` and `app_version`. The client records the highest `release_sequence` seen and only accepts strictly increasing values; `app_version` may go down.
- The detailed format is in [tuf-profile-v1](../spec/tuf-profile-v1.md).

## Consequences

- Channel promotion changes only signed metadata, never artifact bytes.
- Negative tests (expired, stale snapshot, wrong hash, forged channel, insufficient threshold, rollback) are a B0 gate.
