# Zig Native Installer Framework — Technical Architecture v0.2

## 1. Core positioning

The framework is defined as:

> **A small, native, library-first distribution substrate for trusted installation, portable execution and embedded update.**

The core is not `installer.exe` or `updater.exe`, but:

```text
                 Zig Distribution Core
                  ─────────────────────
                  library-first runtime
                         │
          ┌──────────────┼───────────────┐
          │              │               │
          ▼              ▼               ▼
      Installer      Portable Run     Embedded SDK
       Profile          Profile          Profile
          │              │               │
      setup.exe       executor       Electron App
      GUI / CLI       no install       in-process
          │              │               │
          ▼              ▼               ▼
   machine deploy     execute      check/download/stage
          │                              │
          ▼                              ▼
   App Bootstrap                    commit handoff
```

The three Profiles share:

```text
TUF trust
Release/channel resolution
Artifact model
Downloader
Verifier
Cache
Event model
Platform abstraction
```

but each has a different capability boundary.

---

# 2. Four architecture decisions settled in this round

### Decision A — The Compatibility Lab is external and the vendor is replaceable

The self-hosted GitLab remains:

```text
source of truth
build control plane
release control plane
```

Cross-platform compatibility testing uses:

```text
External Compatibility Provider
```

For example Buildkite or another hosted CI/desktop-test provider.

The interface only requires:

```text
GitLab
   │
   │ trigger(test manifest + artifact URL)
   ▼
External Lab
   │
   ├── Windows
   ├── macOS
   └── Linux
   │
   ▼
JUnit / logs / screenshots / diagnostics
   │
   ▼
GitLab commit / pipeline status
```

In principle, the external test platform:

```text
does NOT require source checkout
does NOT receive release signing keys
does NOT own release decisions
```

It only consumes signed candidate artifacts that have already been built.

Buildkite Hosted Agents currently provide hosted Linux/macOS; the Windows Hosted Agent is currently Windows Server 2022 AMD64 and still in private preview; Travis has officially dropped macOS support. Therefore "supports all three platforms" cannot simply be equated with any single CI SaaS.

Therefore a Provider must go through our own capability contract, for example:

```text
provider capability
├── windows-desktop
├── windows-admin
├── macos-arm64
├── linux-x11
├── linux-wayland
├── gui-session
├── elevation
├── reboot
└── screenshot
```

**The vendor is replaceable infrastructure and does not enter the framework protocol.**

---

# 3. Portable Artifact becomes a first-class object

The previous model was built mainly around:

```text
Installed Product
```

It now becomes:

```text
Artifact
│
├── PortableExecutable
│
├── PortableBundle
│
└── InstallableComponent
```

Where:

## PortableExecutable

Represents:

> A native executable that can be verified, cached and run directly without installation.

Lifecycle:

```text
Resolve
   ↓
Fetch
   ↓
TUF Verify
   ↓
Platform Signature Verify
   ↓
Materialize
   ↓
Execute
   ↓
Collect Result
   ↓
Cache / GC
```

There is no:

```text
machine integration
shortcut
registry
service installation
App Bootstrap
uninstall
```

This is a very good fit for:

```text
agent worker
tool executor
simulator
WASM host
helper runtime
CLI tool
sandbox runtime
```

---

# 4. Portable Artifact ≠ SFX

An important technical decision is made here:

> **A Portable Artifact uses the OS-native executable format by default, not a self-extracting executable.**

That is:

| Platform | Portable executable |
|---|---|
| Windows | PE32+ `.exe` |
| macOS | Mach-O executable |
| Linux | ELF PIE executable |

For GUI macOS applications, a

```text
.app bundle
```

can be used as one logical Portable Artifact, instead of forcing a single Mach-O.

Therefore:

```text
Portable
```

is defined as:

> **No installation state**

and not as:

> **Physically exactly one filesystem object**

---

# 5. Explicit opposition to generic SFX / executable packers

v1 does not make any of the following a standard capability:

```text
UPX-like executable packing
custom PE overlay packer
runtime-generated executable
generic self-extract-and-run
encrypted executable payload
```

The reason is not only implementation complexity.

They simultaneously degrade:

```text
AV heuristics
SmartScreen reputation
code-signing transparency
crash diagnostics
binary reproducibility
security review
```

Therefore the online installer:

```text
setup.exe
```

contains only:

```text
Distribution Core
Native GUI
static UI assets
platform code
```

The product payload is:

```text
download separately
```

---

# 6. AV-Friendly Binary Policy

This recommendation becomes framework security policy directly.

### Executables must have a stable identity

Not allowed:

```text
generate a random EXE on every launch
```

Instead:

```text
immutable artifact
        │
        ▼
stable content hash
        │
        ▼
stable publisher signature
        │
        ▼
content-addressed cache
```

For example:

```text
cache/
└── sha256/
    └── ab89.../
        └── executor.exe
```

The same artifact always keeps the same bytes.

---

# 7. Windows: standard PE + Authenticode

All executable objects on Windows:

```text
setup.exe
portable executor
commit helper
DLL
.node module
```

are in principle all Authenticode-signed.

Using:

```text
SHA-256 digest
+
RFC 3161 timestamp
```

Microsoft currently explicitly recommends SHA-256 Authenticode and RFC 3161 SHA-256 timestamps; the timestamp keeps the signature valid long-term even after the certificate expires.

Windows release pipeline:

```text
PE binary
   ↓
Authenticode sign
   ↓
RFC3161 timestamp
   ↓
verify signature
   ↓
immutable artifact
   ↓
compute final SHA256
   ↓
TUF metadata
```

Note:

> **The TUF hash must be computed after Authenticode signing is complete.**

Because signing changes the binary bytes.

---

# 8. SmartScreen cannot be equated with "signature passed"

Windows also has a reputation layer.

Microsoft Defender SmartScreen currently considers both:

```text
publisher reputation
+
file hash reputation
```

Even if a new binary has a valid OV/EV signature, a new hash can still trigger the "unrecognized app" prompt while its reputation is not yet established. Microsoft also states explicitly that EV certificates no longer bypass SmartScreen automatically.

Therefore the release gate cannot be written as:

```text
SmartScreen warning == build failure
```

It should instead distinguish:

```text
Signature trust
    MUST PASS

Defender malware detection
    MUST PASS

SmartScreen publisher identity
    MUST PASS

SmartScreen reputation
    MONITORED
```

and keep the

```text
same publisher identity
```

stable over the long term as much as possible.

---

# 9. Some high-risk runtime behaviors are forbidden on Windows

By default the framework forbids:

```text
PowerShell bootstrap
cmd.exe install logic
download → %TEMP% → random.exe → execute
reflective DLL loading
self-modifying executable
unsigned helper
generic LoadLibrary downloaded payload
generic child-process execution
```

Portable Run is the only Profile explicitly allowed to:

```text
execute artifact
```

And that artifact must be:

```text
TUF authorized
+
policy verified
+
unprivileged by default
```

Therefore:

> **The portable execution capability and the privileged installer execution capability are two completely separate trust domains.**

---

# 10. macOS: Mach-O / .app + Developer ID + Notarization

macOS does not pursue a physical single binary.

GUI installer:

```text
Mogick Installer.app
```

Final website distribution:

```text
MogickInstaller.dmg
```

A CLI Portable Artifact can be:

```text
signed Mach-O
```

All executables / libraries use:

```text
Developer ID
Hardened Runtime
secure timestamp
```

and go through Apple notarization.

Apple currently requires notarized software to enable code signing and use the correct Developer ID certificate, Hardened Runtime and a secure timestamp; Gatekeeper uses Developer ID and notarization to judge software distributed from websites.

Therefore:

```text
build
 ↓
codesign nested binaries
 ↓
codesign .app
 ↓
notarize
 ↓
staple
 ↓
final immutable artifact
 ↓
SHA256
 ↓
TUF
```

It cannot be done in the reverse order.

---

# 11. On macOS, OS trust and TUF likewise do not duplicate each other

The two solve different problems:

```text
Developer ID / Notarization

"Do Apple / Gatekeeper consider
this program to belong to an identified developer,
and has it passed Apple malware/notary checks?"
```

Whereas:

```text
TUF

"Has our release authority
authorized this specific artifact
to become a stable/beta/nightly release?"
```

Both layers are kept.

The Apple notarization service scans for malicious content, checks code signing, and issues a ticket that Gatekeeper can verify for software that passes.

---

# 12. Linux: ELF + TUF as the primary distribution trust

Linux PortableExecutable:

```text
ELF PIE
```

Recommended:

```text
x86_64
arm64
```

The headless portable executor should use, as far as possible, a

```text
static / musl-friendly build
```

to reduce distribution dependencies.

Because the GUI installer needs:

```text
Wayland/X11
text shaping
font rendering
```

a small number of framework-owned static dependencies are allowed.

But the goal remains:

```text
No GTK
No Qt
No Chromium
No WebKit
No Python
No Node
```

A standalone Linux ELF has no unified consumer OS publisher trust like Windows Authenticode or macOS Developer ID.

Therefore the framework's own distribution trust comes mainly from:

```text
HTTPS
+
TUF authorization
+
SHA-256
```

If in the future it outputs:

```text
.deb
.rpm
```

distro/package signatures are layered on top.

---

# 13. Distribution Core becomes library-first

It was previously easy to end up with:

```text
updater.exe
      =
updater implementation
```

This is now formally changed to:

```text
              libdistribution
                 Zig Core
                    │
       ┌────────────┼───────────────┐
       │            │               │
       ▼            ▼               ▼
    setup.exe     dist CLI     distribution.node
```

Core does not own the UI.

Core does not own Electron.

Core does not own command-line parsing.

Core modules:

```text
trust
repository
manifest
resolver
artifact
cache
download
verify
planner
transaction
platform
event
portable
bootstrap
```

---

# 14. Library ABI

Because Zig itself is still evolving quickly, the framework does not expose the Zig language ABI to consumers.

The public native boundary is fixed as:

```text
C ABI
```

For example:

```text
dist_context_create()
dist_context_destroy()

dist_check_update()
dist_resolve()
dist_fetch()
dist_stage()

dist_portable_resolve()
dist_portable_run()

dist_transaction_commit()

dist_event_subscribe()
dist_cancel()
```

The ABI must not expose:

```text
Zig struct
Zig allocator
Zig error union
Zig slice internals
```

Outside callers see only:

```text
opaque handles
fixed-width integers
byte buffers
versioned structs
callback table
```

---

# 15. The ABI itself is also versioned

For example:

```text
DIST_ABI_V1
```

Initialization:

```text
dist_get_api(
    requested_version,
    &api_table
)
```

So that:

```text
Electron app
Installer
CLI
third-party host
```

can upgrade gradually, without being required to release at the same time as the framework source.

---

# 16. Electron Embedded SDK

The Electron architecture is adjusted to:

```text
Electron Main Process
        │
        ▼
 distribution.node
        │
       C ABI
        │
        ▼
 Zig Distribution Core
```

Electron completes the following directly in-process:

```text
check
resolve
download
TUF verification
platform signature verification
stage
progress reporting
```

instead of:

```text
spawn updater.exe
```

---

# 17. The Electron native boundary prefers Node-API

The `.node` wrapper stays extremely thin:

```text
Node-API
   │
C ABI
   │
Zig Core
```

Node-API is designed precisely to provide a native addon ABI that is stable across Node.js versions; using only the Node-API C interface avoids binding directly to the V8 API.

Electron still officially warns that ordinary native modules often need to be rebuilt against the Electron ABI, so our goal should be:

```text
Node-API only
+
prebuilt per OS / architecture
+
Electron compatibility test
```

rather than exposing Electron/V8 internal APIs.

---

# 18. An "in-process updater" does not mean commit must also be in-process

This boundary is kept.

Electron can do:

```text
check
download
verify
stage
```

entirely in-process.

But updating:

```text
the Electron binary that is currently running
```

ultimately requires:

```text
current app exit
       ↓
atomic activation
       ↓
new app launch
```

Therefore one:

```text
Signed Commit Activator
```

is allowed. It is not:

```text
updater.exe
resident daemon
update service
```

but a:

> framework-owned, fixed-capability, very short-lived atomic handoff helper.

Windows:

```text
dist-activate.exe
```

macOS:

can preferably let the

```text
new app launcher
```

complete activation.

Linux can likewise implement it through a version pointer / atomic rename.

---

# 19. The Commit Activator also follows No Custom Scripts

The Activator API has only:

```text
wait_for_pid
verify_transaction
atomic_switch
launch_target
report_result
```

It cannot:

```text
exec arbitrary command
run script
download
resolve release
modify arbitrary files
```

It should be one of the easiest binaries to audit in the entire framework.

---

# 20. Payload Container Format

The recommendation here is to distinguish:

```text
Executable Format
```

and:

```text
Component Payload Format
```

Do not invent a "universal binary container".

Native executables use the native formats:

```text
PE
Mach-O
ELF
```

For multi-file components, v1 is recommended to use:

```text
tar.zst
```

as the framework-controlled payload format.

Reasons:

```text
streamable
open format
high compression ratio
simple deterministic layout
works across platforms
```

But the framework strictly restricts tar semantics.

v1 forbids:

```text
absolute path
..
symlink
hardlink
device
FIFO
special file
```

Only the following are allowed:

```text
regular file
directory
normalized relative path
```

File permissions, the executable bit, service semantics and so on are all described by the manifest.

That is:

> **archive does not define machine semantics.**

---

# 21. A single-file offline SFX is not a v1 goal

This is the most important trade-off in this binary policy.

Online:

```text
setup.exe
<30 MiB
```

is good.

Offline should not, for the sake of

```text
"looking like a single EXE"
```

go back to:

```text
huge SFX
+
embedded archive
+
runtime unpack-and-execute
```

Recommended:

```text
Windows
offline bundle directory / ZIP

macOS
DMG

Linux
tar.zst
```

If real user demand in the future strongly requires:

```text
Windows single-file offline setup
```

it will be done as a separate capability with an AV/SmartScreen benchmark.

Do not let it pollute the v1 architecture.

---

# 22. Signing Architecture

The result is four layers of trust:

```text
             Transport
               HTTPS
                 │
                 ▼
          Repository Trust
                TUF
                 │
                 ▼
          Artifact Integrity
             SHA-256
                 │
                 ▼
          Execution Trust
       OS Platform Signature
```

Where:

| Layer | Problem solved |
|---|---|
| HTTPS | transport confidentiality / basic server authentication |
| TUF | release authorization / freshness / rollback / repository compromise |
| SHA-256 | exact artifact identity |
| OS signing | publisher identity / execution trust / OS security ecosystem |

No layer can be used as a substitute for another.

---

# 23. Release Signing Pipeline

Recommended to be fixed as:

```text
Build once
   │
   ▼
Functional tests
   │
   ▼
Platform signing
   │
   ├── Windows Authenticode
   └── macOS Developer ID
   │
   ▼
macOS notarization
   │
   ▼
FINAL ARTIFACT BYTES
   │
   ▼
SHA-256
   │
   ▼
Staging TUF Repository
   │
   ▼
External Compatibility Lab
   │
   ▼
Release Approval
   │
   ▼
Production TUF metadata
   │
   ▼
Channel Promotion
```

The most important invariant:

> **External compatibility tests run against the exact OS-signed bytes that will eventually be released.**

After the tests pass:

```text
no recompilation
no relinking
no payload modification
```

Only new

```text
TUF release/channel metadata
```

is produced.

---

# 24. Signing keys never enter the external Compatibility Provider

Buildkite or any other SaaS:

```text
never receives:
Windows signing private key
Apple Developer ID private key
TUF production root/targets keys
```

It only gets:

```text
already-signed candidate
+
staging TUF repository
+
test credentials
```

This way, the worst case of an external CI compromise becomes:

```text
test result compromise
```

rather than:

```text
release signing compromise
```

---

# 25. AV / Security Release Gates

New release gates:

```text
All executables platform-signed          PASS
Signature timestamp                       PASS
TUF verification                          PASS
Built-in OS malware scan                  PASS
No unsigned executable payload            PASS
No generic script capability              PASS
No generic privileged exec                PASS
No executable packer / runtime unpacker   PASS
Artifact hash reproducibility              PASS
Privilege helper capability audit         PASS
```

Windows additionally monitors:

```text
SmartScreen reputation
Defender false positive
publisher identity
```

macOS:

```text
codesign --verify
Gatekeeper assessment
notarization
stapling
Hardened Runtime
```

---

# 26. Selection criteria for the Compatibility Provider

It is reasonable that the vendor is still undecided, but we should not compare only:

```text
price
```

We should instead compare whether a vendor can cover real desktop compatibility.

Minimum requirements:

| Capability | Requirement |
|---|---|
| Windows | Windows 11 desktop environment |
| Windows privilege | UAC/admin available |
| macOS | current + N-1, Apple Silicon |
| Linux | at least one Ubuntu LTS |
| Display | real GUI session |
| Linux graphics | X11 + Wayland strategy |
| Filesystem | native filesystem |
| Reboot | preferably supported |
| Artifact-only job | required |
| API trigger | required |
| JUnit/log export | required |
| ephemeral environment | preferred |

For example, the current Buildkite Windows Hosted Agent is Windows Server 2022 rather than a Windows 11 consumer desktop, so it can handle a large share of core/platform tests well, but it cannot on its own prove Windows 11 SmartScreen / desktop installer UX.

So in the future we may end up with:

```text
Provider A
  → 90% automated compatibility

small Desktop Certification Pool
  → Windows 11 / unusual GUI / reboot scenarios
```

rather than insisting that one SaaS solves 100% of cases.

---

# 27. Updated Testing Topology

Final recommendation:

```text
                       Self-hosted GitLab
                              │
              ┌───────────────┼────────────────┐
              ▼               ▼                ▼
         Core tests      VirtualPlatform   Security/Fuzz
              │
              └───────────────┬────────────────┘
                              ▼
                       Signed Candidate
                              │
                              ▼
                   External Compatibility
                           Provider
                              │
                ┌─────────────┼─────────────┐
                ▼             ▼             ▼
             Windows        macOS         Linux
                │             │             │
                └─────────────┼─────────────┘
                              ▼
                       Certification Result
                              │
                              ▼
                         Release Gate
```

The external Compatibility Lab is the:

> **validation plane**

not the:

> **build plane**

and even less the:

> **release signing plane**.

---

# 28. Updated Core Object Model

The framework is ultimately built around the following objects:

```text
Repository
    │
    ▼
Release
    │
    ▼
Artifact
    │
    ├── PortableExecutable
    ├── PortableBundle
    └── InstallableComponent
    │
    ▼
DeploymentProfile
    │
    ├── PortableRun
    ├── InstalledApplication
    └── EmbeddedUpdate
```

Where:

```text
PortableRun
```

has as its only primary capability:

```text
trusted artifact → execute
```

```text
InstalledApplication
```

allows:

```text
desired state
→ typed InstallationPlan
→ machine mutation
```

```text
EmbeddedUpdate
```

allows:

```text
resolve
download
verify
stage
handoff
```

The security capabilities of the three are not inherited from one another.

---

# 29. Updated Architecture

```text
                         RELEASE PLANE

                    Build / Product Composer
                              │
                              ▼
                       Native Artifacts
                PE / Mach-O / ELF / bundles
                              │
                              ▼
                       Platform Signing
                              │
                              ▼
                       Final Artifact
                              │
                       SHA-256 identity
                              │
                              ▼
                     TUF Repository
                              │
              stable / beta / nightly
                              │
──────────────────────────────┼──────────────────────────────
                              │
                              ▼
                    Zig Distribution Core
                       library-first
                              │
          ┌───────────────────┼────────────────────┐
          │                   │                    │
          ▼                   ▼                    ▼
      Installer          Portable Run          Embedded SDK
       Profile              Profile              Profile
          │                   │                    │
      Native GUI         PortableArtifact     Electron / host
       + CLI                  │                    │
          │                   ▼                    ▼
          │                execute          resolve/download/
          │              without install      verify/stage
          │                                        │
          ▼                                        ▼
    InstallationPlan                         Commit Handoff
          │
          ▼
   Privilege Broker
          │
          ▼
   Machine Deployment
          │
          ▼
    Atomic Commit
          │
          ▼
     App Bootstrap
```

---

# 30. Technical decisions currently recommended for freezing

| Area | v1 Decision |
|---|---|
| Core language | **Zig** |
| Core architecture | **Library-first** |
| Native ABI | **C ABI** |
| Update trust | **TUF** |
| Hash | **SHA-256** |
| Windows executable | **PE32+** |
| macOS executable | **Mach-O / `.app`** |
| Linux executable | **ELF PIE** |
| Component archive | **tar.zst candidate for v1** |
| Runtime scripting | **None** |
| Generic privileged exec | **None** |
| Portable execution | **First-class Profile** |
| Windows signing | **Authenticode SHA-256 + RFC3161** |
| macOS signing | **Developer ID + Hardened Runtime + Notarization** |
| Linux distribution trust | **TUF-first** |
| Executable packer | **Forbidden by default** |
| Online installer | **≤30 MiB** |
| Offline SFX | **Not v1** |
| Electron updater | **in-process Zig library via Node-API** |
| Update commit | **short-lived signed activation handoff** |
| Compatibility infrastructure | **external provider abstraction** |
| CI source of truth | **Self-hosted GitLab** |

---

## Architecture mantra

The whole project can ultimately be condensed into five sentences:

> **1. Distribution Core is a library, not an updater executable.**
>
> **2. Artifacts are immutable native objects; Portable Artifact is a first-class deployment model.**
>
> **3. Installation metadata describes state, never executable scripts.**
>
> **4. TUF authorizes releases; platform signatures establish OS-level publisher trust.**
>
> **5. Build once, sign once, test the final bytes, then promote by metadata only.**

These five sentences are recommended as the top-level constraints for subsequent framework ADRs.
