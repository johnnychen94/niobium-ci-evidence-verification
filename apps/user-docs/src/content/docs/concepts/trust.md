---
title: Trust model
description: How TUF authorizes releases, and how that differs from operating-system code signing.
---

Niobium separates two questions. Is this release one the publisher authorized, current, and not older than what I already have? That is answered by TUF (The Update Framework) metadata signed with the publisher's keys. Does the operating system trust this executable's publisher? That is answered by platform signatures such as Authenticode or Apple Developer ID. The first protects the update channel; the second is what the OS shows the user.

## Release authorization with TUF

A Niobium repository holds signed metadata for five kinds of role:

| Role | Signs | Purpose |
|---|---|---|
| root | the keys and thresholds of every role | the anchor; embedded in `setup` |
| targets | every artifact and manifest: length and SHA-256 | what may be installed at all |
| channel (`stable`, `beta`, `nightly`) | which manifest each channel offers | release decisions, delegated by targets |
| snapshot | the current version of targets and every channel | a consistent view of the repository |
| timestamp | the current snapshot | freshness; expires after one day by default |

Signatures are Ed25519 over canonical JSON. When `setup` resolves a release, it:

1. starts from the trusted root embedded in it (or the newer one recorded in the installation), and follows `N+1.root.json` files one version at a time, each signed by both the old and the new root keys;
2. checks the timestamp, the snapshot, the targets and the channel metadata: signatures, thresholds, expiry, and that no version went backwards;
3. downloads the release manifest named by the channel and checks its length and hash;
4. accepts only artifacts whose digests are listed in the signed targets, and checks each download's length and hash before unpacking.

After an install, the accepted versions are written to `trust/state.json` in the install root, so a later update cannot be served older metadata. The full workflow is specified in [tuf-profile-v1](https://github.com/niobium-project/niobium/blob/main/docs/spec/tuf-profile-v1.md).

## Release sequence and version

Each release carries two numbers:

- `release_sequence`, a positive integer that must strictly increase with every release on the repository. Rollback protection is based on it.
- `version`, the application version text, which may go down.

Keeping them apart means a publisher can respond to a bad release by publishing a new release (higher sequence) that contains an older application version, without the installer mistaking it for a rollback attack.

## Platform signatures

Operating systems decide whether to warn about or block an executable based on code signing: Authenticode on Windows, Developer ID and notarization on macOS. Platform signing changes the binary bytes, so it must happen before artifacts are packed and hashed. Niobium v0.1 has no certificates wired in, and its `setup` and artifacts carry no platform signature; this is DEFERRED on [Status and platforms](/status/). The intended order is in [Sign and manage keys](/guides/sign-and-keys/#platform-code-signing).

## Where the trust root comes from

`nbpack config` reads the repository's latest root metadata and embeds it in the product configuration compiled into your branded `setup`. Whoever can replace your `setup` download can replace the trust root, so distribute `setup` itself through a channel your users already trust.
