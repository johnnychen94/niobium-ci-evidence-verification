# C ABI v1

- **Status:** Baseline
- **Decision:** [ADR-0002](../adr/0002-library-first-core-and-c-abi.md)

Header: `api/c/distribution.h`. Library: `libdistribution` (static and dynamic).

## Entry point

```c
int32_t dist_get_api(uint32_t requested_version, const dist_api_v1 **out_api);
```

`requested_version` must be `DIST_ABI_V1` (= 1). On success it returns `DIST_OK` and writes out a pointer to the static function table.

## Function table `dist_api_v1`

| Member | Description |
|---|---|
| `struct_size` | Table size, for backward-compatible extension |
| `context_create(const dist_config_v1*, dist_context**)` | Creates a context; the config contains `struct_size`, repo URL/directory, trust root bytes, product id, channel, scope, and optional `install_dir` and `work_dir` |
| `context_destroy(dist_context*)` | Releases the context |
| `check_update(dist_context*, dist_update_info_v1*)` | Resolves the channel and fills in whether an update exists, `release_sequence`, and the version string |
| `resolve(dist_context*)` | Resolves and verifies the manifest |
| `fetch(dist_context*)` | Downloads and verifies artifacts |
| `stage(dist_context*)` | Unpacks into staging |
| `transaction_commit(dist_context*)` | Executes and commits (including recovery) |
| `portable_resolve(dist_context*, const char* target, dist_buffer*)` | Resolves a portable target and returns the cache path |
| `portable_run(dist_context*, const char* target, const char* const* argv, int32_t* exit_code)` | Runs it |
| `event_subscribe(dist_context*, dist_event_fn, void* user)` | Event callback (JSON bytes + length) |
| `cancel(dist_context*)` | Requests cancellation |
| `last_error(dist_context*, dist_buffer*)` | JSON of the most recent error |

Status codes: `DIST_OK = 0`; all others are negative values whose magnitudes match the [cli-v1](cli-v1.md) exit codes (for example `-4` is a trust failure). `dist_buffer` is a library-owned `{const uint8_t* data; size_t len;}`, valid until the next call on the same context.

## Call order and semantics

- One context corresponds to one transaction: the product's transaction lock is acquired on the first `check_update` or `resolve` and released on `context_destroy`. If the lock is held, `-10` is returned.
- Both `check_update` and `resolve` complete discover and resolve; either may be called first, and the second call reuses the result.
- `fetch`, `stage`, and `transaction_commit` must be called after resolve; otherwise they return `-2`.
- When already up to date (`update_available = 0`), `fetch`, `stage`, and `transaction_commit` do nothing and return `DIST_OK`.
- `transaction_commit` returns `-8` (`bootstrap_pending`) when the commit succeeded but App Bootstrap is still pending.
- `cancel` may be called from any thread; the in-progress operation at its next checkpoint, and all later operations, return `-9`.
- The `argv` of `portable_run` is NULL-terminated; NULL may also be passed, meaning no arguments. `exit_code` follows the same rules as `setup run`.
- `last_error` returns `{"code":"<category>.<name>","message":"<Name>","exit_code":N}`. Every failure also sends one `phase: "error"` event to the callback registered with `event_subscribe`. The JSON the callback receives has no trailing newline.

## Environment

The library reads environment variables from the host process to determine home, XDG directories, and Windows known folders, using the same rules as `setup`.

- **Linux:** the library does not link libc, because a `.so` linked against one libc breaks inside a host that uses another libc. Environment variables are read from `/proc/self/environ`, so changes the host makes with `setenv` after exec are not visible.
- **macOS:** uses libSystem's `environ`.
- **Windows:** uses the process environment block.

The library never shows an elevation prompt: machine scope is available only when the host process itself is already privileged; otherwise `-7` is returned.

## Rules

- Do not expose Zig structs, allocators, error unions, or the internal representation of slices.
- No Zig error may cross the boundary; every exported function catches it and maps it to a status code.
- New members may only be appended to the end of the table, with `struct_size` increased; breaking changes require `DIST_ABI_V2`.
