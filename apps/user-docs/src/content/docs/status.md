---
title: Status and platforms
description: What has been verified in Niobium 0.1, on which platforms, and what is blocked, not run or deferred.
---

Niobium 0.1 is a vertical slice that proves the model; it is not production-ready. This page is the site's single statement of what has been verified. Other pages link here instead of repeating it.

Statuses use five values only:

| Status | Meaning |
|---|---|
| `PASS` | Verified by an automated test or build gate, with recorded evidence |
| `FAIL` | Verified and failing |
| `BLOCKED` | Cannot run yet; the reason is recorded |
| `NOT_RUN` | Can run, has not been run |
| `DEFERRED` | Deliberately out of scope for this version |

The source of truth is the repository's [acceptance plan](https://github.com/niobium-project/niobium/blob/main/docs/acceptance-plan-v0.1.md) and [roadmap](https://github.com/niobium-project/niobium/blob/main/docs/roadmap-v0.1.md); if this page and those disagree, they are right.

## Where it was verified

All `PASS` entries come from `zig build verify` on a macOS arm64 host; the end-to-end suite also passes in a Debian bookworm arm64 container. Nothing has been verified yet on a real Windows machine or a full Linux desktop.

Build targets are `x86_64-windows`, `aarch64-macos` and `x86_64-linux`, plus `aarch64-linux` for VM tests; their support tiers and reference operating systems are on [Platform support](/platforms/). All of them cross-compile and pass the binary checks, and the three shipping targets keep `setup` under 30 MiB (N1-AC-15 to N1-AC-17: `PASS`). Compiling for a platform is not the same as having verified it there.

## User journeys

| ID | Journey | Status |
|---|---|---|
| N1-UJ-01 | User-scope online install from an HTTP repository; App Bootstrap is invoked | `PASS` |
| N1-UJ-02 | Administrator silent install, `install --silent --json --scope machine` | `BLOCKED` |
| N1-UJ-03 | Update to a higher `release_sequence` | `PASS` |
| N1-UJ-04 | Incident rollback: a higher sequence ships an older application version | `PASS` |
| N1-UJ-05 | Repair restores deleted or tampered files | `PASS` |
| N1-UJ-06 | Uninstall leaves the install root and integrations clean | `PASS` |
| N1-UJ-07 | Install from an offline bundle | `PASS` |
| N1-UJ-08 | Portable Run: authorization, cache, execution, cleanup | `PASS` |
| N1-UJ-09 | A C program completes check, resolve, fetch, stage and commit through the C ABI | `PASS` |
| N1-UJ-10 | The five installer window screens complete an install on macOS (manual walkthrough) | `NOT_RUN` |

N1-UJ-02 is blocked for the same reason as the real-OS smoke tests below, and additionally because the smoke tool runs user scope only so far.

## Guarantees

| ID | Guarantee | Status |
|---|---|---|
| N1-INV-01 | After recovery from any kill point, the active version is the old or the new one | `PASS` |
| N1-INV-02 | Unpacking an artifact cannot write outside the staging directory | `PASS` |
| N1-INV-03 | Forbidden manifest and component fields are rejected | `PASS` |
| N1-INV-04 | The elevated helper accepts only its closed operations, inside the managed root | `PASS` |
| N1-INV-05 | TUF rejects expired, rolled-back, forged, under-threshold and mismatched metadata | `PASS` |
| N1-INV-06 | `release_sequence` strictly increases; the application version may go down | `PASS` |
| N1-INV-07 | The window and the command line run the same engine and plan | `PASS` |
| N1-INV-08 | Unknown schema versions and too-old installers fail closed | `PASS` |

These run on the build host against a test platform with injected faults and against the host's real file system. They are not evidence for platforms that have not been run (below).

## Platforms

| Item | Status |
|---|---|
| Real-OS smoke test, Windows 11 (N1-AC-18) | `BLOCKED` |
| Real-OS smoke test, Ubuntu 24.04 arm64 (N1-AC-19) | `BLOCKED` |
| Authenticode and Apple Developer ID signing and notarization | `DEFERRED` |
| Native Wayland window backend (Linux uses X11) | `DEFERRED` |
| Screen-reader bridges (UI Automation, NSAccessibility, AT-SPI) | `DEFERRED` |
| Native folder picker on Linux | `DEFERRED` |

The real-OS smoke tests are blocked because the test virtual machines were not running when the suite last ran. What each platform is committed to, and which test lanes are still missing, is on [Platform support](/platforms/).

## Deferred features

| Item | Status |
|---|---|
| Embedded updates for Electron hosts (`distribution.node`) | `DEFERRED` |
| Protocol handlers, autostart entries and environment variables as capabilities | `DEFERRED` |

## Gaps without an acceptance entry

- `nbpack` cannot rotate root or online keys yet; clients already verify rotated roots ([Sign and manage keys](/guides/sign-and-keys/#rotate-or-recover-keys)).
- There is no published security policy or private reporting channel ([Security](/security/#report-a-vulnerability)).
- The build API carries no compatibility promise in 0.1: pin a commit. The `setup` exit codes and JSON event schema are declared a compatibility contract ([exit codes](/reference/exit-codes/)), and the C ABI changes only by appending to its versioned function table.
