# Documentation index

`docs/` holds maintainer documentation only: architecture, specifications, decisions, development process, runbooks and acceptance. The hard constraints live in the root [AGENTS.md](../AGENTS.md). Documentation for people who build installers with Niobium is the site at https://niobium-project.dev, built from [apps/user-docs](../apps/user-docs/README.md) ([ADR-0015](adr/0015-node-toolchain-for-user-docs.md)).

## Find by purpose

| Purpose | Document |
|---|---|
| Original architecture input (read-only) | [architecture-v0.1](source/architecture-v0.1.md), [architecture-v0.2](source/architecture-v0.2.md) |
| Current phase scope and deferred items | [roadmap-v0.2](roadmap-v0.2.md); previous phase [roadmap-v0.1](roadmap-v0.1.md) |
| Feature coverage boundary and candidate acceptance questions | [feature-coverage](feature-coverage.md) |
| Feature roadmap in user terms (user site) | [Roadmap](../apps/user-docs/src/content/docs/roadmap.md) |
| Platform tiers: maintainer obligations; current tiers and platform roadmap (user site) | [ADR-0014](adr/0014-tier-based-platform-support.md), [Platform support](../apps/user-docs/src/content/docs/platforms.md) |
| Acceptance IDs and actual status | [acceptance-plan-v0.1](acceptance-plan-v0.1.md) |
| Decision records | [adr/README.md](adr/README.md) |
| How each document kind changes and retires; replacing an ADR | [docs-management](development/docs-management.md) |
| Architecture overview and module boundaries | [overview](architecture/overview.md), [module-boundaries](architecture/module-boundaries.md) |
| Transactions, commit and recovery | [transaction-model](architecture/transaction-model.md) |
| UI engine | [ui-engine](architecture/ui-engine.md) |
| Directory and owner rules | [repository-layout](development/repository-layout.md) |
| Test lanes, evidence, and continuous integration | [testing-lanes](development/testing-lanes.md) |
| Checks, lint and rule iteration | [tooling-and-rules](development/tooling-and-rules.md) |
| UI component lifecycle | [ui-component-lifecycle](development/ui-component-lifecycle.md) |
| Commit conventions | [commits](development/commits.md) |
| Using Niobium from another repository (build API) | [consuming](development/consuming.md) |
| Online, offline-file and SFX design and verification tasks | [distribution backlog](development/distribution-backlog.md), [ADR-0020](adr/0020-distribution-delivery-milestones.md) |
| Release signing, key rotation, offline bundles, VM smoke | [runbooks/](runbooks/) |

## Specifications (normative)

| Contract | Specification | Machine contract |
|---|---|---|
| Product manifest | [manifest-v1](spec/manifest-v1.md) | `api/schema/manifest-v1.schema.json` |
| Component metadata and payload | [component-v1](spec/component-v1.md), [artifact-format-v1](spec/artifact-format-v1.md) | `api/schema/component-v1.schema.json` |
| TUF profile | [tuf-profile-v1](spec/tuf-profile-v1.md) | `api/schema/tuf-profile-v1.schema.json` |
| App Bootstrap | [bootstrap-v1](spec/bootstrap-v1.md) | `api/schema/bootstrap-v1.schema.json` |
| CLI and events | [cli-v1](spec/cli-v1.md) | `api/schema/cli-events-v1.schema.json` |
| Elevation IPC | [ipc-v1](spec/ipc-v1.md) | `api/schema/ipc-v1.schema.json` |
| C ABI | [abi-v1](spec/abi-v1.md) | `api/c/distribution.h` |
| UI IR | [ui-ir-v1](spec/ui-ir-v1.md) | `libs/ui/core` |
| Platform contract | [platform-contract-v1](spec/platform-contract-v1.md) | `libs/conformance` |

## Status vocabulary

`PASS`, `FAIL`, `BLOCKED`, `NOT_RUN`, `DEFERRED`. Without actual evidence, do not use "supported", "passed" or "production-ready". Implementation traces are optional, for large multi-commit changes only, and go in `implementation/YYYY-MM-DD-<topic>.md`; they go stale and are not the source of truth.
