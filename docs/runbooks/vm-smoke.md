# VM smoke

`zig build vm-smoke` uses Parallels (`prlctl`) to run the branded offline bundle of `examples/hello` ([offline-bundle](offline-bundle.md)) on a real OS, as the user logged in to the guest. Implementation: `build/steps/vm.zig` (builds the bundle) and `tools/vm-smoke` (drives the guest).

| VM | Target | Coverage |
|---|---|---|
| `Windows 11` | `x86_64-windows` (emulated on an ARM64 host) | user scope `install` → `update` → `repair` → `uninstall`; console screenshot |
| `Ubuntu 24.04.3 ARM64` | `aarch64-linux` | Same as above |

## Steps

1. `zig build vm-smoke` first builds `examples/hello` for each target by running `zig build -Dtarget=<target>` in a child process ([consuming](../development/consuming.md)), leaving the offline bundle in the build cache: nbpack runs on the host, and setup and the sample application are cross-compiled for the target (ReleaseSafe, ELF strip).
2. When a VM is not running, the result is `BLOCKED` and the VM is not started. To allow starting or resuming, use `zig build vm-smoke -- --start`; the tool then probes Parallels Tools with `prlctl exec` every 5 seconds, for at most 300 seconds. To run only one: `-- --vm 'Ubuntu 24.04.3 ARM64'`.
3. Copying does not rely on shared folders: the tool temporarily serves HTTP on the host address of the Parallels shared network (the adapter IPv4 from `prlsrvctl net info Shared`, for example `10.211.55.2`), and the guest downloads the bundle files one by one (with `python3` on Linux, PowerShell `Invoke-WebRequest` on Windows) to `/tmp/niobium-vm-smoke/<UTC>/` or `C:\Users\Public\niobium-vm-smoke\<UTC>\`.
4. `prlctl exec <vm> --current-user <setup> <verb> --silent --json` runs the four operations in order; any non-zero exit code is `FAIL`. The offline bundle's setup uses the `repository/` in the same directory and the embedded trust root, so `--repo` is not needed.
5. `prlctl capture <vm> --file <png>` captures the console; a screenshot failure is only recorded in the transcript and does not affect the result.
6. Evidence is written to `.evidence/vm-smoke/<UTC>/`: `summary.txt` has one line per VM, `PASS`, `FAIL (reason)` or `BLOCKED (reason)`; `<vm>/transcript.txt` records every prlctl command, its output and exit code; `<vm>/screen.png`.

When there is a `FAIL`, the tool exits with code 1; `BLOCKED` does not fail the step, but must not be recorded as PASS.

## Known limitations

- The guest-side commands of steps 3 and 4 have never been run on a real VM: this repository has so far only recorded both VMs as `BLOCKED` (Ubuntu was shut down, Windows was suspended). The four operations of the `aarch64-linux` bundle have passed in a Debian bookworm arm64 container with a temporary HOME, but that is not an Ubuntu guest.
- The setup GUI is not opened automatically: the `prlctl exec` process is not in the user's graphical session. A GUI screenshot requires someone to run setup manually in the guest (N1-UJ-10 is likewise a manual item).
