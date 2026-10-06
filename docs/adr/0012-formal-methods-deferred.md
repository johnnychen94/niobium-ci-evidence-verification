# ADR-0012: Formal models deferred

- **Status:** Accepted
- **Date:** 2026-10-07

## Context

The transaction/commit/recovery state machine suits TLA+ modeling, but TLC depends on Java, which violates [ADR-0001](0001-repository-baseline-and-zig-only-toolchain.md).

## Decision

- v0.1 has no `formal/`. State machine correctness is covered by three kinds of Zig tests: crash injection at every kill point, seeded fault simulation with `zig build sim`, and exhaustive enumeration of journal replay.
- Re-evaluate when the state machine grows to concurrent transactions or maintainer self-update.

## Consequences

- The evidence is weaker than model checking; the acceptance plan marks how each related item is covered.
