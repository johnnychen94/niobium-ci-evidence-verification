---
title: Publish and host
description: Create a repository, publish and promote releases on channels, serve the repository over HTTP, and ship offline bundles.
---

A Niobium repository is a directory of signed metadata and content-addressed files. You create it once, publish every release into it with `nbpack`, and either serve it over HTTP or copy it into offline bundles. This guide assumes you have component artifacts ([Package](/guides/package/)) and keys ([Sign and manage keys](/guides/sign-and-keys/)).

## Create the repository with the first release

```sh
nbpack publish --init --repo repo/ --keys keys/ --product product.json \
  --artifact runtime-macos-aarch64.tar.zst --artifact runtime-windows-x86_64.tar.zst
```

`--init` creates the root metadata from your keys and fails if the directory already holds a repository. `addBundle` in `build.zig` does the same for a fresh repository on every build; for a repository you keep, run `publish` yourself as shown here.

## Publish later releases

Raise `product.release_sequence` (and usually `product.version`) in `product.json`, build the artifacts, then:

```sh
nbpack publish --repo repo/ --keys keys/ --product product.json \
  --artifact runtime-macos-aarch64.tar.zst --artifact runtime-windows-x86_64.tar.zst \
  --channel beta
```

- `--channel` is `stable` (default), `beta` or `nightly`.
- `--version <x.y.z>` and `--sequence <n>` override the values in `product.json`.
- `publish` refuses a sequence that is not greater than the channel's current one (`PackSequenceNotIncreasing`, exit code 3).

`publish` composes the release manifest (filling each component's artifact digests), stores manifest and artifacts under `targets/<sha256>`, signs the channel and targets metadata, then snapshot, and writes `timestamp.json` last. To produce the manifest without signing anything, use `nbpack product compose --product product.json --artifact ... --out manifest.json`.

## Promote a release

After testing the bytes on `beta`, point `stable` at the same release:

```sh
nbpack promote --repo repo/ --keys keys/ --product-id com.example.hello --sequence 3 --channel stable
```

`promote` only rewrites and re-signs metadata; nothing is rebuilt or repacked ([Channels and promotion](/concepts/channels/)).

## Point setup at the repository

`setup` needs to know the repository address and trust its root. Both are compiled into a branded `setup`:

```sh
nbpack config --repo repo/ --product product.json --branding branding.json \
  --repository https://dl.example.com/hello --channel stable --out product-config.json
```

Build `setup` with that configuration, either with `addSetup(b, target, config)` in your `build.zig` or, from a Niobium checkout, with `zig build -Dproduct-config=product-config.json`. In `addBundle`, the `repository_url` option passes `--repository` for you.

`setup` chooses the repository in this order: the `--repo` option, then a `repository/` directory next to the `setup` executable, then the address in its configuration. Without any of them, `install`, `update` and `repair` stop with a usage error (exit code 2).

## Serve over HTTP

Upload the repository directory as static files; the HTTP layout is the directory layout. Because `timestamp.json` is the entry point that names everything else, upload new files under `metadata/` and `targets/` first and replace `timestamp.json` last, the same order `nbpack` writes them in. Never edit files on the server: every change goes through `nbpack` and is uploaded again.

Remember that the timestamp expires after one day by default: run `nbpack sign` and upload the result at least that often.

## Ship an offline bundle

An offline bundle is a directory with `setup`, a full copy of the repository and the font license:

```sh
nbpack bundle --repo repo/ --setup zig-out/bin/setup --out Hello-1.2.0-offline/
```

`--out` must be empty. Then copy Inter's license (fetched by the Niobium build) to `Hello-1.2.0-offline/licenses/Inter-OFL.txt`. `addBundle` produces the complete directory, license included, as `Bundle.dir`.

On the target machine, `setup install` uses the bundled `repository/` and the root embedded in `setup`, with the same verification as online. Bundle metadata expires like any other, so sign the repository with lifetimes that cover the bundle's intended use (`--days`, `--timestamp-days`); `addBundle` uses 365 days for both. The procedure is also in the [offline bundle runbook](https://github.com/niobium-project/niobium/blob/main/docs/runbooks/offline-bundle.md).
