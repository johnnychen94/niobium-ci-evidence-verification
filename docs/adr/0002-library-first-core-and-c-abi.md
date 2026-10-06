# ADR-0002: Library-first core and C ABI

- **Status:** Accepted
- **Date:** 2026-10-07

## Context

Sections 13-15 of source architecture v0.2 require the Distribution Core to be a library rather than an updater executable, and external consumers must not depend on the Zig ABI.

## Decision

- `libs/engine` is the only install/update orchestration facade; the GUI and CLI of `apps/setup` are both frontends of it.
- `apps/libdistribution` exports a C ABI: `dist_get_api(DIST_ABI_V1, &table)` returns a versioned function table. Only opaque handles, fixed-width integers, byte buffers, versioned structs and callback tables are exposed.
- The header `api/c/distribution.h` is the public contract; any incompatible change must bump the ABI version.
- v0.1 implements the Installer and Portable Run profiles; the Node-API `distribution.node` is deferred.

## Consequences

- The GUI and CLI cannot carry two copies of the install logic.
- A C smoke test compiled with `zig cc` is the evidence for the ABI contract.
