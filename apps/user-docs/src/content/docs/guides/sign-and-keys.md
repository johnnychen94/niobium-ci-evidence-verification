---
title: Sign and manage keys
description: Generate TUF signing keys, keep them safe, refresh expiring metadata, and order platform code signing.
---

Niobium signs every release with TUF keys you generate and keep. Whoever holds them can publish to your users, so treat them like a code-signing certificate. This guide covers generating them, where they may live, keeping metadata from expiring, and where OS code signing fits.

## Generate the keys

```sh
nbpack keygen --out keys/
```

`keys/` receives five files, one per role: `root.key.json`, `targets.key.json`, `snapshot.key.json`, `timestamp.key.json` and `channel.key.json`. On macOS and Linux each is created with mode 0600; on Windows they rely on the directory's access control.

`nbpack keygen` is the only way to create keys in v0.1, and it creates all five at once. The first `nbpack publish --init` writes the root public key into the repository; from then on `publish`, `promote` and `sign` refuse a key directory whose root key does not match the repository (`PackRootKeyMismatch`).

## Keep them out of builds and CI

- Generate and store the keys outside the product build and outside version control. The repository's `.gitignore` pattern `*.key.json` is a useful default in your own repository too.
- Never give signing keys to external CI or compatibility-testing systems. Test the staged release bytes there, and sign on a machine you control.
- `addBundle` without `.keys` generates throwaway keys on every clean build. A bundle signed that way can never update an installation made from an earlier bundle. Use it only for tests and demos.

## Keep metadata fresh

Signed metadata expires so that a stale or frozen repository is detected:

| Metadata | Default lifetime |
|---|---|
| timestamp | 1 day |
| snapshot, targets, channels | 30 days |
| root | 365 days |

Clients refuse expired metadata with exit code 4. Re-sign regularly; content stays the same and versions increase:

```sh
nbpack sign --repo <repo-dir> --keys keys/
```

`publish`, `promote` and `sign` all accept `--days <n>` and `--timestamp-days <n>` to change the lifetimes, and `--now <unix seconds>` to sign for a fixed time. The timestamp's short lifetime means `sign` has to run at least daily for a repository that clients should keep accepting.

## Rotate or recover keys

Clients already verify root rotation: they follow `N+1.root.json` files, each signed by both the old and the new root keys, so a rotated root does not require redistributing `setup`. The publisher side is not implemented: `nbpack` has no command to produce a new root version in v0.1. Until it exists:

- an online key (timestamp, snapshot or channel) that leaks cannot be replaced without a new repository and a new `setup`;
- a root key that leaks requires distributing a new `setup` that embeds a new root, through a channel your users trust.

The intended procedures are drafted in the [key rotation runbook](https://github.com/niobium-project/niobium/blob/main/docs/runbooks/tuf-key-rotation.md).

## Platform code signing

OS code signing (Authenticode `signtool` on Windows; Developer ID, Hardened Runtime and notarization on macOS) changes the bytes of your binaries. It must therefore happen before the artifacts are built and hashed:

1. build your binaries;
2. sign them with your platform certificate;
3. build the component artifacts from the signed files;
4. publish them with `nbpack publish`.

Signing after step 3 is too late: the artifacts already contain the unsigned binaries, and an artifact cannot be changed afterwards because releases name it by hash. Niobium v0.1 has not run this step with real certificates, and the `setup` that `addBundle` builds is not platform-signed; see [Status and platforms](/status/). The full ordered procedure is the [release signing runbook](https://github.com/niobium-project/niobium/blob/main/docs/runbooks/release-signing.md).
