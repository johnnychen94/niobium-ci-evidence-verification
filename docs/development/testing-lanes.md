# Test lanes and evidence

| Lane | Content | Command | Part of verify |
|---|---|---|---|
| L0 static | fmt, ast-check, lint, check, check-docs, complexity, schema, size gate, binary lint | `zig build check`, `zig build size-gate` | Yes |
| L1 pure core | Per-module unit tests (SafeAllocator), resolver/planner/state machine on VirtualPlatform | `zig build test` | Yes |
| L2 faults and security | Crash injection at every kill point, `checkAllAllocationFailures`, TUF negative cases, malicious archives, seeded sim | `zig build test`, `zig build sim` | Yes (sim 500 seeds) |
| L2 concurrency | ThreadSanitizer | `zig build test -Dtsan` | Yes (macOS/Linux hosts) |
| L2 fuzz | Integrated fuzzer + `tests/fuzz/corpus` | `zig build fuzz` | No (on demand) |
| L3 platform contract | Host backend runs PlatformContract in a temporary root | `zig build test` | Yes |
| L4 scenarios | `examples/hello` online (local HTTP)/offline install → update → rollback release → repair → uninstall; UI golden | `zig build e2e`, `zig build golden` | Yes |
| L4 build API | `examples/hello` as a standalone package depending on this repository by path, producing an offline bundle with `build/sdk.zig` ([consuming](consuming.md)) | `zig build example` | Yes |
| L5 real OS | Parallels Windows 11, Ubuntu ARM64 | `zig build vm-smoke` | No; reports BLOCKED when unavailable |

## Continuous integration

GitHub Actions on the public repository. The required check is `CI / linux`. A new commit on a pull request cancels the previous run for that ref. Pushes to `main`, the nightly verify, and the weekly host run are not cancelled.

| When | Job | Command |
|---|---|---|
| Every pull request and push to `main` | `linux` | `zig build check` |
| Any `.zig`, `.zon`, `api/`, `build/`, `examples/`, `tests/`, or `third_party/` change | `linux`, then `coverage` | `zig build test`, `zig build c-smoke`; coverage is `zig build test -Dcoverage` under kcov and is not required |
| Those code changes plus `libs/ui/` or `tests/golden/` | `linux` | `zig build golden` |
| `libs/platform/`, `libs/privilege/`, or `libs/ui/backend/`, or the `ci:hosts` label | `windows`, `macos` | `zig build test` on Windows; `zig build test -Dtsan` on macOS. Not required |
| Daily 02:00 UTC+8, if `main` has commits this workflow has not already completed; or the `ci:verify` label | `verify` | `zig build verify --cache-poison=disallowed` on a fresh build cache |
| Sunday 04:00 UTC+8, same skip rule | `windows`, `macos`, `arm-golden` | Host tests plus `zig build golden` on Linux arm64 |

`vm-smoke` and `fuzz` stay local. Copilot code review and the Codecov status are advisory. The debug `.zig-cache` is restored by OS and CPU architecture, saved only after a successful same-repository build, and is not used by the nightly verify. Fork pull requests restore that cache and do not write a new one.

## Evidence

- Test names start with an acceptance ID, for example `test "N1-INV-01: crash at every op recovers to OLD or NEW"`; `tools/check-docs` verifies that the ID exists in [acceptance-plan-v0.1](../acceptance-plan-v0.1.md).
- e2e, sim, gallery and vm-smoke write logs to `.evidence/<suite>/<UTC>/`.
- On failure, keep the first evidence; find the root cause first, and do not rerun until green.
- `zig build gallery` writes every catalog case and page (platform × theme × 100/200%) to `.evidence/ui-gallery/<UTC>/` with an `index.html`; it is for human review only and is not a gate.

## UI golden

- `zig build golden` compares `tests/golden/kit/**` and `tests/golden/screens/**` pixel by pixel, and compares the IR, display list and SemanticTree text snapshots of the macOS light pages.
- Rasterization happens entirely in software and stb_truetype is compiled with `-ffp-contract=off`, so the same golden is bit-identical on macOS, Linux aarch64 and Linux x86_64. `zig build test-cross` installs `suite-golden`; run `zig-out/cross-tests/<target>/suite-golden` from the repository root to recheck on the target machine.
- Waiting and concurrency use barriers, failpoints and a controllable clock, not sleep.

## Seeded sim

- `zig build sim -Dseeds=N -Dseed-start=S` runs seeds S…S+N-1 for every scenario; a failure prints the scenario name and seed.
- Reproduce: `zig build sim -Dseeds=1 -Dseed-start=<failing seed>`; the same seed produces the same fault sequence (`libs/platform/fault.zig`).
- Scenarios live in `tests/sim/scenarios.zig`; each scenario asserts only invariants (OLD or NEW, no leftover lock, replayable journal), not specific errors.

## Crash records

Shipping builds (`setup`, helper, `libdistribution`) use ReleaseSafe. `zig build cross` also uses ReleaseSafe rather than ReleaseSmall: the size gate measures the ReleaseSafe binary that is actually shipped. Linux (ELF) shipping builds carry no DWARF (`shippingStrip` in `build/targets.zig`): DWARF is about 10 MB of 13 MB, and Zig 0.17's `objcopy` cannot split it into a separate file; on macOS and Windows the debug info is not in the executable to begin with (object files, PDB). Linux crash record `addresses` therefore have to be symbolized with an unstripped build of the same commit (`zig build -Dtarget=<target> -Doptimize=ReleaseSafe`); whether the code addresses of the two are byte-identical has not been verified.

Both panics and native faults (POSIX `SIGSEGV`/`SIGBUS`/`SIGILL`/`SIGFPE`, Windows vectored exception handling) go through `libs/core/crash.zig`:

1. call the registered flush hook (journal written to disk);
2. write `crash-<YYYYMMDDTHHMMSSZ>.json` in the log directory;
3. hand off to the std default handler, which prints the stack and aborts.

Record fields:

| Field | Meaning |
|---|---|
| `schema` | Always 1 |
| `kind` | `panic` or `fault` |
| `message` | Panic message or signal name |
| `version`, `product` | Build version and product id |
| `phase` | Engine phase at crash time (`core.Phase`) |
| `tx_id` | Sequence number of the in-progress transaction, 0 for none |
| `time` | UTC time |
| `addresses` | Return addresses (hex strings), at most 32 |

On the next start, `RecoverIncompleteTransaction` runs first, and then the user is told what happened.
