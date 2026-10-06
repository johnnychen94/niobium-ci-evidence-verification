# Using Niobium from another repository

A product repository declares Niobium as a Zig package dependency and calls the functions of `@import("niobium")` in its own `build.zig` to produce component artifacts, a branded setup and an offline bundle. [`examples/hello`](../../examples/hello/build.zig) is built exactly this way: it is a standalone package that depends on this repository by path. `zig build example` builds it in a child process and puts the result in `zig-out/example/`.

The API is implemented in [`build/sdk.zig`](../../build/sdk.zig); the root `build.zig` is only a thin wrapper. v0.1 makes no API compatibility promise, so pin your dependency to a specific commit.

## Adding the dependency

```sh
zig fetch --save=niobium git+https://github.com/niobium-project/niobium#<commit>
```

For local development you can use a path dependency: `.niobium = .{ .path = "../niobium" }`. The package contains only the directories listed in `.paths` of `build.zig.zon`; third_party upstream files are downloaded on the first build according to `third_party/deps.zon` ([ADR-0011](../adr/0011-third-party-fetch.md)), after which builds work offline.

## Inputs the product repository provides

| File | Contract |
|---|---|
| `product.json`: the product template, with `components[].artifacts` left empty as `{}` | [manifest-v1](../spec/manifest-v1.md) |
| One `component.json` per component; when an executable path differs by platform (such as `.exe`), pick the file by target | [component-v1](../spec/component-v1.md) |
| Component file tree: the binaries and resources the application builds itself | [artifact-format-v1](../spec/artifact-format-v1.md) |
| `branding.json` (optional): GUI text, accent, logo | `branding` in [cli-v1](../spec/cli-v1.md) |

The application's business migration goes through App Bootstrap ([bootstrap-v1](../spec/bootstrap-v1.md)), not an installer hook.

## Functions

| Function | Output |
|---|---|
| `addComponent(b, target, component)` | `<id>.tar.zst` (`LazyPath`), the result of `nbpack component build` |
| `addBundle(b, options)` | `Bundle`: `keys`, `repository`, `product_config`, `setup`, `dir` |
| `addSetup(b, target, product_config)` | `setup` with `product_config` embedded (ReleaseSafe, ELF strip, the same settings as the `zig build cross` gate) |
| `nbpack(b)` | `nbpack` for the host, for subcommands not wrapped above (`promote`, `sign`, `component validate`) |

Fields of `Component`: `id` (the same as in `component.json`), `metadata`, `files` (a directory), `version`.

Fields of `BundleOptions`:

| Field | Default | Meaning |
|---|---|---|
| `target` | Required | Target for setup and artifacts |
| `product` | Required | `product.json` |
| `artifacts` | Required | Results of `addComponent`; all must be for `target` |
| `branding` | `null` | `branding.json` |
| `keys` | `null` | Output directory of `nbpack keygen`; when `null`, every clean build generates throwaway keys |
| `repository_url` | `null` | Repository address setup uses online; when `null`, setup can only be used offline |
| `days` | `365` | Validity in days of the new repository metadata |

`Bundle.dir` is the complete offline bundle: `setup`, `repository/` and `licenses/Inter-OFL.txt` ([offline-bundle](../runbooks/offline-bundle.md)). `examples/hello/build.zig` installs it to `zig-out/bundle/`.

## Keys and later releases

`addBundle` creates a new repository with `nbpack publish --init` every time, taking the trust root from `keys`.

- `keys = null` is only suitable for tests and demos: the keys change with the build cache, and later bundles cannot update a product installed from an earlier bundle.
- Production releases: generate and keep the keys outside the build; later versions are written to the same repository with `nbpack publish` following [release-signing](../runbooks/release-signing.md), without calling `addBundle` again.
- OS platform signing (codesign, signtool) changes the binary bytes and must be done before artifact hashes are computed; the setup and artifacts produced by `addBundle` carry no platform signature.

## Known limitations

The actual verification status on each platform is defined by [acceptance-plan-v0.1](../acceptance-plan-v0.1.md): real-OS smoke on Windows and Linux, machine scope and the manual GUI walkthrough are not done yet.
