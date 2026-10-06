---
title: Repository and install layout
description: The files of a Niobium repository, an offline bundle, an install root and the per-user cache, and their default locations.
---

Canonical sources: [tuf-profile-v1](https://github.com/niobium-project/niobium/blob/main/docs/spec/tuf-profile-v1.md) for the repository, the [transaction model](https://github.com/niobium-project/niobium/blob/main/docs/architecture/transaction-model.md) for the install root, and the path policy in [`libs/planner/paths.zig`](https://github.com/niobium-project/niobium/blob/main/libs/planner/paths.zig).

## Repository

```text
metadata/<N>.root.json        one per root version
metadata/timestamp.json       the only file without a version number
metadata/<N>.snapshot.json
metadata/<N>.targets.json
metadata/<N>.<channel>.json   stable, beta, nightly
targets/<sha256 hex>          manifests and artifacts, named by their hash
```

The layout is the same served over HTTP or read from a directory. Only `nbpack` writes it.

## Offline bundle

```text
<bundle>/
  setup                       setup.exe on Windows
  repository/                 a complete repository, as above
  licenses/Inter-OFL.txt      license of the font compiled into setup
```

## Install root

```text
<install root>/
  installation.json           installed product, release, manifest, integrations, bootstrap state
  current -> versions/<n>     the active version
  versions/<n>/<component>/   files of each component
  staging/tx-<n>/             staging of user-scope transactions
  maintainer/setup            copy of setup for update, repair, uninstall (setup.exe on Windows)
  trust/state.json            accepted TUF versions and release sequence
  journal/                    transaction journal
```

## Default locations

| | macOS | Windows | Linux |
|---|---|---|---|
| Install root, user scope | `~/Library/Application Support/<id>` | `%LOCALAPPDATA%\Programs\<id>` | `$XDG_DATA_HOME/<id>`, or `~/.local/share/<id>` |
| Install root, machine scope | `/Library/Application Support/<id>` | `%ProgramFiles%\<id>` | `/opt/<id>` |
| Per-user cache | `~/Library/Caches/<id>` | `%LOCALAPPDATA%\<id>\Cache` | `$XDG_CACHE_HOME/<id>`, or `~/.cache/<id>` |

`<id>` is the product id. `--install-dir` replaces the install root. Components cannot choose any of these paths.

## Per-user cache

```text
<cache>/
  lock                        transaction lock, one per user and product
  downloads/                  artifacts being downloaded
  staging/tx-<n>/             staging of machine-scope transactions (user scope stages in the install root)
  logs/crash-<time>.json      crash records
  portable/                   Portable Run cache
    sha256/<hex>/             unpacked component, its component.json and last-use time
    downloads/
    trust.json                accepted TUF versions for Portable Run
```
