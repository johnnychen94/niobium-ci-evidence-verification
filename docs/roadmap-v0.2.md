# Roadmap v0.2 (adoptable by a product team)

Goal: turn the model proven in [v0.1](roadmap-v0.1.md) into something a product team can adopt. Every feature lives in one built-in module, a product developer gets from nothing to a signed installer quickly, and the Tier 1 platforms have real-OS evidence.

The user-facing wording of each item is owned by the [Roadmap](../apps/user-docs/src/content/docs/roadmap.md) page of the user site; this file maps those items to work and records. Items are in priority order. Feature modules come first because integrations, in-app updates and presets build on them; the production-readiness lanes run in parallel.

## Scope

| User roadmap item | Maintainer work | Record |
|---|---|---|
| Built-in feature modules | One module interface for capabilities and distribution features: schema fragment, validation, planner, per-platform backend, undo and uninstall, helper operation, conformance cases. Port ManagedFiles, Directory, Shortcut, FileAssociation, Service and ApplicationRegistration, then online and offline sources and channels | [ADR-0018](adr/0018-built-in-feature-modules.md) (Proposed) |
| Presets and themes | Versioned preset data and a scaffold command that writes ordinary `product.json`, `component.json` and branding files; a closed set of installer themes on the token pipeline; preview of the installer window before publishing | [ADR-0019](adr/0019-presets-and-themes.md) (Proposed), [ADR-0008](adr/0008-shared-software-renderer.md), [ADR-0009](adr/0009-zon-screen-ir-and-tokens-codegen.md) |
| Production-ready on macOS, Windows and Linux | Tier 1 real-OS lanes (x86_64 Ubuntu 24.04 guest, native x64 Windows 11), machine-scope smoke, the macOS GUI walkthrough, a pinned minimum macOS version, Authenticode and Developer ID signing with notarization | [ADR-0014](adr/0014-tier-based-platform-support.md), [vm-smoke](runbooks/vm-smoke.md), [release-signing](runbooks/release-signing.md) |
| Easier to adopt | Prebuilt `setup`, `nbpack` and `libdistribution` for the Tier 1 targets, built once and signed once; a compatibility promise for the build API | ADR to be written |
| More system integrations | ProtocolHandler and EnvironmentEntry (including `PATH`) as feature modules, with removal on uninstall and conformance cases on every Tier 1 backend | ADR-0018, [platform-contract-v1](spec/platform-contract-v1.md), source v0.1 section 7 |
| In-app updates for any application | The Node-API package `distribution.node` over the existing engine; examples of the C ABI from other languages | [ADR-0002](adr/0002-library-first-core-and-c-abi.md), [abi-v1](spec/abi-v1.md) |
| Online, offline-file and SFX delivery | Three delivery milestones with a shared engine; settle container layouts, final signing, antivirus gates, resource budgets, offline validity and maintainer lifetime | [ADR-0020](adr/0020-distribution-delivery-milestones.md), [distribution backlog](development/distribution-backlog.md) |

## Carried forward from v0.1

These acceptance entries keep their IDs and belong to the production-readiness item:

| ID | Status in v0.1 | What closes it |
|---|---|---|
| N1-UJ-02 | `BLOCKED` | A machine-scope run in `tools/vm-smoke` on a running VM |
| N1-UJ-10 | `NOT_RUN` | The manual macOS walkthrough of the five screens |
| N1-AC-18 | `BLOCKED` | vm-smoke on Windows 11 |
| N1-AC-19 | `BLOCKED` | vm-smoke on Ubuntu 24.04 ARM64 |

Outstanding maintainer task: host the upstream files from `deps.zon` on a self-hosted mirror so a first build no longer depends on GitHub or jsDelivr ([ADR-0011](adr/0011-third-party-fetch.md)).

## Acceptance

[acceptance-plan-v0.1](acceptance-plan-v0.1.md) stays the active acceptance file, and `tools/check-docs` keeps reading it through `acceptance_path`. `acceptance-plan-v0.2.md` opens when the first v0.2 spec defines new acceptance IDs: in that change, `acceptance_path` switches to the new file, the entries above move with their numbers, and the v0.1 plan is frozen ([docs-management](development/docs-management.md#roadmap-and-acceptance-plan)).

## Deferred (DEFERRED)

| Item | User roadmap | Record |
|---|---|---|
| Signed release notes shown in the installer and update prompt | Next | Feature module, to be specified |
| AutoStart capability | Next | Source v0.1, section 7 |
| Root and online key rotation in `nbpack` | Next | [Sign and manage keys](../apps/user-docs/src/content/docs/guides/sign-and-keys.md) |
| Security policy with a private reporting channel | Next | [Security](../apps/user-docs/src/content/docs/security.md) |
| UIA / NSAccessibility / AT-SPI bridges | Later | [ADR-0008](adr/0008-shared-software-renderer.md) |
| Linux native folder picker | Later | [ui-ir-v1](spec/ui-ir-v1.md) fallback |
| Localized installer UI | Later | To be specified |
| `aarch64-windows`, Kylin and UOS | Later | [Platform support](../apps/user-docs/src/content/docs/platforms.md) |
| Native Wayland backend | Not planned | [ADR-0010](adr/0010-x11-now-wayland-deferred.md) |
| External compatibility lab | Maintainer only | Source v0.2, section 2 |
| TLA+ model | Maintainer only | [ADR-0012](adr/0012-formal-methods-deferred.md) |
| ZLint / zlinter integration | Maintainer only | [tooling-and-rules](development/tooling-and-rules.md) |
