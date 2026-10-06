# Transaction model

## Install root

```text
<root>/
  installation.json          installed state (product, active release, manifest bytes, integrations, bootstrap state and bootstrap_target)
  current -> versions/<seq>  Active pointer (Unix symlink / Windows junction)
  versions/<seq>/<component>/…
  maintainer/                reserved component __installer_runtime (a copy of setup itself)
  trust/state.json           TUF trusted versions
  journal/tx-<seq>.jsonl     transaction journal
```

The single-transaction lock is not inside the root: the engine takes the lock at `<cache>/lock` (cache is `--work-dir` or `planner.paths.cacheRoot`, one per user per product), because on first install the root does not exist yet, and a machine root is not writable by a normal user either. Known limitation: two different users operating on the same machine-scope product at the same time do not exclude each other; v0.1 does not handle this.

## Journal records

One JSON object per line: `{"r":"begin","tx":"…","seq":3,"kind":"update","from":2}`, `{"r":"op_done","i":4}`, `{"r":"ready_to_commit"}`, `{"r":"commit"}`, `{"r":"bootstrap_started"}`, `{"r":"bootstrap_done","ok":true}`, `{"r":"finalized"}`. Each write is followed by fsync; when parsing, a truncated last line is treated as not written.

## State machine and recovery

| Last record | Recovery action | Result |
|---|---|---|
| none / `begin` / `op_done` | Roll back completed ops in reverse order, delete staging | OLD |
| `ready_to_commit` | Same as above | OLD |
| `commit` | Re-run the pointer swap (idempotent) and post-commit ops | NEW |
| `bootstrap_started` | Mark `bootstrap_pending` | NEW |
| `bootstrap_done` / `finalized` | Clean up the old version and the journal | NEW |

Invariant: ops in the Execute phase write only to `versions/<new>/` and to version-suffixed integration temp files, and never modify what `current` points to; only commit switches `current`. Integrations reference the stable path through `current`, so they stay valid both before and after commit.

## Three semantics of an op

Every `planner.Op` has `apply`, `rollback` and `verify`, all idempotent: rolling back an op that never ran is a no-op. Crash-injection tests terminate after every op and after every journal record, and after recovery assert that Active is OLD or NEW.

## Implementation conventions

| Convention | Reason |
|---|---|
| `journal/tx-<n>.plan.json` is written before `begin`; on recovery, a journal without `begin` or an orphan plan is treated as "never started" | The journal exists before any op runs |
| Deletion order: journal first, then plan | An orphan plan is harmless; an orphan journal would make recovery get stuck |
| After one failed append, this process appends nothing more to the journal (poisoned) | Appending after a half-written record would corrupt a middle line |
| Recovery first truncates the journal to the last newline, then appends records | Same as above; a torn tail may only appear at the end |
| Roll-forward re-runs all post-commit ops instead of continuing from the last `op_done` | `write_state` needs the locations returned by every `activate_integration`; these ops are idempotent anyway |
| A `bootstrap` failure does not block finalize | Commit is the point of no return; `installation.json` keeps `bootstrap: pending`, and the engine retries |
| user scope: staging is inside the root and `place_release` uses rename; machine scope: staging is in the user cache and is copied file by file | The closed op set of the elevation helper has no rename across a trust boundary |
| uninstall's `remove_root` deletes `installation.json` first and `journal/` and the root last | If killed midway, recovery can still roll forward from the journal |
| The single-transaction lock is an advisory exclusive file lock (`Lock.acquire`), released when the process exits | A crash never leaves a lock that needs manual cleanup |

Verification: `libs/transaction/transaction_test.zig` kills at every platform mutation (N1-INV-01) and requires both outcomes, OLD and NEW, to appear; `zig build sim` mixes injected faults and kills across transactions and multiple rounds of recovery (N1-AC-07).
