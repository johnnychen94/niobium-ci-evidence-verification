# Inter font provenance

Upstream files are not committed: `zig build` fetches them according to [`deps.zon`](../deps.zon) and verifies sha256 ([ADR-0011](../../docs/adr/0011-third-party-fetch.md)). This table must match `deps.zon`.

| Field | Value |
|---|---|
| Upstream | https://github.com/rsms/inter (static TTFs distributed by fontsource) |
| Files | `Inter-Regular.ttf` (latin 400), `Inter-SemiBold.ttf` (latin 600) |
| Version | Inter 4.1, fontsource `@fontsource/inter` 5.3.0 |
| Fetched from | `https://cdn.jsdelivr.net/fontsource/fonts/inter@5.3.0/latin-{400,600}-normal.ttf`; license `https://raw.githubusercontent.com/rsms/inter/v4.1/LICENSE.txt` |
| Pinned on | 2026-10-07 |
| sha256 Regular | `7c7c718a62e315a83fb5b5b0b086028bae10fc153701cf0f0b168e5f5a0c28f9` |
| sha256 SemiBold | `fb6efb6500fe6531b73c7a06d025ceaefc562ee03e9d840c76d48ee11e85b998` |
| sha256 LICENSE.txt | `262481e844521b326f5ecd053e59b98c8b2da78c8ee1bdbb6e8174305e54935a` |
| License | SIL Open Font License 1.1 (the fetched `LICENSE.txt`) |
| Local modifications | None |

## Usage constraints

- Embedded into `libs/ui/render` via `@embedFile`; covers only the Latin subset.
- The MVP installer UI text is in English; CJK glyph fallback belongs to i18n and is deferred (see roadmap).
- The OFL requires distributing the license with the binary: offline bundles produced by `nbpack` copy `LICENSE.txt` to `licenses/Inter-OFL.txt`.
