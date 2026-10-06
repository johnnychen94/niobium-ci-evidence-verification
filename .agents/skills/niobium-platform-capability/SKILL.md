---
name: niobium-platform-capability
description: Use when adding or changing a Niobium OS capability (shortcuts, file associations, uninstall registration, PATH, services, etc.) or a platform backend (macOS / Windows / Linux file system, processes, elevation, windows). Contract first, and lists the crash pitfalls of each platform.
---

# Platform capabilities and backends

## Contract-first process

1. In `docs/spec/platform-contract-v1.md`, specify: inputs, idempotency, reversible operations (undo records), the required privilege level, behavior on all three platforms, and the return value when unsupported.
2. Add the function to the `Platform` interface in `libs/platform/root.zig`; implement it in `libs/platform/virtual.zig` first (including failpoints).
3. Write contract cases in `libs/conformance`: the same set of cases must pass against both VirtualPlatform and the host backend.
4. Then implement `libs/platform/{macos,windows,linux}.zig`.
5. If elevation is needed: add it to the `ipc-v1` op enum, keep broker and helper in sync, and add negative tests for unknown op / wrong nonce / out-of-bounds path.
6. The planner generates the corresponding op; the executor runs it and writes undo; transaction rollback calls undo.

A new platform backend or target enters at Tier 3 and is promoted only under [ADR-0014](../../../docs/adr/0014-tier-based-platform-support.md).

## Platform pitfalls

**Windows**
- Convert every path to UTF-16 with the `\\?\` prefix; do not use `MAX_PATH` buffers.
- Sharing violations / antivirus locks: bounded backoff retry (`contracts.Limits.lock_retry_max`), then return `error.FileLocked`, and the UI prompts "close the application".
- Directory pointer commit: two junction renames (`current.new` → `current`), not a symlink (which requires Developer Mode).
- The window procedure must not propagate errors outward; COM initialization/uninitialization must be paired.
- The user can cancel `runas` elevation: map it to `error.ElevationCancelled` (exit code 9).

**macOS**
- AppKit calls only on the main thread; one autorelease pool per event loop iteration.
- Zig cannot catch ObjC exceptions: validate arguments (nil, ranges) before calling.
- Elevation: Authorization Services prompt; user cancellation likewise maps to `ElevationCancelled`.
- The quarantine attribute is not handled in the MVP; it is recorded in the roadmap.

**Linux**
- X11: connection loss and protocol error replies are errors, not panics; validate reply lengths with `std.math.cast`.
- Without `DISPLAY` the GUI is unavailable; fall back to the CLI and return an explicit error.
- Elevation: `pkexec`, or `sudo -n` when it is unavailable; if neither is available, return `error.ElevationUnavailable`.
- `.desktop` files and `update-desktop-database` belong to the capability; when the tool is missing, log a warning and do not fail.

## Completion check

- `zig build test` (including conformance) passes on the host; `zig build sim` covers the new failpoints.
- `zig build vm-smoke` has run on Windows 11 and Ubuntu ARM64, or the BLOCKED reason is written in the acceptance table.
