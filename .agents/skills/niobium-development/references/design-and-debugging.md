# Design and debugging

## Design checklist

1. **Data or code?** Product differences go into the manifest; when logic is needed, hand it to the App Bootstrap process.
2. **Desired state?** The planner only compares "current state + manifest → desired state" and does not record imperative steps.
3. **Ownership?** The installer owns `versions/`, the `current` pointer, the journal, and trust state; the app owns user data and runtime configuration. The installer does not write to the app data directory.
4. **Privilege?** Operations that need elevation must belong to the closed op set of `ipc-v1`; adding an op = changing the spec + broker + helper + negative tests.
5. **Transaction?** A new operation must be expressible as a journal record and be rollbackable; the only commit point is the pointer swap.
6. **Bounds?** Every loop, queue, retry, and read states its upper bound and timeout.

## Debugging process

1. **Pin the reproduction**: a sim failure gives a seed; replay it directly with `zig build sim -Dseeds=1 -- --seed=<n>`; for an e2e failure, look at `.evidence/e2e/<UTC>/`.
2. **Find the first anomaly first**: read the journal (`<root>/journal/*.jsonl`) in record order; the first record that deviates from the spec is near the root cause.
3. **Crash records**: `<root>/logs/crash-<UTC>.json` contains the phase, tx-id, and stack addresses; resolve them against symbols from `zig build -Doptimize=ReleaseSafe`.
4. **Do not rerun to get green**: treat flakiness as a real bug first; add `-Dtsan` for concurrency issues, switch to a controllable clock for timing issues.
5. **After the fix**: turn the reproducing input into a test (sim seed, fuzz corpus, malicious fixture).

## Common symptoms

| Symptom | Check first |
|---|---|
| After recovery `current` points to a nonexistent version | Whether staging is fsynced before commit; whether journal `ready_to_commit` precedes the pointer swap |
| rename occasionally fails on Windows | Antivirus/indexer locks; whether the executor uses bounded backoff retry |
| TUF verification fails after the clock is set back | Whether expiry is compared with a monotonic clock; whether `trust/state.json` persists the highest version |
| UI stutters | Whether the engine runs on the UI thread; whether a snapshot is held too long |
| X11 window does not appear | Whether a connection setup reply parse error is swallowed; `DISPLAY` and `XAUTHORITY` |
