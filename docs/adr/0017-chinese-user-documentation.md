# ADR-0017: Chinese user documentation

- **Status:** Accepted
- **Date:** 2026-10-07
- **Amends:** [ADR-0015](0015-node-toolchain-for-user-docs.md) (the language rule `tools/check-docs` applies to the site)

## Context

AGENTS.md section 1 makes every document English except `README.zh.md`, and `tools/check-docs` rejects CJK text elsewhere. Many people who build installers with Niobium read Chinese more easily than English, and the user documentation site ([ADR-0015](0015-node-toolchain-for-user-docs.md)) is where they look for how to use it. Maintainer documentation, code, specs and skills have a different audience and gain nothing from a second language, while each translated file is one more place that can drift.

## Decision

- The user documentation site has two locales: English at the site root and Simplified Chinese (`zh-CN`) under `/zh/`. English is the source; Chinese is a translation of it. The site does not redirect by browser language.
- Chinese text is allowed in exactly these paths, and `tools/check-docs` keeps rejecting CJK everywhere else:
  - `README.zh.md`;
  - `apps/user-docs/src/content/docs/zh/`;
  - `apps/user-docs/src/content/i18n/zh-CN.json` (sidebar, version switcher and banner strings);
  - `apps/user-docs/README.md`, for its English-Chinese term table.
- Every English page has a Chinese page at the same path under `zh/`, and every Chinese page has an English page. `tools/check-docs` fails on a missing counterpart in either direction, so a new or removed English page lands together with its translation.
- A link from a page to a site route stays in that page's locale: English pages link to `/...`, Chinese pages to `/zh/...`. `tools/check-docs` fails on a cross-locale route link, and the Astro build validates links in both locales.
- Code, commands, identifiers, file paths, JSON fields, error names and the status words `PASS`, `FAIL`, `BLOCKED`, `NOT_RUN` and `DEFERRED` stay in English inside Chinese pages. Chinese headings that are link targets carry the English heading ID (`## <Chinese heading> { #english-id }`), so anchors are the same in both locales.
- A Chinese page never states more than its English page. When they disagree, the English page is correct and the Chinese page is fixed.
- The machine-readable `llms.txt` files are generated from the English pages only.

## Consequences

- Every change to an English page needs a matching change to its Chinese page; the mirror check catches added or removed pages, not stale wording, which is found in review.
- Contributors who do not read Chinese can still change English pages, but they must add or remove the Chinese file as well, and someone who reads Chinese should update its text.
- The term table in `apps/user-docs/README.md` keeps translations of project terms consistent.
- AGENTS.md section 1 now names the site's Chinese pages as the second exception to the English rule.
