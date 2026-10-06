---
title: Embed through the C ABI
description: Check for, download and apply updates from your own process with libdistribution.
---

`libdistribution` exposes the same engine as `setup` through a C ABI, so an application or launcher can check for and apply updates itself. This guide links the library and walks through one update.

## Build and link the library

From a Niobium checkout, `zig build` installs:

```text
zig-out/include/distribution.h
zig-out/lib/libdistribution.a        static library (macOS shown)
zig-out/lib/libdistribution.dylib    dynamic library
```

Include `distribution.h` and link either library; add `-Dtarget=<triple>` to build for another platform. On Linux the library does not link libc, so it does not tie your host to one C library.

## Get the function table

Everything goes through one exported function, which returns a versioned table:

```c
#include "distribution.h"

const dist_api_v1 *api = NULL;
if (dist_get_api(DIST_ABI_V1, &api) != DIST_OK) {
    /* library too old or too new for this header */
}
```

Every call returns `DIST_OK` (0) or a negative status whose magnitude is the matching [exit code](/reference/exit-codes/); for example `-4` is a trust failure.

## Create a context

```c
dist_config_v1 config;
memset(&config, 0, sizeof config);
config.struct_size = sizeof config;
config.repository = "https://dl.example.com/hello";  /* or a directory path */
config.trust_root = root_bytes;                      /* contents of <N>.root.json */
config.trust_root_len = root_len;
config.product_id = "com.example.hello";
config.channel = NULL;                               /* NULL means "stable" */
config.scope = DIST_SCOPE_USER;
config.install_dir = NULL;                           /* NULL: platform default */
config.work_dir = NULL;                              /* NULL: platform cache */

dist_context *ctx = NULL;
int32_t status = api->context_create(&config, &ctx);
```

One context is one transaction. It takes the product's transaction lock on the first `check_update` or `resolve` and releases it in `context_destroy`; if another transaction holds it, you get `DIST_E_BUSY` (-10).

## Run an update

```c
dist_update_info_v1 info;
memset(&info, 0, sizeof info);
info.struct_size = sizeof info;

status = api->check_update(ctx, &info);
if (status == DIST_OK && info.update_available) {
    status = api->resolve(ctx);
    if (status == DIST_OK) status = api->fetch(ctx);
    if (status == DIST_OK) status = api->stage(ctx);
    if (status == DIST_OK) status = api->transaction_commit(ctx);
}
if (status != DIST_OK && status != DIST_E_BOOTSTRAP_PENDING) {
    dist_buffer error = {0};
    api->last_error(ctx, &error);   /* {"code":"...","message":"...","exit_code":N} */
}
api->context_destroy(ctx);
```

- `fetch`, `stage` and `transaction_commit` before a resolve return `DIST_E_USAGE` (-2); when already up to date they do nothing and return `DIST_OK`.
- `transaction_commit` returns `DIST_E_BOOTSTRAP_PENDING` (-8) when the new version is committed but App Bootstrap failed.
- Buffers returned in `dist_buffer` belong to the library and stay valid until the next call on the same context.

## Progress and cancellation

`event_subscribe(ctx, callback, user)` delivers each [event](/reference/events/) as JSON bytes without a trailing newline. `cancel(ctx)` may be called from any thread; the running operation stops at its next checkpoint with `DIST_E_CANCELLED` (-9).

## Limits

- The library never shows an elevation prompt. Machine scope works only when your process is already elevated; otherwise calls return `DIST_E_PERMISSION` (-7).
- On Linux it reads the environment from `/proc/self/environ`, so variables your process sets after it started are not seen.

A complete program that installs a product this way is the C smoke test, [`tests/c-smoke/main.c`](https://github.com/niobium-project/niobium/blob/main/tests/c-smoke/main.c). Function by function semantics are in the [C ABI reference](/reference/c-abi/).
