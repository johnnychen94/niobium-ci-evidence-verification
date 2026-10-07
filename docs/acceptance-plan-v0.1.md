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


## Test-system validation 2026-10-07

These results cover the automation foundation working tree based on
`99448d398f097213b72f1976252c244d9190e650`, with `dirty=true`, Zig 0.17.0 and a native macOS
aarch64 host. They do not certify an unchanged HEAD or any later revision. The full change exceeds
300 net lines because the approved delivery spans the report contract, build graph, probes and CI;
implementation was applied in bounded patches. No new lint suppressions were introduced (66 total).

| Validation | Verdict | Evidence / limits |
|---|---|---|
| `zig build verify --cache-poison=disallowed --summary failures` | PASS | Final local gate after ZIP extraction checks, including native cases, golden, sim, C smoke, ThreadSanitizer, cross compilation, binary and size gates |
| `zig build test c-smoke --summary failures` | PASS | Default selection and compatibility alias; host contracts: `.evidence/conformance/1791357834297-suite-conformance-68270b21b47d2901/report.json` |
| `zig build test -Dsuite=e2e -Dcase=online-lifecycle --summary failures` | PASS | Filtered lifecycle: `.evidence/e2e/1791357448923-suite-e2e-483751b500cdc93f/report.json` |
| `zig build test -Dsuite=sim,fuzz -Dseeds=2000 -Dseed-start=42 --summary failures` | PASS | Simulation: `.evidence/sim/1791357464115-suite-sim-d2a1eeb2eb130399/report.json`, corpus replay: `.evidence/fuzz/1791357496605-suite-fuzz-e9d02acc9d9fd155/report.json` |
| Unknown suite/case, zero seeds, narrowing verify | PASS | CLI invocations rejected with exit 1; narrowing verify ran no test nodes |
| Saved lifecycle validation through `zig build evidence -Daction=validate` | PASS | Saved report: `.evidence/e2e/1791358963767-suite-e2e-599ea13fb6dff571/report.json` |
| Partial reports, unsupported contracts, missing/changed evidence, deadlines and output limits | PASS | Evidence-tool and conformance regression tests, including link/traversal ZIP rejection; `.evidence/unit/1791358961538-tool-evidence-0bd0862ca45049a9/report.json` |
| Wrong generation, corrupt payload and lost application data | PASS | Independent negative controls and lifecycle cases: `.evidence/e2e/1791358963767-suite-e2e-599ea13fb6dff571/report.json` |
| CI aggregate and path selection | PASS | Local shell checks: seven job-status combinations and five changed-path cases; workflow YAML parsed |
| Windows evidence-tool cross compilation | PASS | `zig build-exe -target x86_64-windows` with contracts/catalog module inputs; compilation only |
| `zig build test -Dsuite=fuzz -Dcontinuous-fuzz --fuzz=1000 --summary failures` | BLOCKED | Native fuzzer rebuild fails with unresolved `___sanitizer_cov_trace_*` symbols from zstd on this macOS toolchain; corpus replay is separate |
| R2 upload/readback, duplicate/conflict/interruption, pagination and deployed lifecycle | PASS | Real US-jurisdiction private Standard bucket; scoped keys stored in the main-only GitHub environment; monthly ordinary-evidence rules read back and live Zig verification passed (deployment record below) |
| Selected Ubuntu/Windows/macOS CI jobs | PASS | [Run 37601399813](https://github.com/niobium-project/niobium/actions/runs/37601399813) at `f2171a1`: all three native unit/conformance/e2e jobs and required `linux` aggregate passed; macOS also ran ThreadSanitizer |
| Trusted fork publisher workflow | NOT_RUN | Trusted default-branch deployment and fork verification remain prerequisites |
| Reference-OS elevation, desktop, signed release bytes and viewer | NOT_RUN | Separate roadmap prerequisites; hosted contracts do not satisfy L5 |

The earlier sandbox `manifest_create PermissionDenied` was resolved for validation by running
approved Zig build commands outside that filesystem sandbox. It was not bypassed by weakening any
repository check. Saved reports and their attachments remain local under `.evidence/` until an
explicit publication succeeds; the links above are working-copy evidence, not committed fixtures.
R2 remains `working` in the construction roadmap.

The subsequent platform fixes in `ea45cce` passed
`zig build verify -Dseeds=2000 --cache-poison=disallowed --summary failures` on native macOS
aarch64 (working tree based on `b38746c`, `dirty=true`). Evidence includes
`.evidence/conformance/1791361295064-suite-conformance-62a571380a8399fe/report.json`,
`.evidence/e2e/1791361397430-suite-e2e-72949fdfbf2c260f/report.json`, and
`.evidence/sim/1791361322875-suite-sim-5ddad716e49b34d7/report.json` (2,000 seeds).
The Windows path-normalization regression failed before the fix. Hosted runs also exposed an
unrelated advisory Codecov upload failure requiring service authentication; coverage tests passed.

The final local gate, `zig build verify -Dseeds=2000 --cache-poison=disallowed --summary failures`,
also passed on clean commit `576dd551c68e4bca4a98e39d02d24cfe42212ea0` (`dirty=false`). Its evidence is
`.evidence/conformance/1791363253246-suite-conformance-11ac52df3ae13f24/report.json`,
`.evidence/e2e/1791363236630-suite-e2e-35224263fe16a273/report.json`, and
`.evidence/sim/1791363214648-suite-sim-4bd885966979559c/report.json`.
Windows native validation required fixing directory-link cleanup, junction path normalization,
snapshot canonicalization, registry handle ABI, and planner registration targets. The planner
regression checks every generated Windows integration target against platform validation.
The earlier [failed run](https://github.com/niobium-project/niobium/actions/runs/37593700618)
retains partial case evidence; offline validation of its Windows report succeeded with verdict FAIL.
Hosted evidence remains downloadable from the linked runs; the deployment record below identifies
the current R2 archive status.


## R2 deployment validation 2026-10-08

The deployment uses `org-niobium-project-dev-assets` and `ci-evidence/YYYY-MM/`. The source
attempt's UTC start chooses the month, so retries retain their keys. Cloudflare configuration
readback verified private access, Standard storage, twelve 90-day ordinary-evidence prefixes
(October 2026–September 2027), and preservation of the existing seven-day multipart-abort rule.
The object read/write credential is scoped to this bucket and stored in the `test-evidence`
GitHub environment, whose deployment policy remains restricted to `main`.

| Validation | Verdict | Evidence / limits |
|---|---|---|
| `zig build test -Dsuite=unit -Dr2-live=true` | PASS | Real conditional writes, digest readback, identical/conflicting publication, report-last recovery, paginated listing and incomplete multipart upload/abort. Concurrent distinct payloads passed: `.evidence/unit/1791391304729-tool-evidence-5e27ce8a69c8b6b0/report.json` (working tree based on `f2171a1`, dirty). Its report and logs are persisted under `ci-evidence/2026-10/` |
| `zig build verify --cache-poison=disallowed --summary failures` | PASS | Clean `28ca68ff6d83b43ed3deb186fb5e8f6db9607990`; conformance `.evidence/conformance/1791391945046-suite-conformance-e56190e63d678af9/report.json`, e2e `.evidence/e2e/1791391862260-suite-e2e-e5b4b3756f79759b/report.json`, sim `.evidence/sim/1791391853685-suite-sim-eec93205f8356e5b/report.json` |
| Native Ubuntu/Windows/macOS and aggregate | PASS | [Replacement CI run](https://github.com/niobium-project/niobium/actions/runs/37658039579) on `28ca68f`; all selected jobs and `linux` passed. The [original PR run](https://github.com/niobium-project/niobium/actions/runs/37655224913) hit a GitHub internal error after native jobs passed, before its aggregate started; its records remain intact |
| Trusted default-branch and fork publication | NOT_RUN | Requires deployment after a fresh protected PR aggregate; the verification fork is prepared and receives no R2 secrets |
| Review fixes and credential-safe diagnostics | PASS | `zig build verify --cache-poison=disallowed --summary failures` on clean `0eeebcf`; conformance `.evidence/conformance/1791403507408-suite-conformance-8266ded1c71071be/report.json`, e2e `.evidence/e2e/1791403478819-suite-e2e-95c5bdaa98938bf7/report.json`, sim `.evidence/sim/1791403507577-suite-sim-8fb4a2f9a879de39/report.json` |
| Bounded native transport retries | PASS | Full `zig build verify --cache-poison=disallowed --summary failures` on clean `6e59033`; conformance `.evidence/conformance/1791404391633-suite-conformance-f05ae06da10a2f00/report.json`, e2e `.evidence/e2e/1791404415720-suite-e2e-aacb2cb4ab223a02/report.json`, sim `.evidence/sim/1791404408066-suite-sim-9e80a371e7d9dcae/report.json`. Standard SDK retries have three attempts and a subprocess deadline; tests are not retried |
| Fresh protected PR aggregate | PASS | [CI run 37660875144](https://github.com/niobium-project/niobium/actions/runs/37660875144) on `ebaaf37`: Ubuntu, Windows, macOS and required `linux` succeeded. The subsequent review fixes require a current native CI run |

Provider verification does not substitute for the trusted CI publication check. The configured
retention horizon must be renewed before September 2027 ends; a missing ordinary-object expiry
fails publication. Advisory Codecov upload authentication remains separate from test verdicts.

GitHub web-editor signatures preserve the tested workflow files without expanding CLI permissions.
Deployment still requires a current protected CI gate; the publisher is not yet installed on `main`.
Local publication of saved CI data preserved completed reports before transient transport failures.
Publication recovery uses the saved evidence, without rerunning tests or replacing archive objects.
