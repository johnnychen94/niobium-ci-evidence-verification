---
title: Channels and promotion
description: How releases reach stable, beta and nightly users, and why promotion changes only metadata.
---

A channel is a signed pointer from a channel name to one release of a product. Moving users to a new release means re-signing that pointer; the artifacts are never rebuilt or repacked. The rule behind this: build once, sign once, test the final bytes, then promote by metadata only.

## The three channels

Niobium has three fixed channels: `stable`, `beta` and `nightly`. Each is a delegated TUF role whose only content is `manifests/<product id>.json` with that release's `release_sequence` and application version.

A branded `setup` takes its channel from the product configuration that `nbpack config --channel` wrote (default `stable`); the command-line option `--channel` overrides it. Each installation records the channel it was installed from, and `setup status` shows it.

## Publishing and promoting

- `nbpack publish ... --channel beta` adds a new release (manifest and artifacts) to the repository and points `beta` at it. Without `--channel`, it publishes to `stable`.
- `nbpack promote --product-id <id> --sequence <n> --channel stable` points `stable` at a release that is already in the repository. It writes and signs metadata only.

A typical flow is to publish to `beta`, run compatibility tests against exactly the bytes users will receive, then promote the same sequence to `stable`. The commands are in [Publish and host](/guides/publish-and-host/).

## Ordering and rollback

Within a channel, `release_sequence` must strictly increase: `nbpack publish` refuses a sequence that is not greater than the channel's current one, and `setup update` refuses to move an installation to a lower one. The application `version` is free.

To withdraw a bad release, publish a new release with a higher sequence that contains the previous good application version. Installations update to it like to any other release; nothing about the old release has to be deleted. This path is covered by acceptance entry N1-UJ-04 on [Status and platforms](/status/).
