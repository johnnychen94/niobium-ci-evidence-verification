---
title: Troubleshooting and FAQ
description: Find logs, map exit codes to causes and fixes, and recover after an interruption.
---

Start from the exit code: every `setup` and `nbpack` failure ends with one, and with `--json` also with an `error` event whose `code` names the cause.

## Logs and crash records

- **Progress and errors** go to standard error as readable lines. Add `--json` to get structured [events](/reference/events/) on standard output instead.
- **Crash records** are written when `setup` panics or hits a fatal signal: `crash-<UTC time>.json` in the `logs` directory of the per-user cache.

| Platform | Cache directory (`<cache>`) |
|---|---|
| macOS | `~/Library/Caches/<product id>` |
| Windows | `%LOCALAPPDATA%\<product id>\Cache` |
| Linux | `$XDG_CACHE_HOME/<product id>`, or `~/.cache/<product id>` |

The same directory holds the transaction lock and downloads. A crash record contains the version, product, engine phase, transaction number, time and up to 32 return addresses; attach it to a bug report. On Linux, shipped binaries carry no debug information, so addresses must be resolved with an unstripped build of the same commit.

## Exit codes: cause and fix

| Code | Cause | What to do |
|---|---|---|
| 1 | Internal error | A bug: report it with the command, the `--json` output and any crash record |
| 2 | Usage error: unknown or repeated option, missing value, or no repository or trust root configured | Check the command against the [setup reference](/reference/setup-cli/); pass `--repo` or use a branded `setup` |
| 3 | Manifest, component or archive rejected, or `nbpack` input invalid (for example `PackSequenceNotIncreasing`) | Fix the input; for `nbpack publish`, raise `release_sequence` |
| 4 | Trust verification failed: signature, expiry, rollback or hash | If the metadata expired, the publisher runs `nbpack sign` and uploads the result. Otherwise the repository was altered or does not match the trust root in `setup` |
| 5 | Repository or network unavailable | Check the address and connectivity, or use an offline bundle |
| 6 | File system error, including a full disk or a locked file | Free space, close the application, retry |
| 7 | Not enough rights, or the elevation prompt was cancelled | Rerun with administrator rights for machine scope, or use user scope |
| 8 | Installed, but App Bootstrap failed (`bootstrap_pending`) | The new version is active; fix the application's bootstrap. It is retried on a later run |
| 9 | Cancelled, or the window was closed without installing | Run again |
| 10 | Another transaction for this product is running | Wait for it to finish; the lock is freed when that process exits |
| 11 | The release needs a newer installer, or uses an unknown schema | Use a newer `setup` |
| 12 | Product not installed (`update`, `repair`, `uninstall`, `status`) | Install first; for a custom location pass the same `--install-dir` |
| 13 | Platform or capability not available, for example no artifact for this platform | Check the release ships for this platform |

The full table, shared by the C ABI as negative values, is in [exit codes](/reference/exit-codes/).

## After an interruption

Run `setup` again with any command. Before anything else it recovers the interrupted transaction: back to the old version if the interruption came before the commit, forward to the new one if it came after ([Transactions](/concepts/transactions/)). Do not delete files from the install root by hand; that is what `setup repair` is for.

If a transaction ended with exit code 8, the installation is complete and only App Bootstrap is pending; `setup status --json` shows `"bootstrap"` as pending until a later run succeeds.

## FAQ

**Is there a download of `setup` or `nbpack`?** No. Both are built from source with Zig 0.17.0, by your product's build through the Niobium build API or by `zig build` in a Niobium checkout.

**Can I run a script during installation?** No. Put product logic in [App Bootstrap](/concepts/app-bootstrap/); declare OS integrations in the [manifest](/guides/package/#declare-integrations).

**How do I roll users back to a previous version?** Publish a new release with a higher `release_sequence` containing the older application version ([Channels and promotion](/concepts/channels/#ordering-and-rollback)).

**`setup` without arguments printed help instead of opening a window.** It does that on Linux without `DISPLAY`, and in a `setup` built without a product configuration. Build a branded `setup` ([Publish and host](/guides/publish-and-host/#point-setup-at-the-repository)).

**Does the installer window support Wayland?** The Linux window backend is X11; a native Wayland backend is deferred ([Status and platforms](/status/)).
