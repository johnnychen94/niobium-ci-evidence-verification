# Roadmap v0.1 (MVP vertical slice)

Goal: prove that **native GUI ≤ 30 MiB + transactional engine + no-script component model** holds.

## Scope

| Area | v0.1 |
|---|---|
| Target platforms | `x86_64-windows`, `aarch64-macos`, `x86_64-linux` (plus `aarch64-linux` built for VM smoke) |
| Scope | user + machine |
| Capability | ManagedFiles, Directory, Shortcut, FileAssociation, Service, ApplicationRegistration |
| Frontends | GUI (Welcome, Options, Progress, Error, Complete) + CLI + C ABI |
| Distribution | online (HTTP) + offline (directory bundle) |
| Trust | TUF profile v1 |
| Operations | install / update / repair / uninstall; Portable Run |
| Application contract | App Bootstrap v1 |
| Reliability | transaction recovery, crash injection, seeded sim |

## Deferred (DEFERRED)

| Item | Record |
|---|---|
| Native Wayland backend | [ADR-0010](adr/0010-x11-now-wayland-deferred.md) |
| UIA / NSAccessibility / AT-SPI bridges (SemanticTree is already generated and tested) | [ADR-0008](adr/0008-shared-software-renderer.md) |
| Linux native folder picker | [ui-ir-v1](spec/ui-ir-v1.md) fallback |
| Real Authenticode / Developer ID signing and notarization | [release-signing](runbooks/release-signing.md) |
| Node-API `distribution.node` | [ADR-0002](adr/0002-library-first-core-and-c-abi.md) |
| External compatibility lab | Source v0.2, section 2 |
| ProtocolHandler, AutoStart, EnvironmentEntry capabilities | Source v0.1, section 7 |
| TLA+ model | [ADR-0012](adr/0012-formal-methods-deferred.md) |
| GitLab CI | Later phase |
| ZLint / zlinter integration | [tooling-and-rules](development/tooling-and-rules.md) |

## Outstanding tasks

| Item | Record |
|---|---|
| third_party mirror: host the upstream files from `deps.zon` on a self-hosted mirror so a first build no longer depends on GitHub / jsDelivr | [ADR-0011](adr/0011-third-party-fetch.md) |
