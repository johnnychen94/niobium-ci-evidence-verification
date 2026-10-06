# Installer TUF Profile v1

- **Status:** Baseline
- **Decision:** [ADR-0004](../adr/0004-tuf-profile-v1.md)

## Repository layout

```text
metadata/<N>.root.json          one per root version
metadata/timestamp.json          the only unversioned file
metadata/<N>.snapshot.json
metadata/<N>.targets.json
metadata/<N>.<channel>.json      stable / beta / nightly delegated roles
targets/<sha256hex>              content-addressed target bytes (manifest, artifact, portable)
```

HTTP and directory sources have the same layout; an offline bundle puts the same directory under `repository/`.

## Metadata format

```json
{ "signed": { "_type": "timestamp", "spec_version": "1.0", "version": 7,
              "expires": "2026-10-13T00:00:00Z", "meta": { "snapshot.json": {
                "version": 5, "length": 412, "hashes": { "sha256": "<hex>" } } } },
  "signatures": [ { "keyid": "<hex>", "sig": "<hex>" } ] }
```

- Signatures: Ed25519, over the canonical JSON of `signed` (object keys sorted by bytes, no whitespace, strings escape only `"`, `\`, and U+0000–U+001F, only integers allowed).
- Key object: `{"keytype":"ed25519","scheme":"ed25519","keyval":{"public":"<64 hex>"}}`; the keyid is the SHA-256 hex of the key object's canonical JSON.
- `root.signed`: `version`, `expires`, `keys`, `roles` (`root`, `targets`, `snapshot`, `timestamp`, each with `keyids` and `threshold ≥ 1`).
- `snapshot.signed.meta`: the `version` of `targets.json` and of every `<channel>.json`.
- `targets.signed.targets`: logical path → `{length, hashes.sha256, custom?}`; `delegations.roles[]`: `{name, keyids, threshold, paths, terminating: true}`, with `name` ∈ `stable|beta|nightly`.
- A channel role's `targets` may contain only `manifests/<product-id>.json`, whose `custom` is `{"release_sequence": n, "app_version": "x.y.z"}`.

## Client workflow

1. Load trusted root N from the config embedded in setup or from the local trust state; fetch `N+1.root.json` in turn, where every new root must satisfy both the old root's and its own root threshold and its version must be exactly +1; the final root must not be expired.
2. Fetch `timestamp.json` (≤ 16 KiB) and verify the signature, that it is not expired, and that the version ≥ the trusted version.
3. Fetch `<v>.snapshot.json`; its length and hash must match the timestamp; verify the signature, version, and that it is not expired; every meta version in it must be ≥ the trusted version.
4. Fetch `<v>.targets.json` and the required `<v>.<channel>.json`; their versions must equal those listed in the snapshot; verify signatures and expiry; channel role signatures use the keys and threshold from the targets delegation; the target path must match the delegation's `paths`.
5. Manifest: take the hash of `manifests/<product-id>.json` from the channel role, download `targets/<hash>`, and check the length and hash; `custom.release_sequence` must equal the manifest's `product.release_sequence`.
6. Artifacts: every `sha256:` in the manifest must appear as the hash of some target in the top-level targets, otherwise `error.UnauthorizedArtifact`; after download, check the length and hash.
7. A new release's `release_sequence` must be strictly greater than the installed value (update); repair uses the installed release; `app_version` may be downgraded.

After successful verification, the root, timestamp, snapshot, targets, and channel versions and the `release_sequence` are written to `<install-root>/trust/state.json`.

## Errors

`error.SignatureThreshold`, `error.Expired`, `error.RollbackAttack`, `error.HashMismatch`, `error.LengthMismatch`, `error.UnknownRole`, `error.PathNotDelegated`, `error.UnauthorizedArtifact`, `error.ReleaseSequenceRegression`, `error.MetadataTooLarge`.
