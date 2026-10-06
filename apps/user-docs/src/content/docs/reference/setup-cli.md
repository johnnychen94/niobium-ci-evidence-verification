---
title: setup command line
description: Commands, options and setting precedence of the setup executable.
---

Canonical source: [cli-v1](https://github.com/niobium-project/niobium/blob/main/docs/spec/cli-v1.md#commands); the parser is [`apps/setup/cli.zig`](https://github.com/niobium-project/niobium/blob/main/apps/setup/cli.zig).

## Commands

| Command | Does |
|---|---|
| `setup` | Opens the installer window. Prints help instead when there is no graphical session (`DISPLAY` unset on Linux) or `setup` has no product configuration |
| `setup install [options]` | Installs the product |
| `setup update [options]` | Updates to the newest release on the channel; exit 0 when already up to date |
| `setup repair [options]` | Reinstalls the installed release and restores missing or changed files |
| `setup uninstall [options]` | Removes the product and its integrations |
| `setup run <target> [options] [-- args...]` | [Portable Run](/concepts/artifacts/#portable-run): runs a component from the cache without installing |
| `setup status [options]` | Prints the installed product, version, scope, channel and root; exit 12 when not installed |
| `setup version`, `setup --version` | Prints the `setup` version |
| `setup --help`, `setup -h` | Prints usage |

`<target>` is `<product id>[:<component>.<entrypoint>]`. Without an entrypoint, the entrypoint of the manifest's first shortcut is used. Everything after `--` is passed to the program unchanged; `run` returns the program's exit code, or 128 plus the signal number if a signal ended it.

## Options

| Option | Meaning |
|---|---|
| `--silent` | No interaction; only errors on standard error |
| `--json` | One JSON [event](/reference/events/) per line on standard output; `status` prints one JSON object |
| `--scope user\|machine` | Install location and rights. Without it, `install` uses the configured default, and `update`, `repair` and `uninstall` keep the installed scope |
| `--channel stable\|beta\|nightly` | Overrides the configured channel |
| `--product <id>` | Product id; must match the product of a `run` target |
| `--repo <url\|dir>` | Repository address or directory |
| `--trust-root <file>` | Root metadata file to trust instead of the configured root |
| `--config <file>` | Product configuration file instead of the one compiled into `setup` |
| `--install-dir <dir>` | Install root other than the scope's default; needed again for later commands on such an install |
| `--components a,b` | Optional component ids to install instead of the `default` ones; required components are always installed |

Usage errors exit with code 2: an unknown option, an option given twice, a missing or invalid value, an extra argument, `--` outside `run`, `run` without a target, and an explicit `gui` command.

## Where settings come from

Command-line options win over the product configuration. The configuration is the file given with `--config`, otherwise the one compiled into `setup` (from `nbpack config`), otherwise a generic one that names no product.

- Repository: `--repo`, then a `repository/` directory next to `setup` (an offline bundle), then the configured address.
- Trust root: `--trust-root`, then the configured root.
- Channel: `--channel`, then the configured channel of a branded `setup`.
- Scope: `--scope`; for `install` only, the configured default.

`install`, `update` and `repair` need a repository and a trust root; `uninstall` needs neither.

## Output

Readable progress and errors go to standard error; with `--json`, events go to standard output. A successful transaction without `--silent` or `--json` ends with a line such as `installed com.example.hello 1.0.0 (user) in <root>`. `setup status --json` prints:

```json
{"schema":1,"product_id":"com.example.hello","version":"1.1.0","release_sequence":2,"scope":"user","channel":"stable","root":"<install root>","bootstrap":"done"}
```

`bootstrap` is `none`, `done` or `pending`.

The option `--priv-helper-v1` is the internal entry point of the elevated helper, not a public command.
