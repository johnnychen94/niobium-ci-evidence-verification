# ADR-0011: Versioned third-party fetch and patches

- **Status:** Accepted
- **Date:** 2026-10-07

## Context

The build needs a few upstream C sources and a font (stb_truetype, the libzstd compression subset, Inter). The repository does not commit external dependencies: about 2 MB of C sources and font binaries would make upgrade diffs unreviewable and mix local changes with upstream files. The build must still be reproducible and work offline.

Zig 0.17 `build.zig.zon` dependencies can only fetch archives; they cannot fetch single files or apply patches. The Inter static TTF is only distributed as a single file, and switching to another source would change the glyph data and every golden.

## Decision

- `third_party/deps.zon` is the single manifest. Each package lists `name`, `version`, a set of `sources` (`url` + `sha256`; archives add `archive`, `strip_components` and an `extract` prefix list, single files add `file`) and ordered `patches`.
- `zig build` runs `tools/fetch-deps` once per package (`build/steps/deps.zig`) and writes the output into the build cache:
  - downloads use `std.http.Client` and honor `HTTP(S)_PROXY`;
  - a sha256 mismatch fails the build;
  - raw downloads are cached by sha256 in `<Zig global cache>/niobium-deps/`, relocatable with `NIOBIUM_DEPS_CACHE`, so each pin is downloaded once per machine and later builds work offline;
  - only entries listed in `extract` are unpacked; absolute paths, `..` and backslash paths are rejected;
  - `third_party/<name>/patches/*.patch` are applied strictly in manifest order (unified diff; context must match line for line, no fuzz).
- The Run step's cache key is the manifest plus the patch files. Changing a pin or a patch refetches; other changes do not.
- The repository keeps only files we wrote: `deps.zon`, `PROVENANCE.md`, `bindings.zig`, `stb_truetype_impl.c`, `patches/`. Upstream files are not committed.
- Pinned packages: stb_truetype (commit `2c980bb5`), libzstd 1.5.7 compression subset, Inter 4.1 (the latin static TTF from fontsource 5.3.0).

## Consequences

- The first build on a new machine needs access to GitHub, codeload and jsDelivr; after that it works offline. A self-hosted mirror is tracked in the [roadmap](../roadmap-v0.1.md).
- Upgrading a dependency: change the URL and sha256 in `deps.zon`, update `PROVENANCE.md`, then run `zig build test`, `zig build golden` and fuzz.
- Local modifications exist only as patches, so review sees the diff directly; when an upstream change makes a patch mismatch, the build fails instead of drifting silently.
