---
title: Niobium
description: A native, declarative, transactional installation and distribution framework written in Zig.
---

Niobium installs, updates, repairs and uninstalls desktop software from a signed release description. You describe a release as data, Niobium packs and signs it, and a small native `setup` executable applies it as a transaction: after a crash at any moment, the machine holds either the old version or the new one, never a mix.

Niobium is at version 0.1 and makes no compatibility promise yet. What has and has not been verified is listed on one page: [Status and platforms](/status/).

## Principles

1. **The manifest is data, never code.** There are no install scripts, shell commands or `exec` fields.
2. **Desired state, not execution steps.** You declare what should be installed; Niobium plans the steps.
3. **The installer deploys; the application migrates.** Business logic such as database upgrades runs in your application through [App Bootstrap](/concepts/app-bootstrap/).
4. **Privilege is a closed capability.** The elevated helper accepts only a fixed set of typed file and integration operations.
5. **Installation is transactional.** Recovery after a crash reaches only the old or the new version.
6. **No runtime extensions.** There are no plugins, hooks or custom libraries loaded by the installer.

## How a release flows

1. **Describe.** Write a `product.json` manifest and one `component.json` per component, next to the files your own build produces.
2. **Pack and sign.** `nbpack` turns each component into an immutable `tar.zst` artifact, composes the release manifest and signs it into a [TUF](/concepts/trust/) repository. Your `build.zig` drives this through the Niobium build API.
3. **Publish and install.** Serve the repository over HTTP or ship it in an offline bundle. Users run `setup`, which verifies the signatures and applies the release as a transaction.

[Tutorial: your first release](/start/) walks through all three steps with the sample product.

## Is it right for you?

Niobium may fit when:

- you ship native desktop software for macOS, Windows or Linux and want one installer model across them;
- you want installs and updates that cannot be left half-applied;
- you want release authorization (who may publish what, rollback protection) separate from the application version;
- you can build from source with Zig 0.17: there are no prebuilt Niobium binaries.

Niobium does not fit when:

- you need install-time scripts or custom actions: the framework rejects them by design;
- you need a capability outside its closed set (shortcuts, file associations, services, application registration, managed files);
- you need a production-ready installer today: real-OS verification on Windows and Linux, machine-wide installs and OS code signing are not done yet ([Status and platforms](/status/));
- you need a platform outside the short [supported list](/platforms/), or a support commitment: Niobium is a hobby project maintained on a best-effort basis ([About the project](/about/)).

## What each section is for

| Section | Use it to |
|---|---|
| [Tutorial](/start/) | Build, sign, install, update and uninstall the sample product once, end to end |
| [Concepts](/concepts/desired-state/) | Understand the model: manifests, artifacts, transactions, privilege, trust, channels |
| [Guides](/guides/package/) | Do one task: package, sign, publish, implement App Bootstrap, embed, install silently |
| [Security](/security/) | Learn what Niobium defends against, what it does not, and how to report a problem |
| [Status and platforms](/status/) | Check what has been verified, on which platform, with which result |
| [Platform support](/platforms/) | See which platforms are targeted, at which support tier, and what comes next |
| [Troubleshooting](/troubleshooting/) | Map an exit code or failure to its cause, and find logs |
| [About the project](/about/) | Learn why Niobium exists, who maintains it, and what support to expect |
| [Reference](/reference/manifest/) | Look up fields, commands, exit codes, events and the C ABI |

The source, specifications and issue tracker are on [GitHub](https://github.com/niobium-project/niobium).
