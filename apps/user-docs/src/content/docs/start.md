---
title: 'Tutorial: your first release'
description: Build the sample product with the Niobium build API, sign it with development keys, install it, publish an update and uninstall it.
---

In this tutorial you take the sample product `Hello`, build it as your own product repository would, sign it with throwaway development keys, install it from a local repository, publish a second release, update to it and uninstall it. It takes about fifteen minutes, most of it the first build.

The commands are for a POSIX shell. This walkthrough was run end to end on macOS (arm64); on Linux and Windows the install paths differ, as noted where they appear.

## Before you start

- **Zig 0.17.0.** Niobium has no prebuilt binaries: `setup` and `nbpack` are compiled from source by your build.
- **git**, to get the sample.
- **Network access on the first build**: Zig downloads Niobium from GitHub, and Niobium's build downloads a few pinned upstream sources (stb_truetype, zstd, the Inter font). Later builds work offline.

## 1. Get the sample product

```sh
git clone https://github.com/niobium-project/niobium
cp -R niobium/examples/hello hello
cd hello
```

`hello` now holds a complete product repository: the application source (`app/`), two components (`components/runtime`, `components/docs`), the product manifest template (`product.json`), installer branding (`branding.json`) and a `build.zig` that calls the Niobium build API.

## 2. Depend on a pinned Niobium commit

Open `build.zig.zon` and delete the `.niobium = .{ .path = "../.." },` entry and the comment above it. Then add Niobium as a URL dependency pinned to the commit you cloned:

```sh
zig fetch --save=niobium "git+https://github.com/niobium-project/niobium#$(git -C ../niobium rev-parse HEAD)"
```

`build.zig.zon` now contains a `.url` and a `.hash` for `niobium`. Delete the path entry first: when it is still there, `zig fetch --save` writes the URL into its `.path` field and the build fails.

## 3. Install the publisher tool and the artifacts

`build.zig` already builds two component artifacts with `niobium.addComponent` and an offline bundle with `niobium.addBundle`. To sign later releases you also need `nbpack` and the artifact files. Add three lines just before `b.installDirectory(...)` at the end of `build`:

```zig
    b.installArtifact(niobium.nbpack(b));
    b.getInstallStep().dependOn(&b.addInstallFile(runtime, "artifacts/runtime.tar.zst").step);
    b.getInstallStep().dependOn(&b.addInstallFile(docs, "artifacts/docs.tar.zst").step);
```

Build:

```sh
zig build
```

The first build compiles `setup` and `nbpack` and can take a minute or more. It leaves:

```text
zig-out/bin/nbpack                  the publisher tool
zig-out/artifacts/runtime.tar.zst   component artifacts
zig-out/artifacts/docs.tar.zst
zig-out/bundle/setup                the branded installer
zig-out/bundle/repository/          a signed TUF repository holding release 1
zig-out/bundle/licenses/
```

## 4. Generate development keys

This first bundle was signed with keys generated inside the build cache, which change from one clean build to the next. Generate keys you keep:

```sh
zig-out/bin/nbpack keygen --out keys
```

`keys/` holds one `<role>.key.json` per signing role (root, targets, snapshot, timestamp, channel); on macOS and Linux each file has mode 0600. These are development keys: do not commit them and do not use them for a real release ([Sign and manage keys](/guides/sign-and-keys/)).

In `build.zig`, pass them to `addBundle` by adding one field after `.artifacts = &.{ runtime, docs },`:

```zig
        .keys = b.path("keys"),
```

Then build again and copy the signed repository to a directory you will publish into:

```sh
zig build
cp -R zig-out/bundle/repository repo
```

`repo/` is your local repository. `setup` reads it the same way it would read one served over HTTP.

## 5. Install

```sh
zig-out/bundle/setup install --scope user --repo repo
```

`setup` prints each phase (`recover`, `discover`, `resolve`, ... `complete`) and ends with:

```text
installed com.example.hello 1.0.0 (user) in /Users/you/Library/Application Support/com.example.hello
```

Check the result and run the application:

```sh
zig-out/bundle/setup status
"$HOME/Library/Application Support/com.example.hello/current/runtime/bin/hello"
```

```text
com.example.hello 1.0.0 (user, stable) in /Users/you/Library/Application Support/com.example.hello
Hello from the Niobium sample product.
```

On Linux the install root is `~/.local/share/com.example.hello`; on Windows it is `%LOCALAPPDATA%\Programs\com.example.hello` and the binary is `hello.exe`.

After the commit, `setup` ran the application's [App Bootstrap](/concepts/app-bootstrap/) entrypoint. The sample records each call in `~/.hello-bootstrap.log`, which now reads `activate - 1.0.0 user`.

## 6. Publish a second release

Raise the version in two places:

- in `build.zig`, change `const version = "1.0.0";` to `"1.1.0"`;
- in `product.json`, set `"version": "1.1.0"` and `"release_sequence": 2`.

`release_sequence` is the number that orders releases; it must grow with every release, while the version text is free ([Channels and promotion](/concepts/channels/)). Rebuild the artifacts and sign them into your repository:

```sh
zig build
zig-out/bin/nbpack publish --repo repo --keys keys --product product.json \
  --artifact zig-out/artifacts/runtime.tar.zst --artifact zig-out/artifacts/docs.tar.zst
```

```text
published to stable (timestamp 2)
```

Running the same `publish` again fails with `nbpack: PackSequenceNotIncreasing` and exit code 3: a release sequence can be used once.

## 7. Update

```sh
zig-out/bundle/setup update --silent --repo repo
zig-out/bundle/setup status
```

```text
com.example.hello 1.1.0 (user, stable) in /Users/you/Library/Application Support/com.example.hello
```

The bootstrap log gained `activate 1.0.0 1.1.0 user`. Running `update` again exits 0 without changes.

The metadata `nbpack publish` writes expires: the timestamp after one day, the rest after 30 days. If you return to this tutorial later and `update` fails with exit code 4, refresh the signatures with `zig-out/bin/nbpack sign --repo repo --keys keys`.

## 8. Uninstall

Every installation keeps a copy of `setup`, the maintainer, inside its install root. Use it to uninstall:

```sh
"$HOME/Library/Application Support/com.example.hello/maintainer/setup" uninstall --silent
```

The install root is gone, and the bootstrap log ends with `deactivate 1.1.0 1.1.0 user`: the application was told before its files were removed. `setup status` now exits with code 12, product not installed.

## What you did

You built a product with the Niobium build API, signed it into a TUF repository, installed it, published and applied an update, and uninstalled it. Every step went through the same signature checks and transactions a real release uses; only the keys were throwaway.

Next:

- [Package your product](/guides/package/) to write your own manifest and components;
- [Sign and manage keys](/guides/sign-and-keys/) before your first real release;
- [Publish and host](/guides/publish-and-host/) to serve a repository or ship offline bundles.
