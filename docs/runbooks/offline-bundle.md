# Offline bundle

An offline bundle is not an SFX: it is a directory (or zip) containing `setup` and a complete `repository/`. `zig build example` produces the offline bundle of `examples/hello` in `zig-out/example/`.

```text
Hello-1.2.0-offline/
  setup            (setup.exe on Windows)
  repository/      the same TUF layout as the online repository (metadata/, targets/)
  licenses/        license of the font embedded in setup (Inter-OFL.txt)
```

1. Build the bundle from a repository already signed for the target channel; `--out` must be an empty directory:

   ```sh
   nbpack bundle --repo <repo-dir> --setup zig-out/bin/setup --out Hello-1.2.0-offline/
   ```

   `bundle` copies setup and the whole repository, skipping partially written `*.tmp` files; the channel is determined by the product config embedded in setup.
2. Copy Inter's `LICENSE.txt` (fetched by `zig build` according to `third_party/deps.zon`; `zig build example` does this step automatically) to `licenses/Inter-OFL.txt`.
3. The user runs `setup`. Without `--repo`, it uses the `repository/` in its own directory (detected by the presence of `repository/metadata/timestamp.json`), and only then the `repository` in the product config. The trust root is still the root embedded in setup, and the verification chain is exactly the same as online (`bundled` in `apps/setup/frontend.zig`).
4. Verify: with the network disconnected, `setup install --scope user` exits with code 0, and `setup status --json` reports the installed version.
