---
title: Platform support
description: Which platforms Niobium targets, what each support tier commits to, and what comes next.
---

Niobium sorts the platforms it builds for into three tiers. A tier states what the project commits to on that platform; whether the commitment is met today is recorded on [Status and platforms](/status/), the only page that reports results.

The list is short on purpose. Niobium is maintained by one person in spare time, with no company resources behind it ([About the project](/about/)), and every Tier 1 platform costs build, test and release time on every change.

## Tiers

| Tier | Built on every change | Tested on a real OS before a release | Can block a release | Fixes |
|---|---|---|---|---|
| Tier 1 | Yes | Required | Yes | First priority |
| Tier 2 | Yes | Best effort | No | When time allows |
| Tier 3 | No | No | No | Only with a volunteer owner |

- **Built on every change** means the target is cross-compiled in ReleaseSafe and its binaries pass the binary lint (allowed dynamic libraries, PE flags, no writable and executable memory). Shipping targets also stay under the 30 MiB size budget for `setup`.
- **Tested on a real OS** means the platform contract suite, the end-to-end install, update, repair and uninstall scenarios and a smoke run on the reference OS. For a Tier 1 platform, a known failure blocks the release; a test that could not run is reported in the release notes as `BLOCKED` or `NOT_RUN`, never as passed.
- **Tier 3** platforms are candidates. Nothing is built for them by default, and nothing about them is promised.

## Current platforms

| Target | Tier | Reference OS | Notes |
|---|---|---|---|
| `aarch64-macos` | 1 | macOS on Apple silicon | The minimum macOS version is not pinned yet |
| `x86_64-windows` | 1 | Windows 11 (x64) | |
| `x86_64-linux` | 1 | Ubuntu 24.04 LTS | Static musl binaries with no dynamic library dependencies; other distributions may work but are not covered |
| `aarch64-linux` | 2 | Ubuntu 24.04 (ARM64) | Built and linted, used for VM smoke runs; not yet a shipping target, so the size budget does not apply |

Results for each target are on [Status and platforms](/status/).

## Roadmap

### Before the first Tier 1 release

Each Tier 1 platform still has a gap between its commitment and its test lanes:

- **`x86_64-linux`:** there is no real-OS test lane yet. The existing VM lane runs Ubuntu 24.04 on ARM64, which exercises `aarch64-linux`, not the x64 build.
- **`x86_64-windows`:** the only real-OS lane runs the x64 build under emulation on Windows 11 for ARM64. Native x64 hardware is not covered.
- **All platforms:** the real-OS smoke run covers user-scope installs only; machine-wide installs are not exercised there.
- **`aarch64-macos`:** the walkthrough of the graphical installer on a real Mac is a manual check that has not been run, and the minimum supported macOS version still has to be chosen.

### Candidates

| Candidate | Tier | What it needs |
|---|---|---|
| `aarch64-windows` | 3 | A build target and binary-lint entry, and a real-OS lane on Windows 11 for ARM64 |
| Kylin and UOS, x86_64 and aarch64 | 3 | A real-OS lane per distribution. The Linux binaries are static, so they are expected to run unchanged, but that is untested; the desktop integration (`.desktop` entries, MIME packages, systemd units, XDG directories) has to be checked on each distribution |

### Not planned

- **A native Wayland backend.** On Wayland sessions the installer window runs through XWayland. The decision is recorded in [ADR-0010](https://github.com/niobium-project/niobium/blob/main/docs/adr/0010-x11-now-wayland-deferred.md).

## Moving between tiers

A platform moves up a tier when it has all of the following:

- a repeatable test lane on the reference OS that produces recorded evidence;
- a named reference OS version;
- a maintainer with the time to keep that lane running.

Moving into Tier 1 also needs a recorded decision, because it adds work to every release. A Tier 1 platform whose real-OS lane stays unavailable for two releases in a row moves down to Tier 2.

Ports to a Tier 3 candidate are welcome when they come with someone who will keep the test lane running, and when they add no work to the Tier 1 platforms. The policy itself is recorded in [ADR-0014](https://github.com/niobium-project/niobium/blob/main/docs/adr/0014-tier-based-platform-support.md).
