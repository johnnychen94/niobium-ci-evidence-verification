# CLI and events v1

- **Status:** Baseline

The CLI is the headless frontend of `InstallerEngine` and shares the same plan with the GUI. Exit codes and the event schema are a public compatibility contract.

## Commands

```text
setup                                    GUI (falls back to CLI help when there is no graphical session)
setup install   [options]
setup update    [options]
setup repair    [options]
setup uninstall [options]
setup run <portable-target> [-- args…]   Portable Run profile
setup status    [--json]
setup version
```

`setup` with no arguments prints help instead of opening a window in these cases: there is no `DISPLAY` on Linux; the embedded config is the generic config (no `product_id`). If the window detects an existing installation it goes to update, otherwise to install. Choices made in the window become the same command as on the command line (`install --scope <scope> [--install-dir <dir>]`, and for update `update --scope <scope> --install-dir <root>`), which then goes through the same engine path (N1-INV-07). The process exit code is the exit code of the last operation; closing the window without running anything gives 9 (cancelled). Existing installations are looked up only in each scope's default root directory, so a product installed in a custom directory later needs `--install-dir` to be updated.

`<portable-target>` is `<product_id>[:<component>.<entrypoint>]`; when the entrypoint is omitted, the entrypoint of the first shortcut in the manifest is used. `setup run` does not write an install root directory and uses only the content-addressed cache:

```text
<portable-cache>/
  sha256/<hex>/component.json   component metadata from the artifact
  sha256/<hex>/files/…          unpacked files
  sha256/<hex>/last-used        last use time (unix seconds), used by GC
  sha256/<hex>.tmp-<rand>/      being unpacked, published by a single directory rename; crash leftovers are cleaned up by GC
  downloads/<hex>.tar.zst       artifact being downloaded, deleted after unpacking
  trust.json                    Portable's own trusted TUF versions (rollback protection)
```

Cached components are reused by artifact digest and not downloaded again, so when the artifact target is unreachable the run still works as long as the TUF metadata can be fetched. The child process exit code is returned unchanged; when the child is terminated by a signal, `128 + signal` is returned. Implementation: `libs/portable`.

Options: `--silent` (non-interactive), `--json` (JSON events on stdout), `--scope user|machine`, `--channel <name>`, `--product <id>`, `--repo <url|dir>`, `--trust-root <file>`, `--config <file>`, `--install-dir <dir>`, `--components a,b`; plus `--help`/`-h` and `--version`. The following are usage errors (exit code 2): an unknown option, the same option given more than once, `--` in any command other than `run`, `run` without a target, and an explicit `gui`.

Settings are resolved in this order: command-line options first, then the product config. The product config comes from `--config <file>`; when that is not given, the config embedded in `setup` at build time is used: the branded config specified by `zig build -Dproduct-config=<file>`, or by default the generic `apps/setup/generic-config.json`. Specific rules:

- `channel` takes effect only in a branded config.
- The config default for `scope` is used only for `install`; `update`, `repair`, and `uninstall` keep the installed scope.
- `install`, `update`, and `repair` must be able to determine the repo and the trust root; `uninstall` needs neither.
- The product for `run` comes from the target; if `--product` is also given and differs from the target, it is a usage error.
- `branding` ([schema](../../api/schema/product-config-v1.schema.json)) affects only the GUI: product name, publisher, accent (`#RRGGBB`), welcome and completion text, license text, base64 PNG logo (≤ 256 KiB after decoding). All text is plain UTF-8, and no markup is interpreted. When the accent cannot reach 4.5:1 on both the light and dark themes, the GUI refuses to start; the CLI ignores branding.

Human-readable output (phases and errors) goes to stderr; with `--json`, events go to stdout. Crash records are written to `<cache>/logs` ([crash records](../development/testing-lanes.md#crash-records)). `setup --priv-helper-v1` is the internal entry point of the elevation helper ([ipc-v1](ipc-v1.md)) and is not part of the public CLI: when the session ends normally with `bye` the exit code is 0, and any other ending gives 7.

## Events

With `--json`, one object per line:

```json
{"schema":1,"phase":"download","progress":0.37}
{"schema":1,"phase":"error","code":"trust.hash_mismatch","message":"…","exit_code":4}
```

`phase` ∈ `recover`, `discover`, `validate`, `resolve`, `plan`, `prepare`, `download`, `verify`, `execute`, `commit`, `bootstrap`, `verify_install`, `finalize`, `complete`, `error`. `progress` is a number from 0 to 1 and is optional; `message`, `code`, and `exit_code` are optional. Consumers must ignore unknown fields (forward compatibility), and producers must not change the meaning of existing fields.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success (including update when already up to date) |
| 1 | Internal error (bug) |
| 2 | Usage error |
| 3 | Manifest / component validation failed (including forbidden fields) |
| 4 | Trust verification failed (signature, expiry, rollback, hash) |
| 5 | Repository or network unavailable |
| 6 | File system error (including insufficient disk space, file locked) |
| 7 | Insufficient permissions or elevation cancelled |
| 8 | Committed but App Bootstrap failed (`bootstrap_pending`) |
| 9 | Cancelled by user |
| 10 | Another transaction is in progress (lock held) |
| 11 | Installer too old or schema not supported |
| 12 | Product not installed (update / repair / uninstall) |
| 13 | Platform or capability not supported |
