# ADR-0018: Built-in feature modules

- **Status:** Proposed
- **Date:** 2026-10-07

## Context

Adding one OS integration today touches many owners at once: manifest decoding and validation (`libs/manifest`), the shared contracts (`libs/contracts`), the planner (`libs/planner`), every platform backend (`libs/platform/macos.zig`, `windows.zig`, `linux.zig`), the elevated helper's operations and the conformance suite (`libs/conformance`). The distribution features (online and offline sources, channels) are woven through the engine in the same way.

The v0.2 roadmap adds link handlers, environment entries, signed release notes and in-app updates, and later AutoStart. At the current cost per feature, that list does not fit the time of one maintainer. A plugin mechanism was considered and rejected: runtime plugins, scripts and product-authored extensions would break principles 1 and 6 in AGENTS.md section 2, and the closed operation set of the elevated helper ([ADR-0007](0007-same-binary-privilege-helper.md)).

## Decision

Proposed:

- Every capability and every distribution feature is a **feature module**: one owner directory that holds everything the feature needs:
  - its closed manifest or component schema fragment, decoded through `contracts.json.decodeStrict`;
  - its semantic validation;
  - its planner contribution, which emits typed operations;
  - a backend for each Tier 1 target, or an explicit typed "unsupported on this platform" error;
  - the inverse of each operation, used by rollback, repair and uninstall;
  - the typed helper operations it needs, specified in [ipc-v1](../spec/ipc-v1.md);
  - its conformance and crash-injection cases.
- The set of modules is fixed at compile time in this repository and declared in `build/modules.zig`. Nothing is discovered or loaded at run time, and no module is written outside Niobium. Products select and configure modules through manifest data only.
- Each module has its own section in the relevant spec and goes through the [review-niobium](../../.agents/skills/review-niobium/SKILL.md) checklist like any other change to the security surface.
- The existing six capabilities move into modules without changing the manifest-v1 wire format. New capabilities (ProtocolHandler, EnvironmentEntry, AutoStart) are written as modules from the start.

Open questions, to settle before this ADR is accepted:

- Can a product config select which modules are compiled into its `setup`? That would reduce size and audit surface. Or does every `setup` carry all modules?
- Where do module directories sit in the dependency direction of AGENTS.md section 3, and which modules may each one import?
- Do distribution features (sources, channels, release notes) share the capability interface, or get a second, narrower one?

## Consequences

- Adding an integration becomes one module, one spec section and its tests. Each new helper operation is still a reviewed addition to a closed set.
- Moving the existing capabilities is a large code move. It is split into patches within the size limit of AGENTS.md section 7, one capability at a time, with the e2e and crash-injection suites passing after each.
- The user-visible model does not change: the manifest stays data, and `setup` loads nothing that is not built into it.
