# App Bootstrap Protocol v1

- **Status:** Baseline

Bootstrap lets the application perform its own business migration after the installer has completed machine deployment. The code belongs to the application, not to the installer protocol.

## Invocation

- Executable: the entrypoint named by the manifest's `bootstrap.entrypoint` (with `bootstrap: true` in the component metadata), located under `current/<component>/`.
- Arguments: exactly one, `--installer-bootstrap-v1`. No other arguments are passed, and no shell is involved.
- Identity: always runs as the ordinary user who started the installation, even when scope is `machine`.
- Environment: only a minimal environment is inherited (`PATH`, `HOME`, `USERPROFILE`, `LANG`, `TMPDIR`, `TEMP`, `TMP`, `SystemRoot`); no other variables are passed.
- Timeout: 120 seconds; a timeout counts as failure, and a watchdog thread forcibly terminates the child process. stdout exceeding 64 KiB likewise terminates the process and counts as failure.
- Location: at commit, the entrypoint's path relative to `current/` is written to `bootstrap_target` in `installation.json`; both `deactivate` and `bootstrap_pending` retries use it, so the manifest need not be resolved again.
- Implementation: `libs/bootstrap` (`bootstrap.run`), called by `libs/engine/commit.zig`.

## Request (stdin, a single JSON object, then stdin is closed)

```json
{ "protocol": 1, "operation": "activate", "transaction_id": "tx-3-…",
  "from_version": "1.1.0", "to_version": "1.2.0", "scope": "user",
  "install_root": "/Users/a/Library/Application Support/com.example.hello" }
```

`operation`: `activate` (after the commit of install/update/repair) or `deactivate` (before uninstall removes files). `from_version` is `null` on first install.

## Response (stdout, single-line JSON, ≤ 64 KiB)

```json
{ "protocol": 1, "status": "ok", "message": "migrated 2 tables" }
```

`status` is `ok` or `error`. A non-zero exit code, a timeout, or a missing or invalid response all count as failure.

## Semantics

- Must be idempotent, restartable, and version-aware; the installer may retry with the same `transaction_id` after crash recovery.
- `activate` failure: the new version stays Active (the commit has completed), `installation.json` records `bootstrap_pending`, and the CLI exit code is 8; it is retried the next time the maintainer runs.
- `deactivate` failure: a warning is recorded and uninstall continues.
- Any required machine-level capability (service, etc.) must be declared in the manifest; bootstrap must not elevate on its own.
