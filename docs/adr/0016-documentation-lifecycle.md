# ADR-0016: Documentation lifecycle

- **Status:** Accepted
- **Date:** 2026-10-07

## Context

The maintainer documentation has several kinds of document (ADRs, specs, architecture notes, runbooks, roadmap and acceptance plan) but no written rule for how each one changes or retires. The ADR index said only that a replacement is declared by a new ADR: an old ADR had no way to point to its replacement, a partial replacement had no form, and references in specs, AGENTS.md and skills could keep citing a replaced rule. Before the first public commit, the original ADR-0011 was deleted and its successor, ADR-0013, renumbered to 0011, which left 0013 unassigned with no record.

The project has one maintainer. The aim is accurate information with little ceremony, so this decision adds workflows and no new checks or CI gates.

## Decision

- [docs-management](../development/docs-management.md) holds the lifecycle of each document kind and the step-by-step workflows; this ADR records only the decision.
- ADRs are never rewritten once accepted. They retire through status changes and two-way links: `Proposed`, `Accepted`, `Superseded`, `Deprecated`, with the optional fields `Supersedes`, `Superseded by`, `Amends`, `Amended by`. Numbers are never reused or renumbered; an unassigned number gets an index row.
- Specs are edited in place, and git history is the record of earlier text. The `-vN` file suffix tracks the contract version the spec describes.
- `architecture/`, `development/` and `runbooks/` describe the current state and change in the same commit as the behaviour they describe.
- Implementation traces in `docs/implementation/` are optional, written only for large multi-commit changes, and never a source of truth.
- When `docs/` and `apps/user-docs` cover the same topic, one owns it and the other links to it.

## Consequences

- A reader of a replaced ADR finds its replacement from the file itself, and the index Status column stays one short phrase.
- Superseding an ADR includes a manual reference sweep; nothing enforces it, so a missed reference is found by the periodic cleanup pass described in docs-management, not by CI.
- Earlier spec text is recovered from git, not from old files in the tree.
- `tools/check-docs` still checks only that ADRs carry Status and Date.
