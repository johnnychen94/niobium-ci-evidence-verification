---
title: Privilege boundary
description: How machine-wide installs get elevated rights without running arbitrary code as administrator.
---

A user-scope install needs no elevation: everything lives in the user's own directories. A machine-scope install writes to system locations, so it needs administrator rights, and Niobium grants them as a closed capability rather than as a general-purpose elevated process.

## The helper

For a machine-scope transaction, `setup` starts a second copy of itself with administrator rights (through the system authorization prompt, `runas`, `pkexec` or `sudo`, depending on the platform). This helper:

- exists only for the duration of one transaction;
- accepts only a fixed list of typed operations: create a directory, write, append or copy a file, rename, remove a file or tree, set or remove the `current` pointer, prepare, activate, discard or remove an integration, and report free space;
- has no operation that runs a program, loads a library or opens a network connection;
- authenticates every message with the transaction id and a random nonce, and rejects replayed message ids.

The unelevated `setup` downloads and verifies the release and stages it in the user's cache; the helper copies the staged files into place.

## Where the helper may write

The helper computes its own policy and does not take paths from the unelevated side:

- it writes only inside `<install base>/<product id>`, where the install base is `/Library/Application Support` on macOS, `%ProgramFiles%` on Windows and `/opt` on Linux;
- integrations go only to the system integration directories it knows;
- copy sources must be in the staging area or the install root, and are opened without following symbolic links; files with more than one hard link are refused.

## What the boundary does not cover

The helper restricts where it writes, not what it writes. The content was verified against the signed release by the unelevated process. If an attacker already controls the installing user's session, they can make the helper write arbitrary content into that product's machine install root and register services or shortcuts for it; they cannot use it to write into other products or arbitrary system locations. This residual risk is accepted.

Embedding hosts that use the [C ABI](/guides/embed-c-abi/) never get an elevation prompt: machine scope works there only when the host process is already elevated.

## Status

Machine-scope installs on a real Windows or Linux system have not been verified yet; see N1-UJ-02 on [Status and platforms](/status/). The wire protocol is specified in [ipc-v1](https://github.com/niobium-project/niobium/blob/main/docs/spec/ipc-v1.md).
