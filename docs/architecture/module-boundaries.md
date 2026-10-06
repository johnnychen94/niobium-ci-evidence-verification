# Module boundaries

`build/modules.zig` is the single source of truth for the module graph: each module declares its root file and the list of modules it may import. A Zig module can only `@import` the modules the build graph hands it, so a layer-skipping dependency fails at compile time; `tools/check` additionally verifies that the declared graph matches the allow table in this file, and rejects relative imports across module directories.

## Layers (dependencies point down only)

| Layer | Modules |
|---|---|
| L6 application assembly | `apps/setup`, `apps/nbpack`, `apps/libdistribution`, `apps/ui-workbench` |
| L5 orchestration | `engine`, `packager`, `conformance` |
| L4 flow | `resolver`, `planner`, `transaction`, `privilege`, `bootstrap`, `portable` |
| L3 services | `trust`, `repository`, `package`, `executor`, `manifest` |
| L2 platform | `platform` (api + virtual + macos + windows + linux) |
| L1 contracts | `contracts` |
| L0 foundation | `core` |
| UI | `ui_core` ← `ui_tokens`, `ui_kit` ← `ui_screens`; `ui_render` ← `ui_core`; `ui_backend` ← `ui_render` |

## Special rules

- `ui_core`, `ui_kit` and `ui_tokens` must not depend on `engine`, `platform` or any IO.
- `ui_screens` depends only on `ui_kit` and `contracts` (ViewModel types).
- Process creation (`std.process` spawn) may appear only in `bootstrap`, `portable`, `privilege` (broker) and the service/elevation adapters of `platform`; enforced by `tools/lint`.
- `@ptrCast`/`@alignCast`/`@intFromPtr` may appear only in `platform`, `privilege`, `ui_backend`, `ui_render`, `apps/libdistribution`, `third_party` bindings, and `libs/engine/events.zig` (`Sink.bind` is the only type-erasure point for event callbacks). The allow table is `ptr_cast_allowlist` in `build/modules.zig`.
