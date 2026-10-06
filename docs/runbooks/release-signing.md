# Release signing

The order cannot be reversed: OS platform signing changes the binary bytes, so artifact and TUF hashes must be computed after platform signing. `zig build example` runs steps 1, 4, 5 and 8 with `examples/hello` (`examples/hello/build.zig` calls `addBundle` in `build/sdk.zig`).

1. Build once: `zig build cross -Doptimize=ReleaseSafe`.
2. Functional tests: `zig build verify`.
3. Platform signing (a hook; v0.1 has no certificates wired in, and this step has never been run):
   - Windows: `signtool sign /fd sha256 /tr <rfc3161> /td sha256 setup.exe`, then `signtool verify /pa`.
   - macOS: sign nested binaries → sign the `.app` (Developer ID, Hardened Runtime, secure timestamp) → `notarytool submit --wait` → `stapler staple`.
4. Pack the signed files. Once per component per platform:

   ```sh
   nbpack component build --source components/runtime/component.json --files <payload-dir> \
     --version 1.2.0 --platform macos-aarch64 --out runtime-macos-aarch64.tar.zst
   ```

   The output is first run through the same strict unpacker used at runtime (`libs/package`) and the component parser before it is written; `nbpack component validate <artifact>` rechecks an existing artifact on its own.
5. Sign into the staging repository. Add `--init` for the first release; `keys/` comes from `nbpack keygen --out keys/` (one `<role>.key.json` per role; mode 0600 on POSIX, relying on the directory ACL on Windows):

   ```sh
   nbpack publish --repo staging/ --keys keys/ --product product.json \
     --artifact runtime-macos-aarch64.tar.zst --artifact docs-macos-aarch64.tar.zst \
     --channel beta --version 1.2.0 --sequence 3
   ```

   Internally `publish` runs `product compose` (fills artifact digests into the manifest template; `artifacts` in the template must be empty), writes content-addressed `targets/<sha256>`, then signs channel and targets, then snapshot, and finally timestamp; `timestamp.json` is written last via a temp-file rename, so clients never see metadata pointing at missing files. It refuses when `release_sequence` is not greater than the channel's current value (`PackSequenceNotIncreasing`). When you only need the manifest without signing, use `nbpack product compose ... --out manifest.json`.
6. Compatibility tests (vm-smoke) run against exactly the same bytes in staging.
7. Release: `nbpack promote --repo <dir> --keys keys/ --product-id com.example.hello --sequence 3 --channel stable`. It only writes an existing release into the target channel and re-signs; it does not recompile or repack.
8. Generate setup's product config and build the branded setup:

   ```sh
   nbpack config --repo <dir> --product product.json --branding branding.json \
     --repository https://dl.example.com/hello --channel stable --out product-config.json
   zig build -Dproduct-config=product-config.json
   ```

   The config embeds the repository's latest `<N>.root.json` as the trust root; when `--repository` is omitted, setup can only be used offline (see [offline-bundle](offline-bundle.md)).

## Expiration

Metadata expires after 30 days by default, timestamp after 1 day, root after 365 days. The clock options `--now <unix seconds> --days <n> --timestamp-days <n>` apply to `publish`, `promote` and `sign`. Run `nbpack sign --repo <dir> --keys keys/` periodically to refresh expiration times; content stays the same and versions increase.

Signing private keys must never enter external CI or compatibility-testing platforms.
