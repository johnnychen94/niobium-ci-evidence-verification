---
name: review-niobium
description: Security and boundary checklist for reviewing Niobium changes (process execution, elevation, archive extraction, TUF, C ABI, size and dependency growth, module boundaries). Use for reviews, self-checks, or changes that touch the security surface.
---

# Niobium review checklist

Answer each item "yes/no/not applicable"; every "no" must come with a fix or a justification in the review.

## Execution and elevation

- [ ] New process spawns appear only in paths listed in `build/modules.zig` `spawn_allowlist`.
- [ ] The spawn argv comes from validated data; it does not go through a shell; it has a timeout and an output limit.
- [ ] Elevated ops belong to the closed `ipc-v1` set; the helper validates the tx-id, the nonce, and that paths are inside the install root.
- [ ] When the helper crashes (EOF), the broker rolls back the transaction and keeps the installer alive.

## Archives and file system

- [ ] Extraction goes only through `package.extract`; it rejects absolute paths, `..`, symlinks, hardlinks, devices, duplicate paths, and over-limit sizes and compression ratios.
- [ ] Writes happen only in the `versions/<seq>` staging area; the only commit is the pointer swap.
- [ ] Delete operations are confined to the install root and have journal records.

## Trust

- [ ] All remote bytes are verified by TUF before use (length + sha256 + signature chain).
- [ ] Comparing old and new uses `release_sequence` and the TUF version number; rollback, freeze (expiry), and mix-and-match snapshots are rejected.
- [ ] Root rotation requires threshold signatures from both the old root and the new root.

## C ABI

- [ ] `export fn` does not expose Zig types, slices, error unions, or allocators.
- [ ] Every error maps to an `nb_status`; output buffers are provided by the caller or have a matching free function.
- [ ] `distribution.h` is in sync with the implementation, and `zig build c-smoke` passes.

## Size and dependencies

- [ ] `zig build size-gate`: setup ≤ 30 MiB, growth ≤ 5% (otherwise update the baseline in the same commit and explain).
- [ ] `zig build check-binary`: no new dynamic dependencies; PE flags complete; no RWX segments.
- [ ] New third_party code has a LICENSE, PROVENANCE.md, and hand-written bindings.

## Boundaries and quality

- [ ] No new import edges outside `build/modules.zig`.
- [ ] No new `lint-allow`, or each one has a specific reason.
- [ ] Test names carry acceptance IDs; acceptance table statuses have evidence.
- [ ] Logs and crash records contain no tokens, raw signed URLs, or archive bytes.
- [ ] No new queue, retry, or read without an upper bound (AGENTS.md section 5).
- [ ] Generated outputs are in sync with their inputs and were not edited by hand.
