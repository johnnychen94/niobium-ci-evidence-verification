# Niobium

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

## Example product

`examples/hello` is a standalone Zig package that depends on this repository and builds the same way any other product repository would ([using Niobium from another repository](docs/development/consuming.md)).

```sh
zig build example                                        # offline bundle: zig-out/example/
zig-out/example/setup install --silent --scope user
zig-out/example/setup status --json
```

## Documentation

- Conventions: [AGENTS.md](AGENTS.md)
- Glossary: [GLOSSARY.md](GLOSSARY.md)
- Docs index: [docs/README.md](docs/README.md)
- Roadmap and deferred items: [docs/roadmap-v0.1.md](docs/roadmap-v0.1.md)
- Acceptance status: [docs/acceptance-plan-v0.1.md](docs/acceptance-plan-v0.1.md)

## License

[MIT](LICENSE)
