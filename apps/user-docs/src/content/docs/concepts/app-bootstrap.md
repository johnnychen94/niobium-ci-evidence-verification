---
title: Installer and App Bootstrap
description: Where the installer's responsibility ends and the application's begins.
---

Niobium deploys files and OS integrations; your application owns everything that depends on what the application means. Moving a database schema, converting settings or registering with a license server are application semantics, and they run in your application's own process through App Bootstrap, not in an installer hook.

## The division

| The installer does | The application does, in App Bootstrap |
|---|---|
| Download, verify and unpack the release | Migrate its data from the previous version |
| Place files and switch the active version | Initialize per-user state |
| Create shortcuts, file associations, services, registration | Prepare for removal when uninstalled |
| Recover interrupted transactions | Make its own work idempotent and restartable |

This keeps the installer small and auditable, and keeps product-specific logic where it can be tested with the product.

## When it runs

After the commit of an install, update or repair, `setup` runs the entrypoint named by the manifest's `bootstrap.entrypoint` with the single argument `--installer-bootstrap-v1` and sends an `activate` request as JSON on standard input. Before an uninstall removes files, it sends `deactivate`. The application answers with one JSON line on standard output.

The process runs as the user who started the installation, even for a machine-scope install, with a minimal environment and a 120-second limit. It gets no shell and no elevated rights; anything that needs machine-level changes must be declared in the manifest.

## When it fails

- `activate` fails: the new version stays active, because the commit has already happened. `setup` exits with code 8 and the installation records bootstrap as pending; it is retried on a later run.
- `deactivate` fails: a warning is recorded and the uninstall continues.

Because a retry can repeat the same transaction after a crash, bootstrap must be idempotent and aware of which version it migrates from and to.

To implement the protocol, see [Implement App Bootstrap](/guides/app-bootstrap/).
