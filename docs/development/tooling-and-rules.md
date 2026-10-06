# Checks, lint and rule iteration

All checks are Zig programs, driven by `zig build check`.

| Tool | Checks |
|---|---|
| `zig fmt --check`, `zig ast-check` | Formatting and syntax |
| `tools/lint` | TigerStyle, crash safety, boundary rules (see below) |
| `tools/check` | Module graph matches the allow table, no cross-module relative imports, files ≤ 600 lines, schema rules, catalog golden complete |
| `tools/check-docs` | Links resolve (relative paths, user-site routes, `github.com/niobium-project/niobium` file URLs), URL hosts allowlisted, English only outside the Chinese paths of ADR-0017, user-site locale mirror, ADR fields complete, acceptance IDs consistent, spec file names versioned |
| `tools/check-binary` | Dynamic dependency allowlist, PE security flags, no RWX segments, size gate |
| `tools/check-commits` | `<type>(<scope>): summary` |
| `zig fmt --complexity` | Per-file token/node baseline; growth > 10% requires updating the baseline in the same commit |

## tools/lint rules

| Rule | Level |
|---|---|
| `fn-length`: function body ≤ 70 lines | error |
| `line-length`: ≤ 100 columns | error |
| `no-recursion`: a function calls itself directly | error |
| `bounded-loop`: `while (true)` needs a `// loop-bound:` explanation | error |
| `split-assert`: `assert(a and b)` | error |
| `no-catch-unreachable`, `no-orelse-unreachable` (non-test) | error |
| `no-empty-catch`, `no-discard-call` (`_ = f(...)`) | error |
| `panic-owner`: `@panic` only in `core/assert.zig` and the panic handler | error |
| `parser-int-cast`: `@intCast`/`@truncate` in parser modules | error |
| `undefined-safety`: `= undefined` needs `// SAFETY:` | error |
| `runtime-safety-allowlist`: `@setRuntimeSafety(false)` | error |
| `spawn-allowlist`, `ptr-cast-allowlist` | error |
| `no-global-var`, `no-page-allocator` (libs/) | error |
| `no-anyerror-pub`, `no-usize-contracts`, `no-debug-print`, `no-sleep-in-tests` | error |

Suppression: `// lint-allow(<rule>): <reason>`, the reason is required; `tools/lint` reports the total number of suppressions.

## Rule iteration

When the same kind of problem appears a second time: first write a fixture case that can fail, then add the rule to `tools/lint` or `tools/check` and register it in this table. False positives are fixed by correcting the rule, not by widening ignores.

## User documentation site

`apps/user-docs` is the one place Node.js is used ([ADR-0015](../adr/0015-node-toolchain-for-user-docs.md)): an Astro Starlight site deployed to https://niobium-project.dev by `.github/workflows/user-docs.yml`. Build it locally with `npm ci && npm run build` in that directory; the build fails on broken internal links and anchors in both locales. `npm run build:versions` assembles every published version (`/next/`, `/vX.Y/`, `/latest/`) into `dist-versions/` from git tags `vX.Y.Z`, as the deploy does; see the [site README](../../apps/user-docs/README.md). `zig build` never runs it.

`tools/check-docs` also covers the site: `.md`/`.mdx` pages, `.astro`/`.mjs`/`.ts`/`.yml` sources and the workflow are scanned for hosts, and in `package-lock.json` only the `resolved` download URLs are checked. Site pages link to each other by root-relative routes with a trailing slash (`/guides/package/`), which resolve against `apps/user-docs/src/content/docs`, and to repository files by `https://github.com/niobium-project/niobium/blob/main/<path>` (or `tree/main/` for directories), which must exist in the working tree. All repository walkers skip `node_modules`, `apps/user-docs/dist`, `apps/user-docs/dist-versions` and `apps/user-docs/.astro`.

The language rule ([ADR-0017](../adr/0017-chinese-user-documentation.md)) is in `tools/check-docs/locales.zig`. Markdown files and every text file under `apps/user-docs/` must be free of CJK text, except `README.zh.md`, `apps/user-docs/src/content/docs/zh/`, `apps/user-docs/src/content/i18n/zh-CN.json` and the term table in `apps/user-docs/README.md`. Every English page needs a Chinese page at the same path under `zh/` and the reverse, and a site page may not link to a route in the other locale.

## External linters

ZLint (v0.10.0 targets Zig 0.16) and zlinter (0.17 port in progress) are marked DEFERRED until they can build on 0.17; their key rules are already covered by `tools/lint`.

## External skills

External skills are installed into `.agents/skills/` and `.claude/skills/` with `npx skills add <repo> --skill <name> -a cursor -a claude-code --copy`, and their version hashes are pinned in `skills-lock.json`. Restore: `npx skills experimental_install`.

| Skill | Source | Purpose |
|---|---|---|
| `zig-0.17` | `zigcc/skills` | Zig 0.17 API and migration notes |
| `zig-tiger-style` | `zigcc/skills` | TigerStyle (this repository's deviations are in AGENTS.md section 5) |
| `apple-hig` | `justinwetch/higagentskills` | macOS values and interaction conventions |
| `winui-app` | `openai/skills` | Windows 11 / Fluent values and interaction conventions |
| `gtk-ui-ux-engineer` | `gotar/opencode-config` | GNOME HIG / libadwaita values and interaction conventions |

When GitHub is not directly reachable, you can temporarily point git at a mirror with a URL rewrite (`GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0='url.<mirror>/https://github.com/.insteadOf' GIT_CONFIG_VALUE_0='https://github.com/'`); the sources in `skills-lock.json` stay recorded as GitHub repositories.

External GUI skills only provide values and checklists and do not change [ADR-0008](../adr/0008-shared-software-renderer.md): no SwiftUI, XAML, GTK or C# dependencies are introduced. Values land in `platforms.*` of `libs/ui/tokens/tokens.json`; the mapping rules are in the `niobium-native-look` skill.
