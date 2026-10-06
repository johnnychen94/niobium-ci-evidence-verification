# Architecture overview

Niobium is a library-first distribution substrate: `libs/engine` orchestrates Discover → Validate → Resolve → Plan → Prepare → Execute → Commit → Bootstrap → Verify → Finalize, and the GUI, CLI and C ABI are only its frontends.

```text
setup (GUI/CLI) ─┐
libdistribution ─┼─► engine ─► resolver ─► trust (TUF) ─► repository (Http/Directory/Embedded)
                 │          ├► planner ─► typed InstallationPlan
                 │          ├► transaction ─► executor ─► platform.api ─► macOS/Windows/Linux/Virtual
                 │          │             └► privilege broker ─► setup --priv-helper-v1
                 │          ├► bootstrap (App Bootstrap v1)
                 │          └► portable (Portable Run)
ui/screens ─► ui/kit ─► ui/core ◄─ ui/render ◄─ ui/backend (AppKit/Win32/X11/offscreen)
```

## Three stable contracts

1. **Product contract**: [manifest-v1](../spec/manifest-v1.md) and [component-v1](../spec/component-v1.md).
2. **Installer contract**: Desired State → transactional deployment ([transaction-model](transaction-model.md), [platform-contract-v1](../spec/platform-contract-v1.md)).
3. **App contract**: [bootstrap-v1](../spec/bootstrap-v1.md).

The outer layer is the **Trust contract**: [tuf-profile-v1](../spec/tuf-profile-v1.md).

## Process model

- `setup` runs as a normal user; the engine runs on a worker thread, and the UI thread only renders read-only snapshots and sends intents.
- `setup --priv-helper-v1` is started only when the plan contains a machine-scope op, and it exits when the transaction ends.
- App Bootstrap and Portable Run targets are separate child processes with timeouts.

## Profile

| Profile | Capability | v0.1 |
|---|---|---|
| InstalledApplication | desired state → plan → machine mutation | Implemented |
| PortableRun | trusted artifact → execute (no machine integration) | Implemented |
| EmbeddedUpdate | resolve / download / verify / stage / handoff | C ABI provides the foundation; Node-API deferred |
