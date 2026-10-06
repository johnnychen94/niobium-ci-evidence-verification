---
title: Artifacts and Portable Run
description: Immutable component artifacts, how they are identified, and running a component without installing it.
---

An artifact is an immutable file identified by its SHA-256 digest. Once a release names a digest, the bytes behind it can never change; a new build is a new artifact. This is what lets Niobium test the exact bytes it later ships, and promote a release between channels without rebuilding it.

## Component artifacts

A component is a deployable unit: a set of files plus named entrypoints. Its artifact is a `tar.zst` file with a fixed layout:

```text
component.json      metadata: id, version, platform, entrypoints, executables
files/...           everything that is installed under current/<component>/
```

Entries are sorted and timestamps and owners are zeroed, so the same inputs produce the same bytes. An artifact is built for one platform (`macos-aarch64`, `windows-x86_64`, and so on); a component that ships on three platforms has three artifacts.

A component carries no install scripts and owns no absolute paths. Which file is executable is decided by the `executables` list in `component.json`, not by modes stored in the archive.

## How an artifact is trusted

The release manifest lists each artifact as `sha256:<digest>` under its platform key, and the signed TUF targets metadata lists the same digest with its length. The installer downloads the artifact, checks length and digest, and only then unpacks it with a strict extractor that refuses links, devices, unsafe paths and archive bombs ([Security](/security/#extraction-safety)).

## Portable Run

Some tools do not need installing. `setup run <product>:<component>.<entrypoint>` resolves the release through the same signed repository, unpacks the component into a per-user, content-addressed cache and runs it, without creating an install root:

```sh
setup run com.example.hello:runtime.main --repo repo -- --some-argument
```

Cached components are reused by digest, so a second run does not download again; each run removes cache entries unused for 30 days. The program's exit code is returned unchanged.

Portable Run, installed applications and embedded updates are separate profiles: what one is allowed to do is not inherited by another. The embedded-update profile for Electron hosts is not implemented in v0.1.

## Offline bundles

An offline bundle is a directory, not a self-extracting archive: `setup` next to a complete copy of the signed repository. `setup` finds `repository/` beside itself and verifies it exactly as it would verify an online repository. See [Publish and host](/guides/publish-and-host/#ship-an-offline-bundle).
