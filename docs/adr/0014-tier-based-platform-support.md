# ADR-0014: Tier-based platform support

- **Status:** Accepted
- **Date:** 2026-10-07

## Context

Niobium is a hobby project with one maintainer and no company resources ([About the project](../../apps/user-docs/src/content/docs/about.md)). Every platform the project claims costs build, test and release time on every change. Today only a macOS aarch64 host runs `zig build verify`, and real-OS evidence for Windows and Linux depends on local Parallels VMs ([vm-smoke](../runbooks/vm-smoke.md)). Without an explicit policy, "it cross-compiles" drifts into "it is supported", which AGENTS.md section 6 forbids.

## Decision

Every build target belongs to one of three tiers. The current assignment, the reference OS of each target and the platform roadmap are user-facing and live on the [Platform support](../../apps/user-docs/src/content/docs/platforms.md) page of the user site; this record fixes what each tier obliges maintainers to do.

- **Tier 1:**
  - The target is a shipping entry in `cross_targets` (`build/targets.zig`), so `cross`, `test-cross`, `check-binary` and `size-gate` run in `verify` on every change.
  - Before a release, the platform contract suite (L3), the end-to-end scenarios (L4) and the real-OS smoke run (L5) have run on the reference OS, with evidence in `.evidence/`.
  - A `FAIL` on any of them blocks the release. A `BLOCKED` or `NOT_RUN` result is stated in the release notes and is never recorded as `PASS`.
  - Regressions are fixed before new features.
- **Tier 2:**
  - The target is in `cross_targets`, so it is built and binary-linted in `verify`. It may be `smoke_only`, which keeps it out of the size gate.
  - Real-OS runs are best effort. Their results are recorded in the acceptance plan but never block a release.
- **Tier 3:**
  - The target is not in `cross_targets` and not in `verify`. It is listed on the roadmap only.
  - A port is accepted only with an owner who keeps its test lane running, and only if it adds no Tier 1 work.
- **Promotion** needs a repeatable evidence lane on the reference OS, a named reference OS version and a maintainer with time for it. It is a reviewed edit to the Platform support page. Promotion into Tier 1 also needs a new ADR.
- **Demotion:** a Tier 1 target whose real-OS lane stays unavailable for two consecutive releases moves to Tier 2.
- `tools/check-docs` fails when a `cross_targets` name is missing from the Platform support page.

## Consequences

- A Linux Tier 1 claim covers the reference distribution only (Ubuntu LTS). Other distributions are at most Tier 2 until they have their own lane.
- Tier 1 targets currently lack some of the lanes their tier requires (an x86_64 Ubuntu guest, native x64 Windows, machine-scope smoke, the macOS GUI walkthrough). These gaps are on the Platform support roadmap and in [roadmap-v0.1](../roadmap-v0.1.md); until they close, the affected acceptance entries stay `BLOCKED` or `NOT_RUN`.
- A new platform backend ([niobium-platform-capability](../../.agents/skills/niobium-platform-capability/SKILL.md)) enters at Tier 3.
