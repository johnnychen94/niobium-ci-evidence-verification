---
title: Implement App Bootstrap
description: Handle the installer's activate and deactivate requests in your application.
---

This guide adds App Bootstrap to your application so it can migrate its own data after an install, update or repair, and clean up before an uninstall. Read [Installer and App Bootstrap](/concepts/app-bootstrap/) first for why this lives in your application.

## 1. Declare the entrypoint

In the component's `component.json`, mark the entrypoint that handles bootstrap:

```json
"entrypoints": { "main": { "path": "bin/hello", "bootstrap": true } }
```

In `product.json`, point the manifest at it:

```json
"bootstrap": { "entrypoint": "runtime.main", "protocol": 1 }
```

The entrypoint may be your normal application binary: bootstrap mode is selected by its argument.

## 2. Recognize the call

`setup` starts the entrypoint with exactly one argument, `--installer-bootstrap-v1`, and no shell. Treat that argument as a separate mode of your program and do nothing else in it: no window, no network unless your migration needs it, no prompts.

## 3. Read the request

Standard input carries one JSON object, then closes:

```json
{ "protocol": 1, "operation": "activate", "transaction_id": "tx-3-...",
  "from_version": "1.1.0", "to_version": "1.2.0", "scope": "user",
  "install_root": "/Users/a/Library/Application Support/com.example.hello" }
```

- `operation` is `activate` after install, update or repair, and `deactivate` before uninstall.
- `from_version` is `null` on a first install.
- The same `transaction_id` can arrive again after a crash: make the work idempotent.

## 4. Answer

Write one line of JSON to standard output and exit with code 0 on success:

```json
{ "protocol": 1, "status": "ok", "message": "migrated 2 tables" }
```

Use `"status": "error"` with a message on failure. A non-zero exit code, a missing or invalid response, more than 64 KiB on standard output, or running longer than 120 seconds all count as failure.

## 5. Respect the limits

- The process runs as the user who started the installation, even for a machine-scope install, and never elevated. Do not try to elevate; declare machine-level needs, such as a service, in the manifest.
- Only `PATH`, `HOME`, `USERPROFILE`, `LANG`, `TMPDIR`, `TEMP`, `TMP` and `SystemRoot` are passed from the environment.
- After a failed `activate` the new version stays installed, `setup` exits with code 8 and the installation records bootstrap as pending until a later run succeeds.

## Example

The sample application in [`examples/hello/app/main.zig`](https://github.com/niobium-project/niobium/blob/main/examples/hello/app/main.zig) implements the protocol in about 70 lines of Zig: it parses the request, appends `<operation> <from> <to> <scope>` to a log file in the home directory, and answers `ok`. The [tutorial](/start/) shows its log after install, update and uninstall.

The normative protocol is [bootstrap-v1](https://github.com/niobium-project/niobium/blob/main/docs/spec/bootstrap-v1.md), with JSON Schemas for the [request](https://github.com/niobium-project/niobium/blob/main/api/schema/bootstrap-request-v1.schema.json) and the [response](https://github.com/niobium-project/niobium/blob/main/api/schema/bootstrap-response-v1.schema.json).
