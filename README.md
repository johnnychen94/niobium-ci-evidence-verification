# Niobium

[![codecov](https://codecov.io/gh/niobium-project/niobium/graph/badge.svg)](https://codecov.io/gh/niobium-project/niobium)

English | [Chinese](README.zh.md)

A native, declarative, transactional installation and distribution framework written in Zig: a small, auditable deployment substrate with deliberately limited semantics.

- **The manifest is data, not code**: no pre/post install scripts, no exec.
- **Transactional**: after a crash at any moment, recovery reaches only the old version or the new one.
- **TUF trust**: release authorization, freshness and rollback protection; `release_sequence` is separate from the application version.
- **Library-first**: the GUI, the CLI and the C ABI share one engine.
- **Own UI**: a closed component vocabulary + tokens + a software renderer, embedded in native AppKit / Win32 / X11 windows.

## Quick start

Requires Zig 0.17.0.

```sh
zig build                 # host binaries: zig-out/bin/setup, nbpack
zig build test            # unit tests
zig build verify          # definition-of-done gate (check + test + sim + golden + e2e + example + cross + size-gate)
zig build gallery         # UI component gallery PNGs -> .evidence/ui-gallery/
```

Pull requests run on GitHub Actions. The required check is `CI / linux`. Code changes also run `zig build test` and `zig build c-smoke`; the full `zig build verify` gate runs daily when `main` has new commits. See [testing lanes](docs/development/testing-lanes.md).

## Example product

`examples/hello` is a standalone Zig package that depends on this repository and builds the same way any other product repository would ([using Niobium from another repository](docs/development/consuming.md)).

```sh
zig build example                                        # offline bundle: zig-out/example/
zig-out/example/setup install --silent --scope user
zig-out/example/setup status --json
```

## Roadmap

✅ available in 0.1 · 🚧 being built now, in priority order · 🔜 next · 🗓️ later · ⛔ not planned. Verification results are on [Status and platforms](apps/user-docs/src/content/docs/status.md).

| Status | Feature |
|---|---|
| ✅ | Online and offline installs |
| ✅ | Release channels (`stable`, `beta`, `nightly`) |
| ✅ | Install, update, repair and uninstall as transactions |
| ✅ | Safe rollback |
| ✅ | Portable Run |
| ✅ | Updates from inside your app through the C ABI |
| 🚧 1 | Built-in feature modules |
| 🚧 2 | Presets and themes for building installers quickly |
| 🚧 3 | Production-ready on macOS, Windows and Linux: real-OS testing, machine-wide installs, OS code signing |
| 🚧 4 | Easier to adopt: prebuilt downloads and a stable build API |
| 🚧 5 | More system integrations: `myapp://` links, `PATH` and environment variables |
| 🚧 6 | In-app updates for any application, Electron and Node.js first |
| 🔜 | "What's new" release notes, signed with the release |
| 🔜 | Start at login |
| 🔜 | Key rotation from `nbpack` |
| 🔜 | A security policy with a private reporting channel |
| 🗓️ | Screen-reader support |
| 🗓️ | A native folder picker on Linux |
| 🗓️ | The installer window in the user's language |
| 🗓️ | More platforms: Windows on ARM, Kylin, UOS |
| ⛔ | Install scripts, custom actions, plugins and runtime extensions |
| ⛔ | Running arbitrary commands with administrator rights |
| ⛔ | A single-file self-extracting installer |
| ⛔ | A native Wayland backend |

What each feature means for you, and why the ⛔ items are left out: [Roadmap](apps/user-docs/src/content/docs/roadmap.md).

## Background

Niobium is an independent open source installer framework, maintained by its author in spare time. It grew out of installer needs encountered while working at TongYuan and is designed as a general-purpose framework. The project is maintained independently, without direct support or direction from TongYuan. Maintenance is best effort, with a focused platform scope: see [About the project](apps/user-docs/src/content/docs/about.md) and [Platform support](apps/user-docs/src/content/docs/platforms.md).

## Documentation

- User documentation (English and Chinese): https://niobium-project.dev
- Feature roadmap: [Roadmap](apps/user-docs/src/content/docs/roadmap.md)
- Platform tiers and roadmap: [Platform support](apps/user-docs/src/content/docs/platforms.md)
- Conventions: [AGENTS.md](AGENTS.md)
- Glossary: [GLOSSARY.md](GLOSSARY.md)
- Docs index: [docs/README.md](docs/README.md)
- Development roadmap and deferred items: [docs/roadmap-v0.2.md](docs/roadmap-v0.2.md)
- Acceptance status: [docs/acceptance-plan-v0.1.md](docs/acceptance-plan-v0.1.md)

## License

[MIT](LICENSE)
