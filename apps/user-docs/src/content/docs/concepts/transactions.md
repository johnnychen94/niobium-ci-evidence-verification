---
title: Transactions
description: How Niobium guarantees that an interrupted install, update or uninstall ends at the old version or the new one.
---

Every install, update, repair and uninstall runs as one transaction with a single point of no return. Before that point the old version stays active and recovery rolls back; after it the new version is active and recovery rolls forward. Kill the process, cut the power or fill the disk at any moment: the next run of `setup` ends at the old version or the new one, never a mix.

## The install root

```text
<install root>/
  installation.json        what is installed: product, release, manifest, integrations
  current -> versions/<n>  the active version (a symlink, or a junction on Windows)
  versions/<n>/<component>/...
  maintainer/              a copy of setup, used for later update, repair and uninstall
  trust/state.json         the TUF versions this installation has accepted
  journal/                 the transaction journal
```

Shortcuts, file associations and services point at paths through `current`, so they stay valid on both sides of a switch.

## The steps

1. **Stage.** Verified artifacts are unpacked into `versions/<new>/`. Nothing the active version uses is touched.
2. **Execute.** Planned operations run one by one. Each writes only to the new version or to version-specific temporary integration files, and each has a rollback.
3. **Commit.** `current` is switched to the new version in one atomic step. This is the point of no return.
4. **Finalize.** App Bootstrap runs, the old version and the journal are cleaned up.

Progress is recorded in an append-only journal (`begin`, one record per completed operation, `ready_to_commit`, `commit`, bootstrap start and end, `finalized`), flushed to disk after every record.

## Recovery

`setup` always runs recovery first, before doing anything else. It reads the last journal record:

| Interrupted | Recovery | Result |
|---|---|---|
| Before the commit record | Roll back completed operations in reverse order, delete staging | Old version |
| After the commit record | Repeat the switch and the post-commit operations (all are idempotent) | New version |
| While App Bootstrap ran | Mark bootstrap as pending; it is retried later | New version |

A half-written last journal line counts as not written. Only one transaction per product and user runs at a time; a second one gets exit code 10. The lock is released by the operating system when the process ends, so a crash never leaves a lock to clean up by hand.

## App Bootstrap is after the commit

Your application's [App Bootstrap](/concepts/app-bootstrap/) entrypoint runs after the switch. If it fails, the new version stays active, `setup` exits with code 8 (`bootstrap_pending`), and bootstrap is retried on a later run. Rolling back files after the application may already have migrated its data would be worse than retrying the migration.

## How this is tested

Crash-injection tests kill the transaction after every file system mutation and after every journal record, and require both outcomes, old and new, to occur; a seeded simulation mixes injected faults with repeated recovery. The results are listed under invariant N1-INV-01 on [Status and platforms](/status/). The full state machine is specified in the [transaction model](https://github.com/niobium-project/niobium/blob/main/docs/architecture/transaction-model.md).

One known limitation: two different users operating on the same machine-scope product at the same moment do not exclude each other.
