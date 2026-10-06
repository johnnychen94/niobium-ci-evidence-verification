---
name: niobium-development
description: The main work loop for the Niobium installer framework - design → contract → implement → verify → deliver. Read this skill first for any design, implementation, debugging, acceptance, or documentation change; it turns the constraints in AGENTS.md into executable steps and links to the detailed rules and anti-pattern table in references/.
---

# Niobium development main loop

AGENTS.md holds the constraints; this skill holds the steps. When the two conflict, AGENTS.md wins, and this skill must be corrected.

## 0. Orient

1. Identify the layer the task touches: `core` / `contracts` / `platform` / service (manifest, trust, repository, package, executor) / flow (resolver, planner, transaction, privilege, bootstrap, portable) / `engine` / UI / apps / tools.
2. Read `build/modules.zig` to confirm the allowed import directions. If you need a new dependency, change it there first and state it in the PR description; `tools/check` rejects undeclared edges.
3. Find the affected spec (`docs/spec/*-v1.md`) and ADRs. Changing a wire format = changing the spec + schema + tests, all three in the same commit.

## 1. Design

- Write the failure scenarios before the success path: power loss, kill, disk full, locked file, UAC cancel, network reset, expired signature, rollback attack.
- Every new state must answer: after a crash here, how does `RecoverIncompleteTransaction` handle it? Write the answer into the recovery table in `docs/architecture/transaction-model.md`.
- Product differences can only be manifest data. When you need "product-specific logic", the answer is App Bootstrap (the app's own process), not an installer hook.
- See [references/design-and-debugging.md](references/design-and-debugging.md) for details.

## 2. Contract

- External data first goes through `contracts.json.decodeStrict` (unknown fields, duplicate keys, depth, and byte limits all fail), then semantic validation (`libs/manifest`).
- Put new limits in `contracts.Limits`; do not scatter constants.
- New C ABI function: keep `api/c/distribution.h` + `apps/libdistribution/root.zig` + `tests/c-smoke/main.c` in sync.

## 3. Implement

- Read the `zig-0.17` and `zig-tiger-style` skills. This repository's deviations and 0.17 pitfalls are in [references/implementation.md](references/implementation.md).
- Files internal to a module are not exposed: expose only through `pub` in `root.zig`.
- Every function ≤ 70 lines; every file ≤ 600 lines; beyond that, split into owner files by semantics, do not create `utils.zig`.

## 4. Verify

Pick the minimal set for the change, then run the full set:

| Change | Command |
|---|---|
| Any Zig | `zig build check test` |
| transaction / executor / platform | `zig build sim -Dseeds=2000` |
| Parser | `zig build fuzz` (and add the triggering sample to `tests/fuzz/corpus/`) |
| UI | `zig build golden`, with `-Dupdate=<component>` when needed; inspect `zig build gallery` manually |
| CLI / engine | `zig build e2e c-smoke` |
| Size / dependencies | `zig build cross check-binary size-gate` |
| Before delivery | `zig build verify --cache-poison=disallowed` |

Put the acceptance ID at the start of the test name (`test "N1-INV-03: ..."`) and write the status back to `docs/acceptance-plan-v0.1.md`. Details in [references/acceptance.md](references/acceptance.md).

## 5. Deliver

- Commit: `<type>(<scope>): English summary`, ≤ 300 net lines; `zig build check-commits`.
- The final report lists: commands actually run and their results, items not run and why, known limitations. Do not write "passed" without evidence.

## Anti-patterns

Check [references/anti-patterns.md](references/anti-patterns.md) first. If any row matches, stop and change the design.
