# Privilege IPC v1

- **Status:** Baseline
- **Decision:** [ADR-0007](../adr/0007-same-binary-privilege-helper.md)
- **Implementation:** `libs/contracts/ipc.zig` (wire format), `libs/privilege/{broker,helper,elevate}.zig`
- **Schema:** `api/schema/ipc-v1.schema.json`

## Transport

- Framing: a 4-byte little-endian `u32` length + UTF-8 JSON, ≤ 1 MiB per frame. JSON is decoded strictly (unknown fields and unknown ops are both rejected).
- Unix: the helper's stdin/stdout pipes (direct, `pkexec`, `sudo`). On the macOS authorization-prompt path, the duplex stream returned by `AuthorizationExecuteWithPrivileges`.
- Windows: the broker creates the named pipe `\\.\pipe\niobium-<tx>-<nonce>`, starts the helper with `runas`, and after connection checks that the client process id matches the process it started.
- Helper launch arguments are a closed set: `--priv-helper-v1 --tx <transaction-id> --nonce <32 hex>`, plus `--pipe <name>` on Windows. If any other argument appears, the helper refuses to start. `tx` allows only letters, digits, and `-`, at most 64 bytes.

## Messages

Handshake (broker → helper):

```json
{"v":1,"type":"hello","tx":"tx-3-…","nonce":"<hex>",
 "managed_roots":["/Library/Application Support/com.example.hello"],
 "source_roots":["/Users/u/Library/Caches/com.example.hello/staging/tx-3"]}
```

Requests and responses:

```json
{"v":1,"type":"request","id":4,"tx":"tx-3-…","nonce":"<hex>","op":"copy_file",
 "args":{"source":"…/staging/tx-3/bin/hello","target":"…/versions/3/runtime/bin/hello",
         "executable":true}}
{"v":1,"type":"response","id":4,"ok":true}
{"v":1,"type":"response","id":5,"ok":false,"error":"path_outside_managed_root"}
{"v":1,"type":"response","id":6,"ok":true,"location":"/Applications/Hello"}
{"v":1,"type":"response","id":7,"ok":true,"free_bytes":52428800}
```

End: `{"v":1,"type":"bye","tx":"…","nonce":"…"}`; the helper replies and exits.

## Closed op set

Ops map one-to-one to the `platform.Platform` vtable. The broker is itself a `Platform` implementation, so executor, transaction, and recovery do not know whether they are on the elevated path.

| op | args | Corresponding vtable |
|---|---|---|
| `create_directory` | `path` | `createDirPath` |
| `write_file` / `append_file` | `path`, `contents` (standard base64) | `writeFile` / `appendFile` |
| `copy_file` | `source`, `target`, `executable` | `copyFile` |
| `rename` | `source`, `target` | `rename` |
| `remove_file` / `remove_tree` | `path` | `deleteFile` / `deleteTree` |
| `set_pointer` / `remove_pointer` | `path`, `target` | `setPointer` / `deletePointer` |
| `prepare_integration` / `discard_integration` / `activate_integration` | `integration` | Integration lifecycle |
| `remove_integration` | `installed` | `removeIntegration` |
| `free_space` | `path` | `freeSpace` |

The vtable contains only mutating operations; reading the install tree (manifest, journal, pointers) is done by the caller through ordinary file APIs. Machine-level install directories are readable by ordinary users and do not go through the helper. `now` is provided by the broker's local clock.

## Rules

- **Session authentication:** the `tx` and `nonce` of every frame are checked against the launch arguments with constant-time comparison; on mismatch the helper replies `tx_mismatch` and exits. The first frame must be `hello` (otherwise `not_hello`). `id` must be strictly increasing (otherwise `replayed_id`).
- **Managed root:** every entry of `hello.managed_roots` must be exactly `<install base>/<product id>`, where the install base is determined by the helper's own policy and is not supplied by the broker. Paths are normalized first (rejecting `.`, `..`, and empty segments) before containment is checked.
- **Writes:** the paths of all writes, renames, deletes, and pointer operations must be inside some managed root (otherwise `path_outside_managed_root`).
- **Copy source:** `copy_file.source` must be inside `source_roots` or a managed root, or be the helper's own executable (used to copy the maintainer). The source path is opened component by component with no-follow; it is rejected if any component is a symbolic link or if the source file has `nlink > 1`, preventing arbitrary file reads through hard links or link replacement.
- **Integrations:** `integration.root` must be inside a managed root, and `scope` must be `machine` (otherwise `scope_not_machine`). The absolute location of `remove_integration` must be inside a system integration directory from the policy or inside a managed root; non-path locations such as `scm:` and the registry are left to the platform backend's ownership check (the `NiobiumManaged` marker).
- **Policy source:** `setup --priv-helper-v1` computes the policy itself and does not read any path supplied by the broker (`apps/setup/helper_mode.zig`):
  - the install base is `planner.paths.machineInstallBase`, that is `/Library/Application Support` on macOS, `%ProgramFiles%` on Windows, and `/opt` on Linux;
  - the system integration directories are `platform.Host.machineIntegrationDirs`;
  - the helper executable is the process's own path.
- **Error names:** on failure, `error` is a member name of `platform.Error` or one of the violation names above. The broker maps member names back to the error of the same name; `path_outside_managed_root` maps to `FsAccessDenied`, and `scope_not_machine` maps to `CapabilityUnsupported`.
- **Helper lost:** on pipe EOF, a truncated frame, or a write failure, the broker enters a sticky state, after which every op returns `PrivilegeHelperLost`. When transaction abort encounters `PrivilegeHelperLost` or `PlatformKilled`, it stops immediately and leaves the rest to recovery on the next startup.
- There is no op that executes arbitrary programs, loads libraries, or accesses the network.

## Trust boundary

The helper restricts **where** things are written, and does not verify **what** is written: the content comes from staging that has passed TUF verification, but that verification happens in the broker process. A compromised same-user broker can write arbitrary content inside this product's managed root and register services or shortcuts there. This is an accepted residual risk: the attacker already controls that user session, and cannot use the helper to write into other products or arbitrary system locations.
