# zstd provenance

Upstream files are not committed: `zig build` fetches them according to [`deps.zon`](../deps.zon) and verifies sha256 ([ADR-0011](../../docs/adr/0011-third-party-fetch.md)). This table must match `deps.zon`.

| Field | Value |
|---|---|
| Upstream | https://github.com/facebook/zstd |
| Version | v1.5.7 |
| Pinned on | 2026-10-07 |
| Fetched from | `https://codeload.github.com/facebook/zstd/tar.gz/refs/tags/v1.5.7` |
| tarball sha256 | `37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3` |
| License | BSD-3-Clause (the fetched `LICENSE`; upstream also offers GPLv2, we choose BSD) |
| Extracted | `LICENSE`, `lib/common/`, `lib/compress/`, `lib/zstd.h`, `lib/zstd_errors.h` (`extract` in `deps.zon`) |
| Not extracted | Decompressor, dictionary builder, legacy, CLI, tests, build scripts |
| Local modifications | None |

## Usage constraints

- Linked only into `nbpack` (`libs/packager`). `setup` and `libdistribution` decompress at runtime with `std.compress.zstd`, and `tools/check-binary` checks that runtime artifacts contain no `ZSTD_` symbols.
- Compile macros: `ZSTD_MULTITHREAD` undefined; `ZSTD_TRACE=0`; `ZSTD_LEGACY_SUPPORT=0`; `XXH_NAMESPACE=ZSTD_`.
- The frame window `windowLog` is fixed at 23 (8 MiB), matching `std.compress.zstd.default_window_len`.
