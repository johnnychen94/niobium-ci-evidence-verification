---
title: nbpack command line
description: Commands and options of nbpack, the publisher tool.
---

Canonical source: the parser and usage text in [`apps/nbpack/cli.zig`](https://github.com/niobium-project/niobium/blob/main/apps/nbpack/cli.zig); procedures in the [release signing runbook](https://github.com/niobium-project/niobium/blob/main/docs/runbooks/release-signing.md). `nbpack` is built by `zig build` in a Niobium checkout, or by `niobium.nbpack(b)` in your `build.zig`.

Options take one value each and may not repeat, except `--artifact`. Unknown commands or options, missing values and missing required options exit with code 2. Other failures print `nbpack: <ErrorName>` and exit with the matching [exit code](/reference/exit-codes/), for example 3 for `PackSequenceNotIncreasing`.

## Commands

| Command | Required | Optional | Does |
|---|---|---|---|
| `keygen` | `--out <dir>` | | Writes a key file for each of the five roles |
| `component build` | `--source <component.json>` `--files <dir>` `--version <x.y.z>` `--out <file>` | `--platform <os-arch>` (default: the host) | Builds and validates one component artifact |
| `component validate <artifact>` | | `--platform <os-arch>` | Validates an artifact; prints its id, version and platform |
| `product compose` | `--product <product.json>` `--artifact <file>`... `--out <file>` | `--version` `--sequence` | Writes the release manifest without signing |
| `publish` | `--repo <dir>` `--keys <dir>` `--product <product.json>` `--artifact <file>`... | `--channel` (default `stable`) `--version` `--sequence` `--init` and the clock options | Adds a release to the repository and signs it |
| `promote` | `--repo` `--keys` `--product-id <id>` `--sequence <n>` `--channel <c>` | clock options | Points a channel at an existing release and re-signs |
| `sign` | `--repo` `--keys` | clock options | Re-signs metadata to extend its expiry |
| `config` | `--repo` `--product <product.json>` `--out <file>` | `--branding <file>` `--logo <png>` `--repository <url\|dir>` `--channel` (default `stable`) | Writes the product configuration for a branded `setup`, embedding the repository's latest root |
| `bundle` | `--repo` `--setup <exe>` `--out <dir>` | | Copies `setup` and the repository into an empty directory, skipping `*.tmp` files |
| `help`, `--help` | | | Prints usage |

`--version` and `--sequence` on `product compose` and `publish` override `product.version` and `product.release_sequence` from `product.json`.

## Clock options

`publish`, `promote` and `sign` accept:

| Option | Default | Meaning |
|---|---|---|
| `--now <unix seconds>` | the current time | Signing time |
| `--days <n>` | 30 | Lifetime of snapshot, targets and channel metadata |
| `--timestamp-days <n>` | 1 | Lifetime of the timestamp |

## Errors you are likely to see

| Error | Exit code | Meaning |
|---|---|---|
| `PackSequenceNotIncreasing` | 3 | The release sequence is not greater than the channel's current one |
| `PackRepoEmpty` | 3 | `publish` without `--init`, `promote` or `sign` on a directory with no repository |
| `PackRepoNotEmpty` | 3 | `publish --init` on an existing repository |
| `PackRootKeyMismatch` | 3 | The key directory's root key is not the repository's root key |
| `PackTemplateHasArtifacts` | 3 | `product.json` already lists artifacts; leave them `{}` |
| `PackMissingArtifact` | 3 | A component in the manifest has no `--artifact` |
| `PackDuplicateArtifact` | 3 | Two artifacts for the same component and platform |
| `PackUnknownComponent` | 3 | An artifact's component id is not in the manifest |
