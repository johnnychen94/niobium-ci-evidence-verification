---
title: Install silently
description: Run setup without a window from scripts, deployment tools or CI, and read its result.
---

Every operation the installer window offers is also a command. With `--silent` and `--json`, `setup` runs without interaction, prints machine-readable events on standard output, and reports the outcome through its exit code.

## Install

```sh
setup install --silent --json --scope user
```

- `--scope user|machine` chooses the install location; without it the product's default scope is used. Machine scope needs administrator rights.
- `--components runtime,docs` lists the optional components to install instead of the ones marked `default`; required components are always installed. A listed or required component with no artifact for this platform fails with exit code 13.
- `--install-dir <dir>` installs somewhere other than the scope's default root.
- `--channel stable|beta|nightly` overrides the channel compiled into `setup`.
- `--repo <url|dir>` overrides where releases come from; an offline bundle's `repository/` is used automatically.

On Windows the executable is `setup.exe`; the options are the same.

## Read the result

Decide success by the exit code: 0 is success, and every other value has one meaning listed in [exit codes](/reference/exit-codes/). Codes worth handling in automation:

| Code | Meaning | Typical action |
|---|---|---|
| 0 | Success, including "already up to date" | none |
| 7 | Not enough rights, or the elevation prompt was cancelled | rerun elevated |
| 8 | Installed, but the application's App Bootstrap failed | the version is in place; check the application |
| 10 | Another transaction for this product is running | retry later |
| 12 | Not installed (for `update`, `repair`, `uninstall`) | run `install` instead |

With `--json`, standard output carries one JSON object per line:

```json
{"schema":1,"phase":"download","progress":0.998}
{"schema":1,"phase":"complete"}
```

A failure produces one `error` event with a stable `code` such as `trust.hash_mismatch` and the `exit_code`. The fields are described in [events](/reference/events/). Human-readable messages go to standard error; `--silent` limits them to errors.

## Check, update, repair, uninstall

```sh
setup status --json      # one JSON object, or exit code 12 when not installed
setup update --silent --json
setup repair --silent --json
setup uninstall --silent --json
```

`update`, `repair` and `uninstall` keep the scope of the existing installation. They look for it only in each scope's default root; for a product installed with `--install-dir`, pass the same `--install-dir` again. `uninstall` needs no repository.

An installation also contains its own copy of `setup` under `maintainer/` in the install root, which deployment tools can call for later updates and removal.

## Status of machine scope

Silent machine-scope installs have not been verified on real Windows or Linux systems yet (N1-UJ-02 on [Status and platforms](/status/)). Verify them on your target systems before relying on them.
