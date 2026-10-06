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
