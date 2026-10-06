---
title: Glossary
description: Terms used in the Niobium documentation.
---

The project's canonical glossary, including internal terms, is [GLOSSARY.md](https://github.com/niobium-project/niobium/blob/main/GLOSSARY.md). This page lists the terms the user documentation relies on.

**Active version.** The version the install root's `current` pointer names. It is only ever the old or the new version of a transaction.

**App Bootstrap.** The protocol through which the installer asks your application, after a commit or before an uninstall, to perform its own migration. See [Installer and App Bootstrap](/concepts/app-bootstrap/).

**Artifact.** An immutable file identified by its SHA-256 digest. A component artifact is a `tar.zst` holding `component.json` and `files/`.

**Capability.** One of the closed set of things the installer can do to a machine: managed files, directories, shortcuts, file associations, services and application registration.

**Channel.** A signed pointer, `stable`, `beta` or `nightly`, from a channel name to one release.

**Commit.** The atomic switch of `current` to the new version; the point of no return of a transaction.

**Component.** A deployable unit of files with named entrypoints, built into one artifact per platform. It carries no scripts and no absolute paths.

**Entrypoint.** A named executable inside a component, referenced as `<component>.<name>` by integrations, App Bootstrap and Portable Run.

**Maintainer.** The copy of `setup` kept in `maintainer/` of an install root, used for later updates, repairs and uninstalls.

**Manifest.** The JSON description of one release: product, components, artifacts, integrations, bootstrap.

**Offline bundle.** A directory with `setup` and a complete repository, installable without network access.

**Portable Run.** Running a component from a verified, content-addressed cache without installing it (`setup run`).

**Product.** What a user installs: a set of components with an id such as `com.example.hello`.

**Recovery.** The step `setup` runs before anything else, which completes or rolls back an interrupted transaction.

**Release sequence.** `release_sequence`, the integer that orders releases and protects against rollback, independent of the application version.

**Repository.** The signed TUF metadata and content-addressed files that `nbpack` writes and `setup` reads.

**Scope.** `user` (installed for one user, no elevation) or `machine` (installed for all users, needs administrator rights).

**Staging.** The directory where a new version is unpacked before it becomes active.

**Transaction.** One install, update, repair or uninstall, journaled so that it ends at the old or the new version.

**TUF.** The Update Framework, the specification Niobium's repository signing follows. See [Trust model](/concepts/trust/).
