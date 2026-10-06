---
title: Security
description: What Niobium defends against, what it does not, and how to report a vulnerability.
---

Niobium is designed so that a compromised download server, a tampered or replayed repository, a malicious archive or a crash cannot get software installed that the publisher did not authorize, or leave a machine half-updated. It does not protect against a compromised publisher, a compromised user session, or a malicious application that the publisher legitimately signed. Each defense below names where it is specified; whether it has been verified is on [Status and platforms](/status/).

## Threat model

Assumed attackers:

- someone who controls the network path or the server hosting the repository, or a mirror of it;
- someone who can hand the user a crafted repository, artifact or offline bundle;
- the environment itself: power loss, kills, full disks and locked files during a transaction.

Assumed trusted:

- the publisher's signing keys and the machine they sign on;
- the `setup` executable the user starts, including the trust root compiled into it;
- the operating system and the administrator account.

## Non-goals

- **A malicious or compromised publisher.** Whatever the keys sign is installed. Keep the keys offline ([Sign and manage keys](/guides/sign-and-keys/)).
- **Malicious application code.** Niobium verifies that bytes are the ones the publisher released, not that they are safe to run.
- **An attacker who already controls the installing user's account.** See the residual risk of the [privilege boundary](/concepts/privilege/#what-the-boundary-does-not-cover).
- **A replaced `setup` download.** The trust root is inside `setup`; distribute it through a channel your users already trust, and platform-sign it once that is available.
- **Confidentiality.** Repositories and artifacts are not encrypted.

## What the TUF profile defends against

| Attack | Defense |
|---|---|
| Serving an artifact the publisher never released | Only digests listed in signed targets metadata are accepted; length and SHA-256 are checked before unpacking |
| Forging or altering metadata | Ed25519 signatures with per-role key thresholds |
| Replaying an older release to downgrade users | `release_sequence` and every metadata version must not go backwards; accepted versions are stored per installation |
| Freezing users on stale metadata | Every metadata file expires; the timestamp after one day by default |
| Mixing files from different repository states | Snapshot pins the version of targets and every channel, and the timestamp pins the snapshot |
| Feeding a channel a release it was not delegated | Channel roles may only name `manifests/<product id>.json`, signed with the delegated keys |
| Oversized metadata to exhaust memory | Size limits on metadata files (the timestamp at most 16 KiB); larger files fail with `MetadataTooLarge` |
| Rotating to an attacker's root | Each new root must be signed by both the old and the new root keys and increase by exactly one version |

Verified by acceptance entries N1-INV-05, N1-INV-06 and N1-AC-02 to N1-AC-03. Specification: [tuf-profile-v1](https://github.com/niobium-project/niobium/blob/main/docs/spec/tuf-profile-v1.md).

## No code in the manifest

Manifests and component metadata are parsed strictly: unknown fields, duplicate keys, excessive depth and oversized documents are rejected, and the fields `pre_install`, `post_install`, `script`, `exec`, `shell` and `command` are refused anywhere. There is no field that makes the installer run a command (N1-INV-03, N1-AC-01).

## Privilege boundary

Machine-scope installs use a short-lived elevated helper that accepts only typed file and integration operations, inside `<install base>/<product id>`, with session authentication and replay protection. It cannot run programs, load libraries or open network connections. Details and the accepted residual risk: [Privilege boundary](/concepts/privilege/) (N1-INV-04).

## Extraction safety

Artifacts are unpacked by a strict extractor that can only create regular files and directories beneath the staging directory:

- symbolic links, hard links, devices and FIFOs are refused;
- absolute paths, drive letters, backslashes, `..` segments, control characters and Windows reserved names are refused;
- duplicate paths, including ones that differ only by case, are refused;
- entry count, single-file size, total size and compression ratio are capped, and an entry's declared size is charged before anything is written.

Verified by N1-INV-02 and N1-AC-04 against malicious archives built byte by byte. Specification: [artifact-format-v1](https://github.com/niobium-project/niobium/blob/main/docs/spec/artifact-format-v1.md).

## Crash guarantees

After an interruption at any point, the next run of `setup` recovers to the old or the new version, never a mix ([Transactions](/concepts/transactions/), N1-INV-01). Fatal errors write a crash record that holds only the version, product, engine phase, transaction number, time and return addresses ([Troubleshooting](/troubleshooting/#logs-and-crash-records)).

## Report a vulnerability

<!-- TODO(maintainers): publish a security policy (SECURITY.md or a section here) with a private
reporting channel, for example GitHub private vulnerability reporting, then replace this paragraph. -->

Niobium has not published a security policy or a private reporting channel yet. Until it does, do not put vulnerability details in a public issue: open an issue on [GitHub](https://github.com/niobium-project/niobium/issues) that asks the maintainers for a private contact, without describing the problem.
