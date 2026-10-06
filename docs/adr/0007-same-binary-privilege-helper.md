# ADR-0007: Same-binary closed-capability privilege helper

- **Status:** Accepted
- **Date:** 2026-10-07

## Context

Section 11 of the source architecture requires the GUI to run as a normal user, starting a short-lived helper only when needed, and the helper to accept only closed typed operations. The online installer should remain a single `setup` file.

## Decision

- The helper is the `setup --priv-helper-v1` mode. Its entry point is isolated in `libs/privilege/helper.zig` and dispatches only a closed op enum.
- The op set maps one-to-one onto the mutating operations of the `platform.Platform` vtable (see [ipc-v1](../spec/ipc-v1.md)). The broker implements the same vtable, so the executor and transaction do not distinguish elevated from unelevated work.
- IPC is length-prefixed JSON, and every message carries a transaction id and a nonce. Paths must lie inside a managed root declared by this transaction, and the shape of a managed root (`<install base>/<product id>`) is constrained by the helper's own policy.
- Elevation: Windows `ShellExecuteExW runas` + named pipe; macOS authorization prompt; Linux `pkexec`, falling back to `sudo`.
- The helper exits when the transaction ends; there is no resident elevated daemon.
- After the helper is lost, the broker sticks to returning `PrivilegeHelperLost`, the transaction stops and aborts, and recovery takes over.

## Consequences

- There is no `Exec`, `Shell`, `SpawnArbitraryProcess` or `LoadPlugin`.
- The cost of single-file distribution is that the helper shares binary size with the GUI, which is acceptable.
- The helper only restricts where it writes and does not validate content; a compromised same-user broker can still rewrite this product's machine-level installation. See the trust boundary section of ipc-v1.
- Bytes for written files cross the pipe as base64 with frames of at most 1 MiB; large files go through `copy_file` (the helper reads directly from staging).
