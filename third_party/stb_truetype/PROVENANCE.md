# stb_truetype provenance

Upstream files are not committed: `zig build` fetches them according to [`deps.zon`](../deps.zon) and verifies sha256 ([ADR-0011](../../docs/adr/0011-third-party-fetch.md)). This table must match `deps.zon`.

| Field | Value |
|---|---|
| Upstream | https://github.com/nothings/stb |
| Files | `stb_truetype.h`, `LICENSE` |
| Version | v1.26 (as stated in the file header), commit `2c980bb59875b0d32144a71867fbdebb2f77cd20` |
| Fetched from | `https://raw.githubusercontent.com/nothings/stb/<commit>/{stb_truetype.h,LICENSE}` |
| Pinned on | 2026-10-07 |
| sha256 stb_truetype.h | `ecd30b05e0dd4fea3a13c26810dd9e1992dc379049482c393d5a19e6b5090aab` |
| sha256 LICENSE | `bebfe904b14301657e4e5d655c811d51fd31b97c455b9cc2d8600d6bac6cff63` |
| License | MIT or Public Domain (dual-licensed, the fetched `LICENSE`) |
| Local modifications | None. `stb_truetype_impl.c` uses macros to reroute all libc hooks to functions exported by `bindings.zig`, so the target artifacts do not depend on libc. |

## Usage constraints

- Used only for glyph rasterization in `libs/ui/render`.
- stb's memory comes from `bindings.Scratch` (a fixed buffer), reset before each glyph; allocation failure returns NULL.
- The v2 rasterizer uses a stack buffer when the glyph width is ≤ 128 px, so the paths that do not check the malloc result are never triggered; `libs/ui/render` clamps the font size to at most 96 px.
- To upgrade: change the commit and sha256 in `deps.zon`, update this table, and run `zig build test` and `zig build golden`.
