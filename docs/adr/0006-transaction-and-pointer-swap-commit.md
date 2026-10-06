# ADR-0006: Transaction journal and pointer-swap commit

- **Status:** Accepted
- **Date:** 2026-10-07

## Context

Sections 9-10 of the source architecture require the old version to stay runnable until commit, the new version to be the only active one after commit, and recovery from any crash point.

## Decision

- Install root layout: `versions/<release_sequence>/<component>/`, `current`, `maintainer/`, `installation.json`, `journal/tx-<seq>.jsonl`.
- The Execute phase never touches `current`. Commit is a journaled pointer switch: on Unix a new symlink plus `rename(2)`; on Windows two renames of a junction, with recovery finishing an interrupted switch.
- OS integration (shortcut, association, service) refers to the stable `current` path, so nothing needs rewriting across versions.
- `RecoverIncompleteTransaction` runs first at startup: the last journal record decides rollback (before COMMIT) or roll-forward (after COMMIT).
- Every operation defines `apply`, `rollback` and `verify`, and is idempotent.

## Consequences

- Crash-injection tests kill after every op and every journal record, then assert after recovery that Active is OLD or NEW.
