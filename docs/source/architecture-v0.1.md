# Zig Native Installer Framework

## 1. Design Positioning

This framework is not a general-purpose scripting-based installer builder. It is a:

> **Native, declarative, transactional, cross-platform application deployment runtime.**

The core goal is to implement a very small native installer substrate in Zig that uniformly addresses:

- GUI installation;
- unattended CLI;
- online / offline distribution;
- component composition;
- install / update / repair / uninstall;
- release channel;
- cryptographic update trust;
- privilege separation;
- crash recovery / rollback;
- Windows / macOS / Linux compatibility.

The current stable Zig release is 0.16.0. Zig treats cross-compilation as a first-class capability and can produce binaries for different targets such as Windows, macOS, and Linux from a single build environment; the standard library also already includes infrastructure such as HTTP, JSON, crypto, ZIP, and tar, which makes it well suited as the single implementation language for an installer.

But it must be stated clearly:

> **Cross-build solves build portability; it does not prove runtime compatibility.**

Every platform must still ultimately pass compatibility testing in a real OS environment.

---

# 2. Six Inviolable Architecture Principles

1. **Manifest is data, never code.**  
   The manifest contains no shell, PowerShell, Python, JavaScript, `exec()`, or any generic command.

2. **Desired state, not execution steps.**  
   The product describes "what I want"; the installer decides "how to get there".

3. **Installer owns machine deployment; application owns application semantics.**  
   File deployment, services, shortcuts, and file associations belong to the installer; database migration, cache initialization, and business configuration migration belong to App Bootstrap.

4. **Privilege is capability-based.**  
   The elevated worker accepts only closed typed operations, never arbitrary executables.

5. **Installation is transactional.**  
   After a crash at any moment, recovery may only reach old-good or new-good; a half-installed active state is not allowed.

6. **The framework is intentionally non-extensible at runtime.**  
   There are no installer plugins, no script hooks, and no custom native DLL hooks. Capabilities can only be extended through framework version evolution.

---

# 3. Overall Architecture

```text
                    BUILD / RELEASE PLANE

 Component A ─┐
 Component B ─┼─────► Product Composer
 Component C ─┘              │
                             │
                    Declarative Product Manifest
                             │
                             ▼
                       Package Builder
                             │
                 ┌───────────┴───────────┐
                 │                       │
           Online artifacts         Offline bundle
                 │
                 ▼
              TUF Signer
                 │
                 ▼
          Repository / CDN
        stable / beta / nightly


────────────────────────────────────────────────────────────


                       CLIENT PLANE

                    setup / maintainer
                           │
              ┌────────────┴────────────┐
              │                         │
          Native GUI                   CLI
              │                   --silent / --json
              └────────────┬────────────┘
                           ▼
                    Installer Engine
                           │
                 ┌─────────┼──────────┐
                 │         │          │
              Resolver   Planner   Transaction
                 │         │          Journal
                 │         │
                 ▼         ▼
              TUF        Typed
            verifier  InstallationPlan
                           │
                 ┌─────────┴──────────┐
                 ▼                    ▼
        Unprivileged executor    Privilege Broker
                                      │
                                      ▼
                              Elevated Worker
                                      │
                              closed capability set
                                      │
                 ┌────────────────────┼──────────────────┐
                 ▼                    ▼                  ▼
             Filesystem            Services          OS Integration
                                                        │
                                                        ▼
                                                   Commit
                                                        │
                                                        ▼
                                              App Bootstrap
                                               user context
```

---

# 4. Modules of the Framework Itself

The recommended code boundaries map directly onto security boundaries.

| Module | Responsibility |
|---|---|
| `core` | install state machine and error model |
| `manifest` | schema parsing, validation, capability model |
| `resolver` | component / platform / channel resolution |
| `trust` | TUF verification, hash, signature, freshness |
| `package` | archive, artifact, offline repository |
| `planner` | Desired State → InstallationPlan |
| `transaction` | journal, staging, commit, recovery |
| `executor` | unprivileged operations |
| `privilege` | elevated helper protocol |
| `platform` | Windows/macOS/Linux OS adapter |
| `ui` | layout, scene, design system, semantic tree |
| `cli` | headless frontend |
| `bootstrap` | App Bootstrap protocol |
| `telemetry` | structured event interface; no telemetry SDK embedded by default |
| `packager` | build-time product assembly |
| `conformance` | component/product/bootstrap compatibility test kit |

This means:

```text
GUI
```

and

```text
CLI
```

are in fact just two frontends of:

```text
InstallerEngine
```

There must never be two sets of installation logic.

---

# 5. Declarative Product Model

I recommend keeping the protocol deliberately very small.

For example:

```yaml
schema: 1

product:
  id: com.example.mogick
  name: Mogick
  version: 1.8.3
  release_sequence: 187

install:
  scope: user

components:
  - id: runtime
    artifact: sha256:...
    required: true

  - id: plugins
    artifact: sha256:...
    required: true

integrations:
  shortcuts:
    - entrypoint: runtime.main

  file_associations:
    - extension: ".mogick"
      entrypoint: runtime.main

bootstrap:
  component: runtime
  protocol: 1

experience:
  theme: default
  accent: "#..."
  icon: product.png
```

Note in particular that the following fields do not exist:

```yaml
pre_install:
post_install:
script:
exec:
shell:
command:
```

The schema parser should reject unknown privileged behavior outright rather than "ignore" it.

---

# 6. The Definition of a Component Should Also Be Extremely Restricted

Component developers provide:

```text
Component Artifact

├── component metadata
├── application files
└── named entrypoints
```

and do not provide:

```text
install.sh
setup.ps1
post-install.py
```

The artifact itself expresses only:

```text
component id
component version
platform / arch
files
named entrypoints
bootstrap support
```

A component should not even decide:

```text
C:\Program Files\...
/Applications/...
/usr/local/...
```

The actual location is decided uniformly by the framework based on:

```text
product id
scope
platform
```

This is another important opinion:

> **Components do not own absolute machine paths.**

---

# 7. OS Integration Is a Closed Capability Set

For example, v1 might support only:

```text
ManagedFiles
Directory
Shortcut
FileAssociation
ProtocolHandler
Service
AutoStart
EnvironmentEntry
ApplicationRegistration
```

When a new capability is needed later:

```text
FirewallRule
Driver
KernelExtension
```

it must not be worked around with:

```text
exec custom script
```

Instead it must become:

```text
Framework Capability v2
```

after formal design, implementation, and testing.

Therefore remote metadata can only ever invoke semantics that the framework explicitly knows.

---

# 8. App Bootstrap Protocol

The application's own migration must still be allowed to contain code, but **the code belongs to the application, not to the installer protocol**.

For example:

```text
Installer
    │
    │ AppBootstrapRequest v1
    ▼
Application
    │
    ├── migrate internal DB
    ├── initialise cache
    ├── migrate configuration
    └── validate app state
```

The manifest may only say:

```yaml
bootstrap:
  component: runtime
  protocol: 1
```

and may not say:

```yaml
command:
  runtime.exe migrate --foo --bar
```

The framework owns a fixed invocation contract, for example:

```text
runtime --installer-bootstrap-v1
```

and then passes a versioned JSON protocol over stdin/stdout:

```json
{
  "operation": "activate",
  "from_version": "1.8.2",
  "to_version": "1.8.3",
  "transaction_id": "..."
}
```

Bootstrap must be:

```text
idempotent
restartable
version-aware
unprivileged by default
```

If the application needs a machine-level service, it must go back and declare it in the product manifest, rather than have the bootstrap sudo by itself.

---

# 9. Installer State Machine

I recommend formally defining the following state machine:

```text
Discover
    ↓
Validate
    ↓
Resolve
    ↓
Plan
    ↓
Prepare
    ↓
Execute
    ↓
Commit
    ↓
Bootstrap
    ↓
Verify
    ↓
Finalize
```

Here `Validate` performs schema/platform/trust validation; `Resolve` decides the channel, version, components, and artifacts; `Plan` compiles the declarative state into a typed `InstallationPlan`; `Prepare` downloads, verifies, and unpacks into staging; `Execute` performs machine mutations that do not yet take effect on the active installation; `Commit` completes atomic activation; after that, App Bootstrap performs business migration.

One core invariant is:

> **Before Commit, the old version remains runnable.  
> After Commit, the new version is the sole active version.**

It must not perform in-place mutation directly, such as:

```text
open current/bin/a.dll
overwrite
overwrite
overwrite
...
```

---

# 10. Crash Consistency

Every operation with side effects must go into the transaction journal:

```text
tx-187.jsonl

BEGIN
STAGE artifact-1
CREATE ...
REGISTER ...
READY_TO_COMMIT
COMMIT
BOOTSTRAP_STARTED
BOOTSTRAP_DONE
FINALIZED
```

Every journal transition must have clear:

```text
replay
rollback
or ignore
```

semantics.

The first thing the framework does at startup is:

```text
RecoverIncompleteTransaction()
```

rather than immediately starting the next install.

This makes it possible to handle the following systematically:

```text
process killed
machine shutdown
power loss
disk full
user cancel
network failure
UAC cancel
```

---

# 11. Privilege Architecture

The whole GUI installer runs by default as:

```text
standard user
```

Only when the installation plan truly needs an elevated capability does it launch:

```text
priv-helper
```

Structure:

```text
Installer Core
     │
     │ transaction-id
     │ nonce
     │ typed plan subset
     ▼
Privilege Broker
     │
     ▼
OS elevation
     │
     ▼
priv-helper
```

An example `priv-helper` API:

```text
WriteManagedFile
RemoveManagedFile
CreateDirectory
RegisterService
RemoveService
CreateMachineShortcut
RegisterProtocol
```

The following do not exist:

```text
Exec
Shell
SpawnArbitraryProcess
LoadPlugin
RunDLL
```

The helper exits after the transaction completes:

> **No permanently running privileged installer daemon.**

This significantly reduces the long-term attack surface.

---

# 12. Update Trust: Adopt an Explicit TUF Profile

Redesigning our own:

```text
manifest.sig
```

protocol is not recommended.

TUF itself was designed for update-system problems such as repository compromise, key compromise, rollback, and freeze, and it separates four top-level roles: Root, Targets, Snapshot, and Timestamp. Targets is responsible for artifact hash/size, Snapshot provides a consistent repository view, and Timestamp provides freshness.

But we also have no need to support TUF's unbounded complexity.

We can define:

## Installer TUF Profile v1

```text
metadata: JSON
hash: SHA-256
target signature: Ed25519

required:
Root
Targets
Snapshot
Timestamp

delegation:
one controlled channel layer
```

For example:

```text
Targets
   │
   ├── stable
   ├── beta
   └── nightly
```

Artifact:

```text
immutable
```

Channel:

```text
mutable signed pointer
```

Therefore:

```text
release #187
application 1.8.3
      │
      ├── nightly
      ├── beta
      └── stable
```

Promotion does not rebuild.

---

# 13. Keep `release_sequence` Separate from the Semantic Version

This detail matters.

Suppose:

```text
release_sequence = 188
app version = 1.8.4
```

After release an incident occurs and a rollback is needed:

```text
release_sequence = 189
app version = 1.8.3
```

This is:

> **new release decision pointing to an older application binary**

rather than a metadata rollback attack.

Therefore:

```text
release_sequence
```

must increase monotonically, while:

```text
application_version
```

may be intentionally downgraded.

This keeps incident rollback from conflicting with TUF anti-rollback semantics.

---

# 14. Online and Offline Should Not Have Two Protocols

Unify on a single:

```text
RepositorySource
```

interface:

```text
HTTPRepositorySource
EmbeddedRepositorySource
DirectoryRepositorySource
```

What the resolver sees is always:

```text
TUF metadata
+
artifacts
```

Therefore:

```text
Online installer
```

and:

```text
Full offline installer
```

share exactly the same resolver, planner, and executor.

The only difference is the artifact source.

---

# 15. Package Format

Do not design a complex proprietary container in the first version.

Recommended:

```text
artifact.zip
```

plus TUF target metadata.

The Zig 0.16 standard library already provides namespaces such as `zip`, `tar`, `compress`, `crypto`, `http`, and `json`, so this layer can be built without bringing in a heavyweight runtime framework.

Later, if data volume clearly requires it, we can add:

```text
tar.zst
```

But the codec should belong to a framework-owned format version:

```text
artifact-format-v2
```

rather than letting products freely choose among dozens of archive formats.

---

# 16. GUI: Do Not Build a General-Purpose UI Framework

This is the key to the success of the whole Zig native approach.

Our goal is not to reimplement Flutter.

Implement only the vocabulary an installer needs:

```text
Window
Stack
Row
Column
Card

Text
Image

Button
Checkbox
Radio
Link

ProgressBar
ProgressRing

Scroll

Modal
Divider
```

Ideally the first version should not even support arbitrary text input.

For the install path:

```text
Choose Folder
```

directly invokes the OS native picker.

This immediately removes a great deal of complexity:

```text
IME
selection
clipboard
text editing
composition
```

---

# 17. UI Engine Architecture

```text
Installer State
      │
      ▼
   ViewModel
      │
      ▼
    UI Tree
      │
 ┌────┴─────────┐
 ▼              ▼
Layout       Semantic Tree
 │              │
 ▼              ▼
Display List  Accessibility
 │
 ▼
Platform Renderer
```

This design is very well suited to testing.

The same:

```text
ViewModel
```

should always produce a deterministic:

```text
UiTree
DisplayList
SemanticTree
```

The UI does not call Win32/AppKit directly.

---

# 18. Platform Rendering Backend

## Windows

```text
Win32
  │
HWND / event
  │
Direct2D
  │
DirectWrite
```

Direct2D is the hardware-accelerated 2D API built into Windows, aimed specifically at high-quality native UI rendering; DirectWrite handles high-quality text, international text, and typography.

Therefore there is no need for:

```text
CEF
WebView
Qt
Flutter Engine
```

---

## macOS

```text
AppKit
  │
window / input / accessibility
  │
Core Graphics
  │
Core Text
```

AppKit comes with built-in window, event, and accessibility support; Core Graphics is Apple's lightweight 2D rendering framework; Core Text provides low-level high-quality text layout, font substitution, ligatures, and kerning.

---

## Linux

Linux needs to be treated separately:

```text
             Platform Backend
                 /        \
             Wayland      X11
```

Wayland itself is a compositor/client protocol with a C client library; the protocol uses a permissive MIT-like license.

To avoid depending on GTK/Qt, I recommend:

```text
window/input:
Wayland + X11 fallback

layout/render:
our tiny renderer

text:
FreeType + HarfBuzz
```

HarfBuzz uses the Old MIT license; FreeType can be used under the BSD-style FreeType License, which explicitly permits proprietary projects.

This way Linux can avoid:

```text
GTK
WebKitGTK
Qt
Chromium
```

as mandatory runtime dependencies.

---

# 19. Accessibility Must Enter the Architecture from the First Version

The biggest hidden cost of a native custom renderer is not rounded rectangles, but:

```text
Accessibility
DPI
font fallback
keyboard navigation
RTL
localisation
screen readers
```

Therefore the UI Engine must also produce:

```text
SemanticTree
```

and then:

```text
Windows → UI Automation
macOS   → NSAccessibility
Linux   → AT-SPI
```

Accessibility must never be bolted on in v3.

Otherwise, by then the UI tree and drawing model will most likely no longer be suited to adding semantic information.

---

# 20. Product UI Is Opinionated Too

Product packagers cannot submit:

```text
HTML
CSS
native code
custom page plugin
```

They can only configure:

```text
product name
logo
accent
copy
license
component choices
optional install preferences
```

The framework controls:

```text
spacing
typography
motion
layout
accessibility
error UI
progress UI
```

Only this way can we get, at the same time:

> **Consistent visual quality + a tiny runtime + testability.**

---

# 21. CLI Contract

The same binary supports:

```text
setup
```

→ GUI.

As well as:

```bash
setup install --silent
setup update --silent
setup repair --silent
setup uninstall --silent
```

Recommended for automation environments:

```bash
setup install \
    --channel stable \
    --scope machine \
    --json
```

It emits versioned JSON events:

```json
{"schema":1,"phase":"resolve"}
{"schema":1,"phase":"download","progress":0.37}
{"schema":1,"phase":"verify"}
{"schema":1,"phase":"execute","progress":0.82}
{"schema":1,"phase":"bootstrap"}
{"schema":1,"phase":"complete"}
```

The CLI's:

```text
exit code
JSON schema
```

are also a public compatibility contract.

---

# 22. Runtime Size Budget

I would write:

> **Online GUI installer ≤30 MiB**

directly as a release gate, not as an aspiration.

Recommended internal budget:

| Module | Initial budget |
|---|---:|
| Installer Core | ≤5 MiB |
| UI/layout/renderer | ≤4 MiB |
| platform integration | ≤3 MiB |
| HTTP/TUF/crypto | ≤3 MiB |
| archive/decompression | ≤3 MiB |
| fonts/assets/branding | ≤4 MiB |
| priv helper / maintenance | ≤3 MiB |
| reserved | ≤5 MiB |
| **Total** | **≤30 MiB** |

A simple Zig binary by itself can be very small; Zig's official material even demonstrates KB-scale static examples using `ReleaseSmall`, so the real size pressure will come from UI, crypto, text, and assets, not from the language runtime.

The offline artifact payload **does not count against this 30 MiB budget**.

---

# 23. Testing Architecture

Testing cannot consist only of:

```text
installer.exe launches
```

What this system really needs to verify is:

> **protocol correctness + transactional correctness + platform correctness + visual correctness.**

I recommend establishing a six-layer testing model.

| Layer | What it verifies |
|---|---|
| L0 Static / Schema | manifest, dependency, license, size, forbidden capabilities |
| L1 Pure Core | resolver, planner, state machine |
| L2 Fault / Security | crash, fuzz, malicious metadata/archive |
| L3 Platform Contract | filesystem/service/shortcut/elevation adapter |
| L4 Scenario E2E | install/update/repair/uninstall |
| L5 Compatibility Certification | OS × arch × display × privilege matrix |

---

# 24. The Most Important Testing Technique: Virtual Platform

Every OS side effect must first go through:

```text
PlatformCapabilities
```

For example:

```text
FileSystem
ServiceManager
ShortcutManager
PrivilegeManager
ProcessManager
Clock
Network
```

In tests it is replaced with:

```text
VirtualPlatform
```

Then:

```text
DesiredState
      ↓
Planner
      ↓
InstallationPlan
      ↓
VirtualPlatform
```

can run tens of thousands of deterministic tests on any CI.

---

# 25. Crash Testing Must Be Able to "Kill After Every Operation"

This is the biggest difference between an installer and an ordinary application.

For example, given the plan:

```text
op1
op2
op3
op4
commit
op5
```

the test framework automatically executes:

```text
kill after op1
restart

kill after op2
restart

kill after op3
restart

...
```

After every restart it checks the invariant:

```text
Active == OLD
OR
Active == NEW
```

It must never be:

```text
Active == MIXED
```

This is far more important than ordinary happy-path E2E.

---

# 26. Security / Fuzz Test

The following must be attacked with particular focus:

```text
manifest parser
TUF metadata parser
archive parser
path normalization
IPC
journal recovery
bootstrap protocol
```

Attack cases include:

```text
../ traversal
absolute paths
symlink escape
hardlink escape
archive bomb
integer overflow
oversized metadata
invalid UTF-8
duplicate JSON fields
expired timestamp
old snapshot
wrong artifact hash
component dependency cycle
forged channel metadata
IPC replay
transaction-id confusion
privileged path escape
```

In particular:

> **No artifact may write outside the staging root through archive extraction.**

This is a hard invariant.

---

# 27. Platform Contract Test

Every platform backend must implement the same conformance suite:

```text
PlatformContract
```

For example:

```text
create managed file
atomic replace
locked-file behavior
ACL
service create/remove
shortcut create/remove
file association
process detection
privilege escalation
restart recovery
```

So when adding:

```text
platform/freebsd.zig
```

it is not:

> "It compiles, so FreeBSD is supported."

Instead it must have:

```text
Platform Contract Suite = PASS
```

before it is allowed to become a supported platform.

---

# 28. Compatibility Matrix

Do not write the support scope as a vague:

> Windows/macOS/Linux supported.

It should be machine-readable instead:

```yaml
support:
  windows:
    architectures: [x86_64, arm64]
    releases: [...]
    scopes: [user, machine]

  macos:
    architectures: [arm64, x86_64]
    releases: [...]

  linux:
    architectures: [x86_64, arm64]
    desktops:
      - wayland
      - x11
```

This file itself generates the CI matrix.

---

# 29. Three Tiers of Compatibility

| Tier | Meaning | Release Gate |
|---|---|---|
| Tier 0 | officially fully supported | must pass completely on every release |
| Tier 1 | officially compatible but not primary | full run on nightly / release candidate |
| Tier 2 | best effort/community | compile + basic smoke |

For example, Linux cannot just say:

> "Linux supported".

It should be specific down to actual environment contracts such as:

```text
Ubuntu LTS + GNOME + Wayland
Debian stable + GNOME
Fedora + GNOME + Wayland
RHEL-like + X11
KDE + Wayland
```

Which specific versions are supported is decided by product strategy, not unilaterally by the framework.

---

# 30. Real VM / Hardware Lab

Cross compilation cannot replace runtime tests.

Recommended:

```text
PR:
VirtualPlatform
+ small native smoke

Nightly:
Tier-0 VM matrix

Release Candidate:
full Tier-0
+ Tier-1
+ real hardware samples

Weekly:
OS preview / beta compatibility
```

Areas that especially need real hardware include:

```text
Windows ARM64
Apple Silicon
GPU/rendering
high-DPI
UAC
file locking
reboot/shutdown
screen reader
```

Zig unifies the build very well, but the runtime environment must still be verified in practice.

---

# 31. GUI Testing

Because the UI uses an in-house renderer, it can get more deterministic tests than a Web UI.

The first layer is direct snapshots:

```text
UiTree
DisplayList
SemanticTree
```

The second layer:

```text
offscreen render
      ↓
golden image comparison
```

Only the third layer is:

```text
real OS screenshot
```

The test matrix covers at least:

```text
100 / 125 / 150 / 200% DPI
light / dark
English
Chinese
long German-like strings
RTL
keyboard-only
screen reader semantics
small screen
large screen
```

---

# 32. Recommended Release Acceptance Gates

I recommend establishing the following gates directly in the first version:

| Item | Gate |
|---|---|
| Online installer size | ≤30 MiB |
| Generic script/exec capabilities | **0** |
| Undeclared dynamic dependency | **0** |
| Tier-0 compatibility | 100% |
| Transaction crash-injection | 100% invariant pass |
| TUF negative/security suite | 100% |
| Install → repair → uninstall | clean |
| Upgrade | supported previous versions PASS |
| GUI golden tests | PASS |
| Accessibility semantics | PASS |
| Binary / artifact signing | PASS |
| CLI compatibility suite | PASS |
| Dependency license policy | PASS |

In addition, set a size regression gate:

```text
>5% binary growth
```

must have human review.

This prevents the "small framework" from slowly turning into 150 MB three years later.

---

# 33. Framework Compatibility

Three protocols must be versioned separately:

```text
Manifest Schema
Installer Engine
App Bootstrap Protocol
```

For example:

```text
manifest_schema = 3
min_installer = 2.4
bootstrap_protocol = 1
```

If the installer does not understand the schema:

> **Fail closed.**

It must not guess.

Nor may compatibility be achieved through scripts.

An old installer must first upgrade the framework runtime before continuing the product upgrade.

---

# 34. How the Framework Runtime Upgrades Itself

After installation, keep:

```text
maintainer
```

but do not run a resident service.

When the application updates:

```text
application
    │
    ▼
maintainer update
```

The `maintainer` itself is also a reserved managed component:

```text
__installer_runtime
```

Updates use:

```text
stage
exit old maintainer
activate new maintainer
resume transaction
```

rather than self-overwrite.

Therefore the installer runtime itself also obeys the:

```text
transactional update
```

rule.

---

# 35. Role Model

I recommend clearly distinguishing six roles here. One person may take on several roles, but ownership must not be mixed.

| Role | Owns | Does not own |
|---|---|---|
| **Framework Developer** | Engine, schema, platform adapters, GUI, privilege, conformance | product business migration |
| **Component Developer** | Component artifact, entrypoint, App Bootstrap | installer scripts / arbitrary machine mutation |
| **Product Packager** | component composition, branding, OS integration declarations, scope | custom installer code |
| **SRE / Release** | repository, channel, promotion, availability, incident operation | modifying artifact content |
| **Security / PKI** | trust policy, TUF keys, root rotation, signing thresholds | product features |
| **QA / Compatibility** | support matrix, certification, compat lab | release content |
| **User / Enterprise Admin** | GUI / CLI interaction | implementation policy |

---

# 36. Component Developer Workflow

```text
Implement component
       │
       ▼
Build platform artifact
       │
       ▼
component validate
       │
       ├── structure
       ├── dependency
       ├── bootstrap protocol
       └── security checks
       │
       ▼
Component Conformance
       │
       ▼
Immutable Artifact Registry
```

What a component developer delivers is a:

> **deployable component**

rather than an:

> **installer implementation**.

---

# 37. Framework Developer Workflow

```text
Framework change
      │
      ▼
Unit / property tests
      │
      ▼
VirtualPlatform suite
      │
      ▼
Platform Contract suite
      │
      ▼
Compatibility Lab
      │
      ▼
Security / fuzz
      │
      ▼
Framework Release
      │
      ▼
Conformance SDK
```

A framework release must publish all of the following together:

```text
runtime
schema documentation
conformance test suite
compatibility matrix
migration notes
```

---

# 38. Product Packager Workflow

Product packagers do not write Zig.

Ideally it is only:

```text
select component versions
        │
        ▼
define product manifest
        │
        ├── branding
        ├── required/optional components
        ├── install scope
        └── OS integrations
        │
        ▼
product validate
        │
        ▼
compose
        │
        ▼
setup binaries
+
release manifest
```

So:

```text
Product Packaging
```

should be configuration work, not software development.

---

# 39. SRE / Release Workflow

```text
Immutable candidate artifact
          │
          ▼
      nightly
          │
      telemetry
          │
          ▼
        beta
          │
     acceptance
          │
          ▼
       stable
```

Key principle:

> **Promotion changes signed release metadata, never artifact bytes.**

What SRE mainly cares about:

```text
repository health
download success
update adoption
installer failures
channel distribution
TUF metadata freshness
rollout percentage
bad-release incident
```

rather than:

```text
how to copy DLLs.
```

---

# 40. Security / PKI Workflow

Recommended:

```text
Root key
offline / threshold

Stable targets
controlled signing

Beta/nightly
automation-friendly signing

Timestamp
online short-lived key
```

TUF itself separates different privileges through roles and signature thresholds, and it allows delegated targets roles, so it fits naturally with release role separation.

Root rotation, key compromise, and emergency signing should each become a separate runbook.

---

# 41. User Workflow

Ordinary users:

```text
Download setup
     │
     ▼
OS verifies code signature
     │
     ▼
Native Installer GUI
     │
     ▼
Install
     │
     ├── Resolve
     ├── Download
     ├── Verify
     ├── Install
     └── Bootstrap
     │
     ▼
Launch
```

The default experience should be very simple.

An opinionated installer should not inherently have:

```text
15-page wizard
advanced directory tree
hundreds of options
```

Advanced scenarios are handed to:

```text
enterprise CLI
```

---

# 42. Enterprise Admin Workflow

Administrators:

```bash
setup install \
    --silent \
    --scope machine \
    --channel stable \
    --json
```

This can then be used for:

```text
MDM
SCCM
Intune
Ansible
CI image build
enterprise provisioning
```

The GUI and CLI ultimately invoke the same:

```text
InstallationPlan
```

so the two paths behave exactly the same.

---

# 43. Recommended Ownership Flow

The whole thing can be condensed into:

```text
Component Developer
      │
      │ immutable component
      ▼
Artifact Registry
      │
      ▼
Product Packager
      │
      │ product release
      ▼
QA / Compatibility
      │
      ▼
Security Signing
      │
      ▼
SRE / Release
      │
      │ channel promotion
      ▼
Repository
      │
      ▼
Installer Framework
      │
      ▼
User / Enterprise Admin
```

Meanwhile:

```text
Framework Developer
```

provides the horizontal substrate:

```text
┌──────────────────────────────────────────┐
│ schema / engine / UI / platform / tests │
└──────────────────────────────────────────┘
```

It does not take part in the feature decisions of each product release.

---

# 44. The Organizational Boundaries Most Worth Holding

The value of the whole framework really comes from four "not allowed" rules.

```text
Component Developer
    cannot write installer logic

Product Packager
    cannot write executable installer extensions

SRE
    cannot change immutable artifacts

Installer
    cannot understand application-specific migration
```

Once these boundaries are held, the system becomes very easy to govern.

Once you open up:

```text
custom scripts
```

the responsibilities of these four roles quickly get mixed together again.

---

# 45. Recommended Phase-One MVP

The MVP should not implement every installer capability from the start.

Do only:

```text
Windows x64
macOS arm64
Linux x64

user + machine installation

managed files
shortcut
file association
service

GUI + CLI

online + offline

TUF

install / update / repair / uninstall

App Bootstrap v1

transaction recovery
```

The UI only needs:

```text
Welcome
Options
Progress
Error
Complete
```

First prove that:

> **native GUI <30 MiB + transactional engine + no-script component model**

holds.

Only then expand OS integration capabilities.

---

# 46. Final Technical Boundaries

I recommend ultimately defining the whole project as three stable contracts:

```text
                    PRODUCT CONTRACT
              Declarative Product Manifest
                         │
                         ▼
                INSTALLER CONTRACT
        Desired State → Transactional Deployment
                         │
                         ▼
                  APP CONTRACT
                  Bootstrap Protocol
```

Wrapped around the outside is:

```text
TUF
```

as the:

```text
Trust Contract
```

The final result is:

```text
             TUF / Trust
                 │
                 ▼
        Declarative Manifest
                 │
                 ▼
        Zig Installer Engine
                 │
        typed capabilities
                 │
                 ▼
          Native Platform
                 │
                 ▼
           App Bootstrap
```

This is the end state I consider most worth pursuing.

It is not "a smaller CEF installer".

It is a:

> **small, native, auditable deployment substrate with deliberately limited semantics.**

This is the real architectural advantage that Zig + native + opinionated design can bring.
