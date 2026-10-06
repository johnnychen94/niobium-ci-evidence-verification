---
title: C ABI
description: Functions, structures and status codes of libdistribution.
---

Canonical sources: the header [`api/c/distribution.h`](https://github.com/niobium-project/niobium/blob/main/api/c/distribution.h) and the [abi-v1](https://github.com/niobium-project/niobium/blob/main/docs/spec/abi-v1.md) specification. For a walkthrough, see [Embed through the C ABI](/guides/embed-c-abi/).

## Entry point

```c
int32_t dist_get_api(uint32_t requested_version, const dist_api_v1 **out_api);
```

`requested_version` must be `DIST_ABI_V1` (1); any other value returns `DIST_E_USAGE`. On success, `*out_api` points to a static function table.

## Function table `dist_api_v1`

| Member | Does |
|---|---|
| `struct_size` | Size of the table; later versions only append members |
| `context_create(config, &ctx)` | Creates a context from a `dist_config_v1` |
| `context_destroy(ctx)` | Releases the context and its transaction lock; accepts NULL |
| `check_update(ctx, &info)` | Resolves the channel and fills `dist_update_info_v1` |
| `resolve(ctx)` | Resolves and verifies the release manifest |
| `fetch(ctx)` | Downloads and verifies the artifacts |
| `stage(ctx)` | Unpacks into staging |
| `transaction_commit(ctx)` | Executes and commits the transaction, running recovery first |
| `portable_resolve(ctx, target, &buffer)` | Resolves a Portable Run target and returns its cache path |
| `portable_run(ctx, target, argv, &exit_code)` | Runs it; `argv` is NULL-terminated or NULL |
| `event_subscribe(ctx, callback, user)` | Registers the [event](/reference/events/) callback |
| `cancel(ctx)` | Requests cancellation; callable from any thread |
| `last_error(ctx, &buffer)` | JSON of the last error: `{"code":...,"message":...,"exit_code":N}` |

## Structures

**`dist_config_v1`**: `struct_size`; `repository` (URL or directory, UTF-8); `trust_root` and `trust_root_len` (bytes of a `<N>.root.json`); `product_id`; `channel` (`"stable"`, `"beta"`, `"nightly"`, or NULL for stable); `scope` (`DIST_SCOPE_USER` 0 or `DIST_SCOPE_MACHINE` 1); `install_dir` and `work_dir` (NULL for the platform defaults).

**`dist_update_info_v1`**: `struct_size`; `update_available` (1 when the channel offers a higher `release_sequence`); `release_sequence`; `installed_release_sequence`; `version` (the offered application version, NUL-terminated in a 64-byte array).

**`dist_buffer`**: `{ const uint8_t *data; size_t len; }`, owned by the library and valid until the next call on the same context.

## Status codes

`DIST_OK` is 0. Every error is negative and its magnitude equals the [exit code](/reference/exit-codes/) of the same failure: `DIST_E_INTERNAL` -1, `DIST_E_USAGE` -2, `DIST_E_VALIDATION` -3, `DIST_E_TRUST` -4, `DIST_E_NETWORK` -5, `DIST_E_FILESYSTEM` -6, `DIST_E_PERMISSION` -7, `DIST_E_BOOTSTRAP_PENDING` -8, `DIST_E_CANCELLED` -9, `DIST_E_BUSY` -10, `DIST_E_UNSUPPORTED_SCHEMA` -11, `DIST_E_NOT_INSTALLED` -12, `DIST_E_UNSUPPORTED_PLATFORM` -13.

## Rules

- One context is one transaction. The lock is taken by the first `check_update` or `resolve` and released by `context_destroy`; a held lock returns -10.
- `check_update` and `resolve` both resolve; either may come first, and the second reuses the result.
- `fetch`, `stage` and `transaction_commit` before a resolve return -2. When no update is available they do nothing and return 0.
- After `cancel`, the running call and every later call return -9.
- Every failure also sends one `error` event to the subscribed callback.
- No Zig types, allocators or errors cross the boundary.
- The library never prompts for elevation; machine scope needs an already elevated process (-7 otherwise).
- Environment: on Linux it is read from `/proc/self/environ` because the library does not link libc, so `setenv` calls made after the process started are not seen; on macOS from `environ`; on Windows from the process environment block.
