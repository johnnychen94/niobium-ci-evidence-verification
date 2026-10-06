---
title: Desired-state manifest
description: Why a Niobium release is described as data, and what the installer derives from it.
---

A Niobium release is a JSON document that states what should be on the machine, not how to put it there. The installer compares that desired state with what is installed and plans the operations itself. Nothing in the manifest is executed.

## What the manifest says

The product manifest names the product, its release, the components and their artifacts per platform, the OS integrations to create, and the App Bootstrap entrypoint:

- **product**: a reverse-domain `id`, display `name`, `publisher`, `version` text and `release_sequence`;
- **install**: which scopes (`user`, `machine`) are allowed and which is the default;
- **components**: each with an `id`, a title, whether it is required or selected by default, and one artifact digest per platform;
- **integrations**: shortcuts, file associations and services, each pointing at a named entrypoint of a component;
- **bootstrap**: the entrypoint that implements [App Bootstrap](/concepts/app-bootstrap/);
- **experience**: accent color, license and welcome text, icon.

Field-level rules are in the [manifest reference](/reference/manifest/).

## Why data and not scripts

Install scripts are where installers usually go wrong: they run with elevated rights, they cannot be rolled back, and they turn every product into a special case. Niobium removes them:

- unknown fields are rejected at every level, and the fields `pre_install`, `post_install`, `script`, `exec`, `shell` and `command` are rejected wherever they appear;
- a manifest with a newer `schema`, or a `min_installer` above the running installer, fails closed instead of being half understood;
- what the installer can do to a machine is a closed set of capabilities: managed files and directories, shortcuts, file associations, services and application registration.

A product that needs something else, such as migrating its data, does it in its own process through App Bootstrap, after the installer has finished deploying files.

## From desired state to a plan

When you run `setup install`, `update`, `repair` or `uninstall`, the engine:

1. resolves the release from the signed repository and verifies it ([trust model](/concepts/trust/));
2. combines the manifest with your choices (scope, components, install directory) into a desired state;
3. reads the installed state from the install root;
4. compiles the difference into a typed plan of operations, each with an apply, a rollback and a verify step;
5. executes the plan as a [transaction](/concepts/transactions/).

The GUI and the command line build the same request and run the same engine path, so a choice made in the window and the equivalent command produce the same plan.

## Where things go

The framework decides every machine path from the scope and the product id; components only contain relative paths. For example, a user-scope install on macOS lives in `~/Library/Application Support/<product id>`, and a machine-scope install on Linux in `/opt/<product id>`. The full table is in [repository and install layout](/reference/repository-layout/).
