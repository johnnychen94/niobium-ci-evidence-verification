# Anti-pattern table

| Symptom | Guarantee broken | Recommended design | Verification |
|---|---|---|---|
| Manifest gains `post_install`, `script`, or `hooks` fields | Principles 1 and 6: manifest is data, the framework is not extensible | App Bootstrap v1 (product logic runs inside the app process) | `tools/check` forbidden-field scan; schema `additionalProperties: false` |
| Overwriting files in `current/` directly | Transactionality: MIXED after a crash | Unpack into `versions/<seq>`, commit by pointer swap | sim OLD-or-NEW assertion |
| JSON parsing ignores unknown fields | Contract strictness; semantic drift not covered by signatures | `contracts.json.decodeStrict` | Negative tests: unknown fields, duplicate keys |
| Unpacking artifacts with `std.tar.pipeToFileSystem` | Path traversal, symlink escape, device files | `package.extract` strict walker | All of `tests/fixtures/malicious` rejected |
| `catch unreachable` on IO / parse results | Crash safety: external input can trigger a panic | Explicit error, mapped to an exit code | `tools/lint no-catch-unreachable` |
| Comparing old and new by `app_version` | Rollback protection: version numbers can repeat or go backwards | Monotonically increasing `release_sequence` | N1-INV rollback rejection test |
| Whole installer process runs as administrator | Least privilege | Same binary `--priv-helper-v1` executes only closed ops | Broker negative tests: unknown op, wrong nonce |
| UI thread calls the engine directly | Single owner; hangs | Engine on a worker thread; UI only reads snapshots and sends intents | tsan lane |
| `lint-allow` without a reason just to pass checks | Rule credibility | Fix the rule or the code; the reason must be specific | Suppression count in the lint report |
| Updating golden wholesale | Regression detection | `-Dupdate=<component>` + review the diff | AGENTS.md section 6 |
| Creating `utils.zig` / `common/` | Clear ownership | Find the semantic owner module | `tools/check` directory name check |
| Introducing GTK / XAML / SwiftUI to be "more native" | ADR-0008 shared renderer, size, dependency gates | Approximate the native look with platform values in tokens | `check-binary` dynamic dependency allowlist |
| Using `std.heap.page_allocator` in `libs/` | Allocators replaceable and testable | Pass an `Allocator` explicitly | `tools/lint no-page-allocator` |
| Sleeping to wait for async results | Test determinism | barrier / failpoint / controllable clock | `tools/lint no-sleep-in-tests` |
| `@intCast` on lengths read from files | Out-of-bounds panic | `std.math.cast` and return an error | `tools/lint parser-int-cast` |
| A missing field or swallowed error is reported as success | Facts are explainable | Distinguish absent, valid default, and failure per the contract | Negative contract test for each case |
| UI or local state shows "installed" before the engine confirms | Single owner of install state | UI shows pending until the engine reports the journaled result | UAC-cancel and `PrivilegeHelperLost` scenarios |
| Unknown helper or download outcome followed by a blind retry | Transactionality; no duplicate effect | Recover from the journal, then start a new transaction | sim kill point at that op |
| Bug closed with an extra retry or guard | Root cause fixed | Fix the first contract deviation (design-and-debugging.md) | Regression on the original trigger sequence |
| Test counts mock calls or reads a test-only getter | Tests protect behaviour | Assert public results, journal records, and exit codes | The test fails when the behaviour is removed |
| L1 VirtualPlatform pass reported as an L5 OS pass | Evidence matches what ran | Record the lane; L5 stays `BLOCKED` or `NOT_RUN` without a VM | Coverage column of the acceptance row (`vm-smoke`) |
| Crash JSON or log line treated as proof of commit | Journal is the install fact | Read the journal and the `current` pointer | Recovery test from the same kill point |
