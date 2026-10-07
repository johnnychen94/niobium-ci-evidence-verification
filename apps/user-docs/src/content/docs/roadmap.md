---
title: Roadmap
description: What Niobium can do today, what is being built now, what comes next, and what is not planned.
---

This page lists features in the order they are planned, described by what they do for you and for the people who install your software. It carries no dates: Niobium is maintained by one person in spare time ([About the project](/about/)), so the order is a commitment and the timing is not.

The roadmap says what is planned, not what works. Whether a feature has been verified, and on which platform, is recorded only on [Status and platforms](/status/). Plans for individual platforms are on [Platform support](/platforms/#roadmap).

| Mark | Meaning |
|---|---|
| ✅ | Available in Niobium 0.1; its verification status is on [Status and platforms](/status/) |
| 🚧 | Being built now for the next release, numbered in priority order |
| 🔜 | Next, after the current work |
| 🗓️ | Later |
| ⛔ | Not planned, on purpose |

## Features

| Status | Feature | What it means for you |
|---|---|---|
| ✅ | Online and offline installs | Users install from a repository you host over HTTP, or from an offline bundle on a disk or share ([Publish and host](/guides/publish-and-host/)) |
| ✅ | Release channels | `stable`, `beta` and `nightly` let you test a release with some users before everyone gets it, without rebuilding it ([Channels and promotion](/concepts/channels/)) |
| ✅ | Install, update, repair and uninstall | Every change is a transaction, so a crash or power cut never leaves a half-installed application ([Transactions](/concepts/transactions/)) |
| ✅ | Safe rollback | To withdraw a bad release, you publish a new one with the previous good version; installations move to it like to any other update |
| ✅ | Portable Run | A component runs from a verified cache without being installed ([Artifacts and Portable Run](/concepts/artifacts/#portable-run)) |
| ✅ | Updates from inside your app | Your application checks for, downloads and applies updates itself through `libdistribution` ([Embed through the C ABI](/guides/embed-c-abi/)) |
| 🚧 1 | Built-in feature modules | Each system integration and distribution feature becomes one self-contained module inside Niobium, tested the same way on every platform. New integrations arrive faster, and the aim is that your `setup` contains only the modules your product uses |
| 🚧 2 | Presets and themes | Start from a preset for your kind of product (desktop application, command-line tool, Electron application, background service), pick a theme for the installer window, and set your name, logo and colour. You get an installer ready to sign and publish without writing every field by hand, and a preview before you publish |
| 🚧 3 | Production-ready on macOS, Windows and Linux | Tested on real machines, installs for all users of a machine proven, and `setup` signed with Authenticode and Apple Developer ID ([Platform code signing](/guides/sign-and-keys/#platform-code-signing)), so your users don't see "unknown publisher" or Gatekeeper warnings |
| 🚧 4 | Easier to adopt | Prebuilt `setup`, `nbpack` and `libdistribution`, and a compatibility promise for the build API. You can try Niobium without installing Zig and upgrade it without rewriting your build |
| 🚧 5 | More system integrations | Open your application from `myapp://` links, add a command-line tool to `PATH`, and set environment variables, all removed cleanly on uninstall and without install scripts |
| 🚧 6 | In-app updates for any application | Your application updates itself with the same signatures and transactions as `setup`. An Electron and Node.js package comes first; other languages call the C ABI, with examples |
| 🔜 | Online, offline-file and SFX delivery | Three milestones: a signed online installer, one complete offline file opened or unpacked before installation, and a self-extracting offline installer (SFX) requiring no separate unpacking step. Platform formats and verification remain planned ([delivery decision](https://github.com/niobium-project/niobium/blob/main/docs/adr/0020-distribution-delivery-milestones.md)) |
| 🔜 | What's new | Release notes in the installer and in your application's update prompt, signed together with the release so they cannot be swapped |
| 🔜 | Start at login | Your application registers to start when the user signs in, with no script or manual step |
| 🔜 | Key rotation from `nbpack` | Replace a lost or expired signing key without breaking existing installations; clients already accept rotated keys ([Sign and manage keys](/guides/sign-and-keys/#rotate-or-recover-keys)) |
| 🔜 | A security policy | A published policy with a private channel for reporting vulnerabilities ([Security](/security/#report-a-vulnerability)) |
| 🗓️ | Screen-reader support | People who use screen readers can install your software, on all three platforms |
| 🗓️ | A native folder picker on Linux | Choosing an install location looks and works like the rest of the desktop |
| 🗓️ | The installer window in the user's language | Users install in the language they read |
| 🗓️ | More platforms | Windows on ARM, Kylin and UOS, among the candidates on [Platform support](/platforms/#candidates) |
| ⛔ | Install scripts and custom actions | The manifest is data. Product-specific work such as a database migration runs in your application through [App Bootstrap](/concepts/app-bootstrap/) |
| ⛔ | Third-party plugins and runtime extensions | Feature modules are built into Niobium and reviewed with it; `setup` loads nothing else |
| ⛔ | Running arbitrary commands with administrator rights | The elevated helper accepts only a fixed set of typed operations ([Privilege](/concepts/privilege/)) |
| ⛔ | A native Wayland backend | On Wayland the installer window runs through XWayland ([Platform support](/platforms/#not-planned)) |

Feature modules are part of Niobium itself: you still describe your product as data, and nothing outside Niobium is loaded at install time. The items marked ⛔ are left out so that installs stay predictable and auditable.
