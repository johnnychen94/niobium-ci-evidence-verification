# Directory and owner rules

- `apps/<name>/main.zig`: only argument parsing, dependency injection and process assembly.
- `apps/user-docs/`: the user documentation site (Astro Starlight on Node.js, [ADR-0015](../adr/0015-node-toolchain-for-user-docs.md)), the only non-Zig app. Pages are in `src/content/docs/`, with their Chinese mirror in `src/content/docs/zh/` ([ADR-0017](../adr/0017-chinese-user-documentation.md)); it is excluded from the Zig package in `build.zig.zon` and never built by `zig build`.
- `libs/<module>/root.zig`: the module's public entry point; only `pub` declarations in `root.zig` are visible to other modules. A module's internal files and their tests live in the same directory.
- `libs/ui/kit/<component>/`: one directory per component, containing the implementation and tests.
- `api/schema/*.schema.json`: JSON Schema; must use `additionalProperties: false` and must not contain forbidden fields.
- `tools/<tool>/main.zig`: build-time tools; may only be invoked by Run steps in `build/`, and production modules must not depend on them.
- `tests/e2e/`, `tests/conformance/`, `tests/golden/`, `tests/fixtures/`, `tests/fuzz/`: cross-module tests and data; single-module unit tests stay inside the module.
- `examples/<name>/`: standalone Zig packages that depend on this repository by path and use Niobium only through the public build API (`build/sdk.zig`), the same way an external product repository does ([consuming](consuming.md)).
- `third_party/deps.zon`: the single manifest of upstream URLs and sha256; `third_party/<lib>/` holds only `PROVENANCE.md`, `bindings.zig`, our own glue source and `patches/*.patch`. Upstream files are fetched by `zig build` into the build cache and are not committed ([ADR-0011](../adr/0011-third-party-fetch.md)).
- `shared/`, `common/`, `utils/`, `helpers/` directories are forbidden; shared code must find a semantic owner.
- Generated files are written to the build cache and are not committed.
