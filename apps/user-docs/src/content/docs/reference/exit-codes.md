---
title: Exit codes
description: The stable exit codes of setup and nbpack, the matching C ABI status codes, and event error codes.
---

Canonical sources: the exit code table in [cli-v1](https://github.com/niobium-project/niobium/blob/main/docs/spec/cli-v1.md#exit-codes) and its implementation [`libs/core/exit_code.zig`](https://github.com/niobium-project/niobium/blob/main/libs/core/exit_code.zig). Exit codes are a public compatibility contract: a code never changes meaning.

The C ABI returns the same codes as negative numbers; the constants are in [`distribution.h`](https://github.com/niobium-project/niobium/blob/main/api/c/distribution.h).

| Exit code | C ABI status | Event category | Meaning |
|---|---|---|---|
| 0 | `DIST_OK` (0) | | Success, including an update when already up to date |
| 1 | `DIST_E_INTERNAL` (-1) | `internal` | Internal error (a bug) |
| 2 | `DIST_E_USAGE` (-2) | `usage` | Usage error |
| 3 | `DIST_E_VALIDATION` (-3) | `validation` | Manifest, component, archive or input validation failed, including forbidden fields |
| 4 | `DIST_E_TRUST` (-4) | `trust` | Trust verification failed: signature, expiry, rollback, hash or length |
| 5 | `DIST_E_NETWORK` (-5) | `network` | Repository or network unavailable |
| 6 | `DIST_E_FILESYSTEM` (-6) | `fs` | File system error, including insufficient disk space and locked files |
| 7 | `DIST_E_PERMISSION` (-7) | `permission` | Insufficient permissions, or elevation cancelled |
| 8 | `DIST_E_BOOTSTRAP_PENDING` (-8) | `bootstrap` | Committed, but App Bootstrap failed |
| 9 | `DIST_E_CANCELLED` (-9) | `cancelled` | Cancelled by the user |
| 10 | `DIST_E_BUSY` (-10) | `busy` | Another transaction for the product is in progress |
| 11 | `DIST_E_UNSUPPORTED_SCHEMA` (-11) | `schema` | Installer too old, or schema not supported |
| 12 | `DIST_E_NOT_INSTALLED` (-12) | `not_installed` | Product not installed |
| 13 | `DIST_E_UNSUPPORTED_PLATFORM` (-13) | `platform` | Platform or capability not available |

`setup run` is the exception: it returns the exit code of the program it ran, or 128 plus the signal number.

## Event error codes

A failure with `--json` emits an `error` event whose `code` is `<category>.<name>`: the category from the table above and the internal error name in snake case without its category prefix. For example `TrustHashMismatch` becomes `trust.hash_mismatch`, and `NotInstalled` becomes `not_installed.not_installed`. The categories follow the exit code table; the specification does not enumerate the names after the dot. Match on the category or the exit code, and show the name to people.

For causes and fixes, see [Troubleshooting](/troubleshooting/#exit-codes-cause-and-fix).
