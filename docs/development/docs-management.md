# Documentation management

How each kind of maintainer document changes and retires, decided in [ADR-0016](../adr/0016-documentation-lifecycle.md). These are workflows, not checks: nothing here is enforced by `zig build`. Precedence between documents is in [AGENTS.md section 1](../../AGENTS.md).

## Document kinds

| Kind | Holds | How it changes | How it retires |
|---|---|---|---|
| `adr/` | A decision, its context and consequences | Body is fixed once Accepted | Status becomes Superseded or Deprecated |
| `spec/*-vN.md` | What a contract is | Edited in place | The contract is removed, with an ADR |
| `architecture/` | How the system works now | Same commit as the behaviour change | Rewritten in place |
| `development/`, `runbooks/` | How to work, step by step | Edited in place | Deleted when no longer true |
| `roadmap-v0.x.md`, `acceptance-plan-v0.x.md` | Phase scope and acceptance status | Edited during the phase | Frozen when the next phase opens |
| `source/` | The original architecture input | Never | Never |
| `implementation/YYYY-MM-DD-*.md` | A dated trace of one large change (optional) | Never edited after the change | Left in place; never cited as truth |

When code and a document disagree, the ADR or spec wins: fix the code, or write an ADR that changes the rule. `architecture/` follows the code and the ADRs, and is corrected in the same commit.

## ADRs

Fields at the top of each ADR, one per line in the form `- **Field:** value`:

| Field | Required | Value |
|---|---|---|
| Status | Yes | `Proposed`, `Accepted`, `Superseded` or `Deprecated` |
| Date | Yes | Date of the last status change |
| Supersedes, Superseded by | When a decision is fully replaced | ADR links |
| Amends, Amended by | When part of a decision is replaced | ADR links and the affected section |

- `Proposed` is how a conflict found during work is recorded (AGENTS.md section 1); a Proposed ADR can be edited freely.
- `Deprecated` means withdrawn with no replacement; the ADR body says why in a closing note.
- Once an ADR is Accepted, only typos and broken links are fixed in place. A change of meaning is a new ADR.
- Numbers are assigned once and never reused or renumbered. An unassigned number gets an index row that says why.

### Replace or amend a decision

1. Write the new ADR. Its Decision section states exactly what it replaces: the whole decision, or named bullets.
2. In the old ADR, change only the header: set Status to `Superseded` (full replacement) or keep `Accepted` (amendment), update Date, and add `Superseded by` or `Amended by`. Do not edit its body.
3. Search for references to the old rule and point them at the new ADR where the rule changed:

   ```sh
   rg -n 'ADR-NNNN|adr/NNNN-' docs AGENTS.md README.md README.zh.md .agents/skills apps/user-docs/src
   ```

4. Update the [ADR index](../adr/README.md): add the new row, and set the old row's Status to a short phrase such as `Superseded by 0017` or `Accepted; amended by 0017`.
5. If the change alters a contract, update the spec, schema and tests in the same commit (AGENTS.md section 7).

## Specs

Specs are edited in place; git history is the record of earlier text. The `-vN` suffix tracks the contract version the spec describes (the schema `$id`, `DIST_ABI_V1`). A change of contract version is recorded by an ADR, and the spec file is renamed in that same change.

## Roadmap and acceptance plan

- When a phase closes, the next phase starts a new file (`roadmap-v0.2.md`). The old file gets one line at the top saying it is historical and linking to the new file, and is not edited again.
- Acceptance IDs are never reused. An ID that moves to the next plan keeps its number; a dropped ID stays in the old plan with its last status.

## Maintainer and user documentation

`docs/` is for Niobium maintainers; `apps/user-docs` is for people who build installers with Niobium ([ADR-0015](../adr/0015-node-toolchain-for-user-docs.md)). When both need the same topic, one owns the content and the other links to it, as [ADR-0014](../adr/0014-tier-based-platform-support.md) does for platform tiers: the ADR holds the obligations, the user site holds the current assignment. `README.zh.md` tracks `README.md` (AGENTS.md section 1), and the site's Chinese pages track its English pages ([ADR-0017](../adr/0017-chinese-user-documentation.md)).

The feature roadmap follows the same split. The user site's [Roadmap](../../apps/user-docs/src/content/docs/roadmap.md) page owns the single feature table: the wording of each feature and its status mark (✅ available, 🚧 now, 🔜 next, 🗓️ later, ⛔ not planned). The current `roadmap-v0.x.md` maps each item to its work and records. Both READMEs carry the same table with the status and feature name only. A feature changes status on the Roadmap page, in both READMEs and in `roadmap-v0.x.md` in the same commit. When a feature ships, its mark becomes ✅ and its acceptance entries appear on [Status and platforms](../../apps/user-docs/src/content/docs/status.md).

## Cleanup pass

Run when a phase closes or before a release. It is a checklist, not a gate.

- [ ] References to Superseded ADRs: for each one, run the search in step 3 above.
- [ ] `DEFERRED`, `NOT_RUN` and `BLOCKED` rows in the acceptance plan still have a current reason.
- [ ] `architecture/` pages still match the code they describe.
- [ ] `README.zh.md` matches `README.md`.
- [ ] The user site's Chinese pages say the same as their English pages.
- [ ] The [docs index](../README.md) lists every page in `docs/`.
