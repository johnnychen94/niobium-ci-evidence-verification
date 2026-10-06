# Component metadata v1

- **Status:** Baseline

The root directory of every component artifact contains `component.json`; all other files are under `files/`. A component owns no absolute machine paths and contains no install scripts.

```json
{
  "schema": 1,
  "id": "runtime",
  "version": "1.2.0",
  "platform": "macos-aarch64",
  "entrypoints": {
    "main": { "path": "bin/hello", "bootstrap": true },
    "agent": { "path": "bin/hello-agent" }
  },
  "executables": ["bin/hello", "bin/hello-agent"]
}
```

## Rules

- Only the fields above are allowed; unknown fields and forbidden fields (same as [manifest-v1](manifest-v1.md)) are rejected.
- `platform` must match the key under which the manifest references this artifact.
- `entrypoints.*.path` and `executables[]` are normalized relative paths under `files/` and must exist in the payload.
- `bootstrap: true` means the entrypoint implements [bootstrap-v1](bootstrap-v1.md); the manifest's `bootstrap.entrypoint` must point to such an entrypoint.
- The executable bit is determined only by `executables`; modes in the archive are ignored.
- `nbpack component validate` checks the structure, entrypoint existence, the bootstrap declaration, and the safety rules (see [artifact-format-v1](artifact-format-v1.md)).
