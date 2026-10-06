# ADR-0001: Repository baseline and Zig-only toolchain

- **Status:** Accepted
- **Date:** 2026-10-07

## Context

The source architecture requires an installer that is small, auditable and built cross-platform. A multi-language toolchain widens the build surface and the supply-chain risk.

## Decision

- Product code, the build graph, code generation, checks, lint, tests and the VM smoke driver are all written in Zig 0.17.0; the single entry point is `zig build <step>`.
- C dependencies (stb_truetype, libzstd) are built by Zig's bundled C compiler and used through hand-written `extern` bindings (`@cImport` has been removed).
- Windows resources are compiled by a `zig rc` Run step.
- Directory layers: `apps/`, `libs/`, `api/`, `tools/`, `tests/`, `build/`, `third_party/`, `docs/`.
- Allowed non-language tools: OS vendor signing tools (codesign, notarytool, hdiutil, signtool) and Parallels `prlctl`. Agent skills are installed with `npx skills`, which never enters the product build.

## Consequences

- A new contributor only needs Zig 0.17.0.
- The Node-API addon and TLA+ models (both deferred) would bring in Node.js / Java and will need a new ADR.
