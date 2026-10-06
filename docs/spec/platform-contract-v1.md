# Platform contract v1

- **Status:** Baseline

Every platform backend (`libs/platform/{virtual,macos,windows,linux}`) implements `platform.api.Capabilities` and must pass the PlatformContract suite in `libs/conformance` before its target can be promoted above Tier 3 ([ADR-0014](../adr/0014-tier-based-platform-support.md)). "It compiles" does not mean it is supported.

## Capabilities

| Capability | Required operations | Notes |
|---|---|---|
| FileSystem | create dir, atomic write, rename, remove tree, symlink/junction swap, free space | All paths are relative to the install root directory handle |
| Shortcut | create/remove | macOS `~/Applications` link; Windows `.lnk` (Start Menu); Linux `.desktop` |
| FileAssociation | register/remove | macOS does not support dynamic registration (`CapabilityUnsupported`; declared by the app bundle); Windows `Classes` registry; Linux `mimeapps.list` + `.desktop` MimeType |
| Service | register/remove | launchd plist; SCM; systemd unit |
| ApplicationRegistration | write/remove | Windows Uninstall registry key; on Linux/macOS writing `installation.json` is sufficient |
| Privilege | is_elevated, spawn_helper | See [ipc-v1](ipc-v1.md) |
| Process | spawn_bootstrap, spawn_portable | For use only by the bootstrap and portable modules |
| Clock | now | Injectable |
| Paths | install_root(scope, product_id), cache_root, log_root | Determined by the framework; components cannot specify them |

## Implementation conventions

The interface is `Platform` (a vtable) in `libs/platform/api.zig`. There are three implementations: `Virtual` (tests and sim), `Host` (`libs/platform/host.zig`, which selects `macos.zig` / `windows.zig` / `linux.zig` at compile time), and the privilege broker (which forwards to the helper).

- **Integration lifecycle:** prepare (execute phase, writes a `<final>.nb-tx-<n>` temporary file) → activate (after commit, renames over `<final>`, reentrant) → remove (deletes only entries carrying the ownership marker). discard deletes the temporary file.
- **Ownership marker:** text files contain `niobium-managed`; a `.lnk` is marked by a target path that goes through `\current\`; registry keys carry a `NiobiumManaged` value; macOS links must be symlinks. Files not written by the framework are never overwritten or deleted; when one is encountered, `PlatformIntegrationFailed` is returned.
- **Name validation (`names.zig`):** an id is a single path segment and must not contain separators, control characters, a leading dot, `..`, or platform-reserved characters; unit / plist label / ProgID allow only `[A-Za-z0-9._-]`; extensions allow only lowercase letters and digits; a target is a relative path without `..`.
- **`Host.Options`:** `env` (HOME, APPDATA, XDG_* and so on, read once by `apps/*`); `machine_root` (prefix for machine scope system directories, empty in production); `system_managers` (whether to call launchctl, systemctl, desktop caches, the registry, and SCM). Contract tests redirect every location to a temporary directory and turn off `system_managers`; in that mode, integrations that exist only in a system manager return `CapabilityUnsupported`.
- **free space:** returns the number of bytes available to the caller on the volume containing `path`. If the path does not exist, the nearest existing ancestor is used.

### macOS

| Integration | user | machine |
|---|---|---|
| shortcut | `~/Applications/<id>` → `<root>/current/<target>` (symlink) | `/Applications/<id>` |
| service | `~/Library/LaunchAgents/<product>.<id>.plist` + `launchctl bootstrap gui/<uid>` | `/Library/LaunchDaemons/…` + `system` domain |
| file association / registration | `CapabilityUnsupported` | Same as user |

### Windows

| Integration | user | machine |
|---|---|---|
| shortcut | `%APPDATA%\Microsoft\Windows\Start Menu\Programs\<id>.lnk` (hand-written MS-SHLLINK, no COM dependency) | `%ProgramData%\…` |
| file association | `HKCU\Software\Classes\<product>.<ext>` + `.<ext>\OpenWithProgids`; the default value of `.<ext>` is written only when it is empty or already belongs to this product | `HKLM\…` |
| service | `CapabilityUnsupported` | SCM `<product>.<id>` |
| registration | `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\<product>` | `HKLM\…` |

`current` is a directory junction (no symlink privilege needed). The switch takes two renames: first `current.next` is created, then `current` is renamed to `current.old`, then `current.next` is renamed to `current`, and finally `current.old` is deleted. A crash between the two renames leaves no `current`: for a crash before commit, rollback redoes the swap; for one after commit, roll-forward redoes it. `setPointer` handles both a missing link and leftover `.next` and `.old`.

### Linux

`<data>` is `$XDG_DATA_HOME` (default `~/.local/share`) in user scope and `/usr/local/share` in machine scope.

| Integration | user | machine |
|---|---|---|
| shortcut | `<data>/applications/<product>.<slug>.desktop` | Same as user |
| file association | `<data>/mime/packages/<product>-<ext>.xml` + a hidden `<data>/applications/<product>.assoc-<ext>.desktop` (`MimeType=`) | Same as user |
| service | `$XDG_CONFIG_HOME/systemd/user/<product>-<id>.service` + `systemctl --user` | `/etc/systemd/system/…` |
| registration | `CapabilityUnsupported` | Same as user |

`Exec=` and `ExecStart=` wrap the path in double quotes. A path containing `"`, `` ` ``, `$`, `\`, or `%` is rejected outright, with no escaping. The framework does not rewrite `mimeapps.list`: the default program is the user's choice, and only the handler is registered here.

## Contract tests

`create managed file`, `atomic replace`, `pointer swap interrupted recovery`, `shortcut create/remove`, `association register/remove` (or explicitly unsupported), `service register/remove` (machine scope, may be `NOT_RUN` in CI), `free space query`, `path policy` (scope × platform).

Implementation: `run(io, arena, Subject)` in `libs/conformance` runs the cases above against any `Platform` and returns `pass` / `unsupported` / `not_run` for each case. Capabilities declared in `Subject.required` are not allowed to be unsupported. `path policy` is covered by the scope × platform tests in `libs/planner/paths.zig`; the suite additionally verifies that escaping integration ids are rejected.

| Run | Location |
|---|---|
| Virtual (all capabilities required) | `libs/conformance` unit tests |
| Host backend (N1-AC-14), user and machine scope, locations redirected to a temporary directory | `tests/conformance`, `zig build test` |
| The same binary on Windows 11 / Ubuntu | `zig build test-cross` output `zig-out/cross-tests/<target>/suite-conformance`, executed by vm-smoke |

## Platform crash pitfalls

- Win32: wndproc does not propagate errors; pair COM initialization/release; `\\?\` long paths; bounded retries for sharing violations and AV locks.
- AppKit: call only on the main thread; one autorelease pool per event loop iteration; validate input before calling APIs that may throw ObjC exceptions.
- X11: connection loss and protocol error replies are errors, not panics.
