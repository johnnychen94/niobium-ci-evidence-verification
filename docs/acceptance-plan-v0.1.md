# Acceptance plan v0.1

Status uses only `PASS`, `FAIL`, `BLOCKED`, `NOT_RUN`, `DEFERRED`. Every entry whose "Coverage" column is `zig test` must be cited by at least one test name (checked by `tools/check-docs`).

Basis for status: `zig build verify` passes on a macOS aarch64 host (covering all entries with `zig test` and `build` coverage), and the e2e suite also passes in a Debian bookworm arm64 container; e2e evidence is in `.evidence/e2e/<UTC>/`. The reason for the `BLOCKED` entries is in `.evidence/vm-smoke/<UTC>/summary.txt`: neither VM was running, and the tool does not start them without `--start` ([vm-smoke](runbooks/vm-smoke.md)). N1-UJ-02 additionally needs machine scope, while `tools/vm-smoke` currently runs only user scope. N1-UJ-10 is a manual item: on a macOS host, run `zig build example`, then open `zig-out/example/setup` and walk through all five screens.

## User journeys

| ID | Description | Coverage | Status |
|---|---|---|---|
| N1-UJ-01 | User-scope online install (HTTP repository); bootstrap is invoked | zig test | PASS |
| N1-UJ-02 | Administrator `install --silent --json --scope machine` | vm-smoke | BLOCKED |
| N1-UJ-03 | update to a higher release_sequence | zig test | PASS |
| N1-UJ-04 | Incident rollback release: a higher sequence points at an older app_version | zig test | PASS |
| N1-UJ-05 | repair restores deleted or tampered files | zig test | PASS |
| N1-UJ-06 | After uninstall, the install root and integrations are clean | zig test | PASS |
| N1-UJ-07 | Offline bundle install (Embedded repository) | zig test | PASS |
| N1-UJ-08 | Portable Run: TUF authorization, content-addressed cache, execution, GC | zig test | PASS |
| N1-UJ-09 | A C ABI host completes check → resolve → fetch → stage → commit | zig test | PASS |
| N1-UJ-10 | The five GUI screens open on a macOS host and complete an install | manual | NOT_RUN |

## Invariants

| ID | Description | Coverage | Status |
|---|---|---|---|
| N1-INV-01 | After recovery from any kill point, Active ∈ {OLD, NEW}, never MIXED | zig test | PASS |
| N1-INV-02 | Artifact unpacking cannot write outside the staging root | zig test | PASS |
| N1-INV-03 | Forbidden fields in manifest/component are rejected | zig test | PASS |
| N1-INV-04 | The helper accepts only closed ops, a matching tx/nonce, increasing ids and paths inside a managed root | zig test | PASS |
| N1-INV-05 | TUF rejects expired, rolled-back, forged, below-threshold, wrong hash/length | zig test | PASS |
| N1-INV-06 | release_sequence strictly increases; app_version may downgrade | zig test | PASS |
| N1-INV-07 | GUI and CLI drive the same engine and the same plan | zig test | PASS |
| N1-INV-08 | Unknown schema / too-old installer fails closed | zig test | PASS |

## Acceptance entries

| ID | Description | Coverage | Status |
|---|---|---|---|
| N1-AC-01 | Strict manifest parsing (unknown fields, duplicate keys, limits) | zig test | PASS |
| N1-AC-02 | Canonical JSON and Ed25519 signature verification | zig test | PASS |
| N1-AC-03 | Root version-chain rotation | zig test | PASS |
| N1-AC-04 | All malicious archive fixtures are rejected | zig test | PASS |
| N1-AC-05 | The planner produces the expected plan for install/update/repair/uninstall | zig test | PASS |
| N1-AC-06 | Journal recovery: rollback before commit, roll-forward after commit | zig test | PASS |
| N1-AC-07 | `zig build sim` seeded faults with no invariant violation | zig test | PASS |
| N1-AC-08 | bootstrap v1 activate/deactivate and failure semantics | zig test | PASS |
| N1-AC-09 | CLI exit codes and JSON event schema | zig test | PASS |
| N1-AC-10 | C ABI smoke (C program compiled with zig cc) | build | PASS |
| N1-AC-11 | UiTree / DisplayList / SemanticTree snapshots are deterministic | zig test | PASS |
| N1-AC-12 | Offscreen pixel golden | zig test | PASS |
| N1-AC-13 | Tokens contrast gate | build | PASS |
| N1-AC-14 | Host PlatformContract suite | zig test | PASS |
| N1-AC-15 | setup (ReleaseSafe) ≤ 30 MiB, all targets | build | PASS |
| N1-AC-16 | Binary lint: dynamic dependency allowlist, PE flags, no RWX | build | PASS |
| N1-AC-17 | All targets cross-compile | build | PASS |
| N1-AC-18 | vm-smoke Windows 11 | vm-smoke | BLOCKED |
| N1-AC-19 | vm-smoke Ubuntu 24.04 ARM64 | vm-smoke | BLOCKED |
| N1-AC-20 | check / lint / check-docs all pass | build | PASS |
| N1-AC-21 | Parsers return an error instead of crashing under every allocation failure | zig test | PASS |
| N1-AC-22 | A dependent package (`examples/hello`) produces an installable offline bundle through the public build API only | build | PASS |
