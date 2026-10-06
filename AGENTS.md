# Niobium development conventions

Niobium is a native, declarative, transactional installation and distribution framework written in Zig. This file holds the repository's hard constraints, forbidden patterns and review gates. Procedures live in `.agents/skills/`; contracts and trade-offs live in `docs/spec/` and `docs/adr/`. A requirement is stated once and linked, never copied in full to several places.

## 1. Rule precedence and sources of truth

Current explicit user instruction > this file > accepted ADRs > versioned specs (`docs/spec/*-v1.md`) > architecture baseline (`docs/source/`) > general engineering practice. When you find a conflict, pause the affected change and record the conflict and a proposed ADR first; never change architectural semantics silently through code.

- `docs/source/` is the original architecture input, a read-only archive; current decisions are the ADRs and specs.
- `docs/implementation/YYYY-MM-DD-*.md` are implementation traces; they go stale and are not a source of truth.
- Docs, skills, code comments and commit summaries are written in English. [README.zh.md](README.zh.md) is the only Chinese document and must track [README.md](README.md). APIs, code identifiers and JSON fields are English.
- The repository is public. It must not reference internal or private hosts, mirrors or organizations; `tools/check-docs` enforces part of this.

## 2. Inviolable principles

The six architecture principles (from section 2 of `docs/source/architecture-v0.1.md`):

1. **Manifest is data, never code.** There is no shell, PowerShell, script, `exec()` or any generic command field.
2. **Desired state, not execution steps.**
3. **Installer owns machine deployment; application owns application semantics.** Business migration belongs to App Bootstrap.
4. **Privilege is capability-based.** The elevated helper accepts only closed typed operations.
5. **Installation is transactional.** After a crash at any moment, recovery reaches only old-good or new-good.
6. **The framework is intentionally non-extensible at runtime.** No plugins, no script hooks, no custom DLL hooks.

The five mantras (from v0.2):

1. Distribution Core is a library, not an updater executable.
2. Artifacts are immutable native objects; Portable Artifact is a first-class deployment model.
3. Installation metadata describes state, never executable scripts.
4. TUF authorizes releases; platform signatures establish OS-level publisher trust.
5. Build once, sign once, test the final bytes, then promote by metadata only.

## 3. Repository boundaries and dependency direction

```text
apps/ process assembly (setup, nbpack, libdistribution, ui-workbench), no business logic
libs/ implementation; one owner directory per module
api/ machine-readable contracts (JSON Schema, C header)
tools/ checks, generators and gates written in Zig
tests/ cross-module e2e, conformance, golden, fixtures
build/ the single source of truth for the build graph: modules.zig declares modules and allowed imports
third_party/ upstream sources pinned by deps.zon + PROVENANCE + patches + bindings; upstream files are fetched at build time, not committed
```

Dependencies only point downward: `apps → engine → {resolver, planner, transaction, privilege, bootstrap, portable} → {trust, repository, package, executor} → platform/api → contracts → core`. `ui/core` and `ui/kit` must not import `engine` or `platform`; `ui/screens` talks to the engine only through the `contracts` ViewModel; platform backends are injected only by `apps/*`.

A module may only `@import` the modules `build/modules.zig` hands it, which the compiler enforces; `tools/check` additionally rejects relative `@import("../...")` across module directories. Do not create `shared/`, `common/`, `utils/` or `helpers/` grab-bag directories.

## 4. Starting a task

1. Read this file, then [docs/README.md](docs/README.md) to locate the relevant specs and ADRs.
2. For any design, implementation, debugging or acceptance work: read [.agents/skills/niobium-development/SKILL.md](.agents/skills/niobium-development/SKILL.md).
3. For writing or changing Zig code: read the `zig-0.17` and `zig-tiger-style` skills (under `.agents/skills/`); this repository's deviations are in section 5.
4. For installer UI, tokens, components and screens: read [niobium-ui-kit](.agents/skills/niobium-ui-kit/SKILL.md) and [niobium-native-look](.agents/skills/niobium-native-look/SKILL.md).
5. For a new OS capability or platform backend: read [niobium-platform-capability](.agents/skills/niobium-platform-capability/SKILL.md).
6. For review, security or boundary-related changes: review against the [review-niobium](.agents/skills/review-niobium/SKILL.md) checklist.
7. External GUI skills (`apple-hig`, `winui-app`, `gtk-ui-ux-engineer`) only provide design values and checklists; the SwiftUI/AppKit controls, WinUI 3/XAML/C#/MSIX and GTK/libadwaita they recommend do not change [ADR-0008](docs/adr/0008-shared-software-renderer.md).

## 5. Zig rules

- Zig is pinned to 0.17.0 (`minimum_zig_version` in `build.zig.zon`). Use the `std.process.Init` main and an explicitly passed `std.Io`.
- Pass `Allocator` and `Io` explicitly; in `libs/`, container-level mutable `var`, `std.heap.page_allocator` and `c_allocator` are forbidden.
- Public functions use explicit error sets; `anyerror` is forbidden. Expected failures (IO, parsing, network, disk full, file locks, UAC cancel, timeouts) are always errors, never panics; panic/assert only express programmer invariants.
- Use `std.math.cast` for untrusted integers, not `@intCast`/`@truncate`; on untrusted data, `catch unreachable`, `orelse unreachable`, empty `catch {}` and `_ = call()` discards are forbidden.
- Every loop, queue and retry has a fixed upper bound; input sizes are bounded by `contracts.Limits`.
- The C ABI boundary exposes no Zig structs, allocators, error unions or slices; every `export fn` maps errors to status codes.
- Follow TigerStyle, with these deviations: function names keep Zig std camelCase; function bodies ≤ 70 lines and lines ≤ 100 columns; non-trivial functions in core modules have at least one entry assertion; compound assertions are split.
- `@cImport` was removed in 0.17: C dependencies use hand-written `extern` declarations in `third_party/<lib>/bindings.zig`.
- Release builds are ReleaseSafe; `@setRuntimeSafety(false)` is allowed only in small, fuzzed hot loops on the lint allowlist.

## 6. Tests, acceptance and gates

Test lanes: L0 static (check/lint/schema/size), L1 pure core (VirtualPlatform), L2 faults and security (crash injection, sim, fuzz, malicious input), L3 platform contract, L4 scenario e2e, L5 real OS (vm-smoke). Details: [docs/development/testing-lanes.md](docs/development/testing-lanes.md).

- Crash-injection invariant: after recovery from any kill point, `Active == OLD` or `Active == NEW`, never MIXED.
- No artifact can write outside the staging root through extraction.
- Acceptance status uses only `PASS`/`FAIL`/`BLOCKED`/`NOT_RUN`/`DEFERRED`; without real evidence, never write "supported" or "passed".
- Compiling, mocks succeeding, screenshots and an agent's own claims do not constitute completion. Evidence goes to `.evidence/<suite>/<UTC>/`.
- Goldens are never updated wholesale: `zig build golden -Dupdate=<component>` must name a scope, and the diff is inspected in review.

## 7. Changes, commits and definition of done

- Commits: `<type>(<scope>): summary` with an English summary, type ∈ `feat|fix|test|docs|refactor|chore|adr|build`.
- Hand-written patches target ≤ 300 net lines; more needs splitting or a stated reason. Hand-written files ≤ 600 lines (generated files, fixtures and third_party excepted).
- Never get a pass by disabling rules, widening ignores, deleting regression cases or updating snapshots wholesale; `// lint-allow(<rule>): <reason>` must state a reason, and the count is reported.
- When the same class of problem appears a second time, it must become a failing check: write the failing case first, then implement.
- Definition of done: implementation, contracts, docs and acceptance IDs are in sync; relevant tests have run; `zig build verify` passes or the blocker is recorded explicitly. The final report states the actual commands, results, what was not run and limitations.

## 8. Repository skills

| Skill | Purpose |
|---|---|
| `niobium-development` | Design → contract → implement → verify → deliver main loop, with the anti-pattern table |
| `niobium-ui-kit` | Installer UI components, tokens, screens and goldens |
| `niobium-native-look` | Map each platform's look and interaction conventions to tokens |
| `niobium-platform-capability` | Contract-first flow and crash pitfalls for new capabilities / platform backends |
| `review-niobium` | Security and boundary review checklist |
| `zig-0.17`, `zig-tiger-style` | External Zig language skills (pinned by `skills-lock.json`) |
| `apple-hig`, `winui-app`, `gtk-ui-ux-engineer` | External platform design references (values and checklists only); sources in [docs/development/tooling-and-rules.md](docs/development/tooling-and-rules.md#external-skills) |
