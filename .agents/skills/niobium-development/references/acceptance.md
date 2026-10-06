# Acceptance and evidence

## Status words

Use only `PASS`, `FAIL`, `BLOCKED`, `NOT_RUN`, `DEFERRED`. `PASS` must satisfy all of the following:

1. At least one test name starts with the acceptance ID;
2. That test actually ran and passed in this `zig build verify` (or the designated lane);
3. The evidence path is written into the corresponding row of `docs/acceptance-plan-v0.1.md`.

## ID families

| Prefix | Meaning | Main lane |
|---|---|---|
| `N1-UJ-xx` | User journeys (install, update, repair, uninstall, offline, Portable Run) | e2e |
| `N1-INV-xx` | Invariants (OLD-or-NEW, no writes outside staging, TUF rollback rejection...) | test, sim |
| `N1-AC-xx` | Architecture acceptance (size, dependencies, ABI, UI golden, platform contract...) | check, cross, golden, conformance |

## Evidence directory

`.evidence/<suite>/<UTC>/`: `summary.json` (command, exit code, start and end time, git rev) + logs + artifact hashes. The evidence directory is not committed; the acceptance table only records the path and the verdict.

## How to write BLOCKED

State the blocking condition and the part that was executed, for example: "vm-smoke: Windows 11 VM is suspended, `prlctl resume` failed (verbatim error); Linux ARM64 already PASS".
