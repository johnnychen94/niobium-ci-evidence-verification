# TUF key rotation

> NOTE: `nbpack` in v0.1 has no root rotation command. `nbpack keygen` generates keys for all five roles (root, targets, snapshot, timestamp, channel) at once; `publish`, `promote` and `sign` refuse to sign when the root public key in the key directory does not match the repository root (`PackRootKeyMismatch`). The client already verifies `N+1.root.json` along the version chain (`libs/trust`); the procedure below describes publisher-side steps that are not yet implemented.

## Routine root rotation

1. Generate new keys on an offline machine.
2. Generate `N+1.root.json`: the new root must be signed by both the old root threshold and the new root threshold.
3. Re-sign timestamp and snapshot (versions increase): `nbpack sign --repo <dir> --keys <dir>`.
4. Clients verify each step along the version chain; setup does not need to be redistributed.

## Online key compromise (timestamp, snapshot, channel)

1. Use root to produce a new root version that replaces the compromised role's keys.
2. Bump the versions of the affected metadata and re-sign; metadata signed with the old key becomes invalid immediately because the keyid in root changed.
3. Record the incident and the affected time window.

## Root key compromise

A new setup (embedding the new root) must be distributed out of band; follow the incident-handling process.
