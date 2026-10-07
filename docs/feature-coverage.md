# Installer framework feature coverage

This catalog proposes the coverage boundary for Niobium across authoring, distribution, deployment and maintenance. Each row names a capability and an acceptance question. It does not declare implementation, platform support or release commitments.

The [current roadmap](roadmap-v0.2.md) owns scheduled work. The [acceptance plan](acceptance-plan-v0.1.md) owns actual results. Existing contracts remain authoritative through the [documentation index](README.md#specifications-normative).

## Reading the catalog

| Boundary | Meaning | Change authority |
|---|---|---|
| B | A current contract covers this capability; evidence still needs checking | The linked spec and accepted ADRs |
| C | A candidate for framework-owned functionality | Design review, contract and acceptance work before implementation |
| I | An integration owned by the build pipeline, application or deployment operator | The integration contract; no runtime installer plugins |
| X | Excluded under the current architecture | A new decision is required to change the boundary |

Priority is a proposal: P0 protects deployment integrity or release trust; P1 enables product adoption; P2 expands advanced use cases. Priority does not change the current roadmap. X rows use no priority.

FC identifiers are catalog references, not product acceptance IDs. B means contract coverage, not PASS. Candidates have no assumed schema fields or CLI commands. Platform coverage is evaluated separately for each OS, architecture and user/machine scope.

## Product definition

| ID | Capability | Boundary | Priority | Acceptance question |
|---|---|---|---|---|
| FC-MOD-01 | Product identity, publisher and display version | B | P0 | Does strict validation reject malformed or ambiguous identity? |
| FC-MOD-02 | Release sequence and minimum installer version | B | P0 | Are incompatible or regressive releases rejected before mutation? |
| FC-MOD-03 | Required, default and optional components | B | P1 | Does GUI/CLI selection produce the same desired state? |
| FC-MOD-04 | Component groups and workload presets | C | P1 | Can a workload expand into an explicit, reproducible selection? |
| FC-MOD-05 | Versioned dependencies, conflicts and replacements | C | P1 | Are cycles, unsatisfied constraints and conflicts explained before download? |
| FC-MOD-06 | Architecture and platform payload selection | B | P0 | Is a missing target reported explicitly rather than substituted? |
| FC-MOD-07 | User and machine installation scopes | B | P0 | Does scope control paths and required privilege consistently? |
| FC-MOD-08 | Minimum OS, runtime and hardware prerequisites | C | P1 | Can preflight reject an incompatible host without executing product commands? |
| FC-MOD-09 | Multiple instances and versions installed side by side | C | P2 | Are identity, locks, integrations and update channels isolated? |
| FC-MOD-10 | Installed-state inventory and drift classification | C | P1 | Can managed changes be distinguished from user-owned data? |

## Payload authoring and packaging

| ID | Capability | Boundary | Priority | Acceptance question |
|---|---|---|---|---|
| FC-PKG-01 | Component construction and validation | B | P0 | Are entrypoints, executable declarations and payload layout validated? |
| FC-PKG-02 | Immutable artifacts addressed by digest | B | P0 | Does every reference identify exact authorized bytes? |
| FC-PKG-03 | Deterministic unsigned payload generation | B | P1 | Do identical inputs produce identical payload bytes? |
| FC-PKG-04 | File inclusion, exclusion and duplicate diagnostics | C | P1 | Can authors inspect the exact file inventory before packing? |
| FC-PKG-05 | Permission and executable metadata | B | P0 | Does extraction follow the component contract rather than archive modes? |
| FC-PKG-06 | Online, offline and embedded bundle generation | B | P1 | Do each bundle's contents and source layout satisfy the contracts? |
| FC-PKG-07 | Mixed embedded and remote payload bundles | C | P2 | Are source precedence and offline behavior explicit and trusted? |
| FC-PKG-08 | Existing native application and language bundle ingestion | I | P1 | Can validated output from native builds, Electron or PyInstaller be packaged? |
| FC-PKG-09 | Native MSI, MSIX, PKG, DEB or RPM export adapters | C | P2 | Can each build-time adapter define ownership without competing updaters? |
| FC-PKG-10 | Compression, size and disk-budget reports | C | P1 | Are download, expansion, staging and retained-version costs separated? |

## Repositories and publishing

| ID | Capability | Boundary | Priority | Acceptance question |
|---|---|---|---|---|
| FC-REL-01 | HTTP and local-directory repositories | B | P0 | Do both sources enforce the same release trust contract? |
| FC-REL-02 | Signed stable, beta and nightly channels | B | P0 | Can channel metadata authorize only its delegated product targets? |
| FC-REL-03 | Metadata-only promotion of tested artifacts | C | P0 | Are promoted artifact bytes identical to the signed, tested bytes? |
| FC-REL-04 | Signed release notes and update notices | C | P1 | Are displayed notes bound to the selected release and safely rendered? |
| FC-REL-05 | Key generation, rotation and recovery workflows | C | P0 | Can a maintainer rotate keys without bypassing root authorization? |
| FC-REL-06 | Atomic repository publication and validation | C | P0 | Can an interrupted publish expose only a valid old or new snapshot? |
| FC-REL-07 | Mirrors, CDN and object storage deployment | I | P1 | Does an untrusted transport remain unable to authorize new bytes? |
| FC-REL-08 | Percentage rollout and deployment cohorts | C | P2 | Are cohort decisions bounded, privacy-aware and reproducible? |
| FC-REL-09 | Withdrawn releases and authorized version rollback | C | P0 | Can older application bytes be released under a new authorized sequence? |
| FC-REL-10 | Release retention, repository GC and audit inventory | C | P2 | Are artifacts needed by installed clients or offline media preserved? |

## Transfer and caching

| ID | Capability | Boundary | Priority | Acceptance question |
|---|---|---|---|---|
| FC-NET-01 | Download length and digest validation | B | P0 | Are incomplete or modified bytes rejected before extraction? |
| FC-NET-02 | Component-selective download | B | P1 | Are only the resolved artifacts fetched? |
| FC-NET-03 | Verified cache reuse | B | P1 | Can corrupt cache entries ever be treated as valid payloads? |
| FC-NET-04 | Resume after interrupted download | C | P1 | Is resumed content fully verified against the authorized target? |
| FC-NET-05 | Bounded retries, backoff and network timeouts | C | P0 | Does every failure terminate within a defined retry and time budget? |
| FC-NET-06 | Proxy, authentication and custom trust-store policy | C | P1 | Are credentials kept out of logs and never used to bypass release trust? |
| FC-NET-07 | Bandwidth limits and bounded parallel downloads | C | P2 | Are limits enforced without starving cancellation or verification? |
| FC-NET-08 | Binary differential downloads with full-payload fallback | C | P2 | Does reconstruction yield the exact authorized full-artifact digest? |
| FC-NET-09 | Cache quotas, GC and shared-cache isolation | C | P1 | Are in-use artifacts and other users' entries protected? |
| FC-NET-10 | Air-gapped freshness and offline update policy | C | P1 | Is expired metadata handled by an explicit policy without silent trust bypass? |

## Deployment lifecycle

| ID | Capability | Boundary | Priority | Acceptance question |
|---|---|---|---|---|
| FC-LIF-01 | Fresh installation | B | P0 | Does the installed state match the selected manifest? |
| FC-LIF-02 | Installation discovery and status | B | P1 | Are missing, installed and incomplete states distinguishable? |
| FC-LIF-03 | Component add, remove and selection modification | C | P1 | Can selections change while maintaining dependency and ownership rules? |
| FC-LIF-04 | Update and already-current no-op | B | P0 | Does an unchanged release avoid machine mutation? |
| FC-LIF-05 | Integrity checking and repair | B | P0 | Are damaged managed files repaired without deleting user data? |
| FC-LIF-06 | Uninstall and owned-integration cleanup | B | P0 | Are only framework-owned resources removed? |
| FC-LIF-07 | Portable Run with trusted cache reuse | B | P1 | Does execution avoid installed-profile machine integrations? |
| FC-LIF-08 | Application coordination and files-in-use handling | C | P1 | Are running processes handled without forced data loss? |
| FC-LIF-09 | Restart requirements and reboot continuation | C | P2 | Can recovery distinguish pending restart from completed deployment? |
| FC-LIF-10 | App Bootstrap handoff and pending activation | B | P0 | Does application failure preserve the documented committed state? |

## Transactions and recovery

| ID | Capability | Boundary | Priority | Acceptance question |
|---|---|---|---|---|
| FC-TXN-01 | Durable journal and typed installation plan | B | P0 | Can recovery reconstruct the transaction after process loss? |
| FC-TXN-02 | Staging isolation and active-version switching | B | P0 | Can writes affect active files before commit? |
| FC-TXN-03 | Precommit rollback and postcommit roll-forward | B | P0 | Does every kill point recover to a contract-valid OLD or NEW state? |
| FC-TXN-04 | Idempotent apply, rollback and verification | B | P0 | Can interrupted recovery be repeated without duplicate effects? |
| FC-TXN-05 | Concurrent operation and cross-user exclusion | C | P0 | Can two users mutate one machine installation concurrently? |
| FC-TXN-06 | Cancellation and privilege-helper loss | B | P0 | Are interrupted operations resolved through journal recovery? |
| FC-TXN-07 | Disk-full, locked-file and permission fault recovery | C | P0 | Are original failure and recovery failure separately actionable? |
| FC-TXN-08 | Installed-state reconciliation after external damage | C | P0 | Can metadata, active pointer and actual files disagree without false success? |
| FC-TXN-09 | Retained versions and transactional cleanup | C | P1 | Does GC preserve active, recovery-needed and policy-retained versions? |
| FC-TXN-10 | Cross-volume and interrupted platform-operation recovery | C | P0 | Are copy, rename and integration boundaries covered by platform fault tests? |

## Operating-system integrations

| ID | Capability | Boundary | Priority | Acceptance question |
|---|---|---|---|---|
| FC-OS-01 | Managed files and directories | B | P0 | Are writes and removals confined to the declared ownership boundary? |
| FC-OS-02 | Application shortcuts | B | P1 | Are platform-specific shortcuts maintained across update and uninstall? |
| FC-OS-03 | File associations | B | P1 | Are platform limits and the user's default-handler choice respected? |
| FC-OS-04 | Application and uninstall registration | B | P1 | Does platform capability reporting match actual registration behavior? |
| FC-OS-05 | System services and user agents | B | P1 | Are supported scopes explicit, with rollback and uninstall cleanup? |
| FC-OS-06 | URL and protocol handlers | C | P1 | Are collisions, ownership and unregister behavior specified per platform? |
| FC-OS-07 | PATH and typed environment entries | C | P1 | Can uninstall remove only the entry this product owns? |
| FC-OS-08 | Login startup registration | C | P2 | Is startup consent visible and removal ownership-aware? |
| FC-OS-09 | Scheduled tasks, firewall rules and privileged integrations | C | P2 | Does each proposed capability get a closed contract and inverse operation? |
| FC-OS-10 | macOS bundles and Linux desktop/MIME integration | C | P1 | Can immutable native objects retain OS trust and desktop registration? |

## Developer experience

| ID | Capability | Boundary | Priority | Acceptance question |
|---|---|---|---|---|
| FC-DX-01 | Prebuilt tools and a versioned build API | C | P1 | Can a product team build an installer without building Niobium from source? |
| FC-DX-02 | Desktop, CLI, Electron, Python and service scaffolds | C | P1 | Does each generated example validate and complete a real install? |
| FC-DX-03 | Schema completion and field-level diagnostics | C | P1 | Do diagnostics locate the field and explain a permitted correction? |
| FC-DX-04 | One documented local packaging workflow | C | P1 | Can a new author produce a validated installer from an example? |
| FC-DX-05 | Screen preview before release packaging | C | P1 | Does preview use the same renderer and valid product data? |
| FC-DX-06 | Plan preview and read-only validation | C | P1 | Can authors inspect effects without writes, elevation or application execution? |
| FC-DX-07 | Manifest, payload and installation-state comparison | C | P1 | Can an author identify why a component or integration changes? |
| FC-DX-08 | CLI help, structured errors and stable exit codes | B | P1 | Do GUI, CLI and SDK expose compatible failure categories? |
| FC-DX-09 | CI examples, source maps and troubleshooting documentation | I | P1 | Can pipeline failures be traced to product inputs and retained evidence? |
| FC-DX-10 | Schema migration and tool/runtime compatibility checks | C | P1 | Are breaking changes diagnosed before generating or deploying artifacts? |

## End-user experience

| ID | Capability | Boundary | Priority | Acceptance question |
|---|---|---|---|---|
| FC-UX-01 | Welcome, options, progress, error and completion flows | B | P1 | Does each view reflect engine-confirmed state? |
| FC-UX-02 | Component explanations, dependencies and size estimates | C | P1 | Can the user understand the selected features and storage costs? |
| FC-UX-03 | Location selection and permissions/disk-space preflight | C | P1 | Does the installer explain problems before machine mutation? |
| FC-UX-04 | Honest phase progress, throughput and cancellability | C | P1 | Are unknown estimates shown as unknown and cancellation boundaries explained? |
| FC-UX-05 | Recovery, retry, repair and support actions | C | P1 | Does the error flow offer only actions valid for the recorded state? |
| FC-UX-06 | Maintenance and in-application update consent | C | P1 | Can users distinguish download, apply, restart and activation states? |
| FC-UX-07 | Dark mode, high contrast, DPI and reduced motion | B | P1 | Do appearance settings preserve legibility and interaction behavior? |
| FC-UX-08 | Keyboard access and assistive-technology bridges | C | P1 | Can screen readers and keyboard users complete the entire lifecycle? |
| FC-UX-09 | Localization, Unicode, IME, shaping and RTL layout | C | P2 | Are long translations and non-Latin input usable on each target? |
| FC-UX-10 | User-data retention and informed destructive choices | C | P0 | Are application-owned data and framework-owned deployment files distinguished? |

## Customization and extension boundaries

| ID | Capability | Boundary | Priority | Acceptance question |
|---|---|---|---|---|
| FC-CUS-01 | Product name, publisher, logo, accent and plain text | B | P1 | Does invalid branding fail safely without affecting deployment semantics? |
| FC-CUS-02 | Closed, versioned theme choices | C | P1 | Are token changes constrained by accessibility and size gates? |
| FC-CUS-03 | Data-only presets that generate ordinary product files | C | P1 | Can generated files be maintained without a preset runtime? |
| FC-CUS-04 | Validated product and component presentation metadata | C | P1 | Can descriptions vary without executable markup or layout code? |
| FC-CUS-05 | Framework-maintained screens and component evolution | C | P2 | Does each addition update UI contracts, semantics and goldens? |
| FC-CUS-06 | Typed policy defaults and enterprise branding | C | P2 | Are policy-controlled choices visible and still validated? |
| FC-CUS-07 | Repository-owned feature modules fixed at build time | C | P1 | Does each module own validation, planning, undo and conformance? |
| FC-CUS-08 | Build-time feature selection and size profiles | C | P2 | Are removed capabilities reported explicitly rather than silently ignored? |
| FC-CUS-09 | Build-pipeline adapters and artifact exporters | I | P1 | Can adapters run outside the installer without weakening its contracts? |
| FC-CUS-10 | App Bootstrap and host-application experience integration | B | P1 | Does product logic stay in the application with the documented privilege boundary? |

## SDK and application integration

| ID | Capability | Boundary | Priority | Acceptance question |
|---|---|---|---|---|
| FC-SDK-01 | Static and dynamic Distribution Core libraries | B | P1 | Can hosts consume a versioned ABI without installer UI dependencies? |
| FC-SDK-02 | Update check, resolve, fetch, stage and commit | B | P0 | Are call order, lock lifetime and no-op behavior tested through the public API? |
| FC-SDK-03 | Events, cancellation and structured error retrieval | B | P1 | Are callback lifetimes and cancellation behavior defined and tested? |
| FC-SDK-04 | Portable resolution and execution | B | P1 | Are process outcomes returned without hiding framework failures? |
| FC-SDK-05 | Node-API and Electron bindings | C | P1 | Can packaged applications exercise the same engine and trust path? |
| FC-SDK-06 | Python, .NET, Rust, Go and C/C++ consumption examples | I | P1 | Do examples verify ABI layout, ownership and error handling? |
| FC-SDK-07 | Application-owned update scheduling and UI | I | P1 | Can the application control timing while the core controls deployment? |
| FC-SDK-08 | Host privilege and machine-scope policy | B | P0 | Does an unprivileged library host receive the documented error? |
| FC-SDK-09 | Threading, reentrancy and API compatibility guarantees | C | P0 | Are unsupported concurrent calls rejected and binary compatibility checked? |
| FC-SDK-10 | Business activation, settings and data migration | I | P1 | Does application failure remain separate from machine-deployment success? |

## Enterprise administration

| ID | Capability | Boundary | Priority | Acceptance question |
|---|---|---|---|---|
| FC-ADM-01 | Silent install, update, repair and uninstall | B | P1 | Can operators complete the lifecycle with machine-readable outcomes? |
| FC-ADM-02 | Explicit license-agreement acceptance policy | C | P1 | Can unattended operation record the agreed document and applicable policy? |
| FC-ADM-03 | Desired component configuration import/export | C | P1 | Does a shared configuration reproduce selection across compatible hosts? |
| FC-ADM-04 | Channel pinning and update policy | C | P1 | Are application versions and authorized release sequences handled separately? |
| FC-ADM-05 | Managed offline repositories and air-gap provisioning | I | P1 | Can operators distribute validated media and refresh trust metadata? |
| FC-ADM-06 | Maintenance windows and restart deferral | I | P2 | Does external scheduling respect transaction and consent boundaries? |
| FC-ADM-07 | Device-management and package-manager integration | I | P1 | Are detection, exit-code and uninstall rules documented for each integration? |
| FC-ADM-08 | Fleet inventory and configuration-drift export | C | P2 | Can operators consume local state without collecting application secrets? |
| FC-ADM-09 | Policy provenance and audit records | C | P1 | Can an operator explain which policy authorized the deployed selection? |
| FC-ADM-10 | Multiuser and shared-machine deployment | C | P0 | Are discovery, access control and integration ownership correct for every user? |

## Runtime security and trust

| ID | Capability | Boundary | Priority | Acceptance question |
|---|---|---|---|---|
| FC-SEC-01 | Strict schemas, bounded input and forbidden-field rejection | B | P0 | Are malformed, oversized and executable manifest fields rejected? |
| FC-SEC-02 | TUF signatures, delegation and target authorization | B | P0 | Can unauthorized release metadata or payloads reach deployment? |
| FC-SEC-03 | Rollback, freeze and metadata-mixing defenses | B | P0 | Are replayed or inconsistent trust states rejected? |
| FC-SEC-04 | OS publisher signatures and macOS notarization | I | P0 | Are signatures checked on the exact distributed native objects? |
| FC-SEC-05 | Root-confined extraction and archive-bomb defenses | B | P0 | Do malicious archives fail without writes outside staging? |
| FC-SEC-06 | Least privilege and closed helper operations | B | P0 | Can malformed IPC or a lost helper cause unauthorized mutation? |
| FC-SEC-07 | Cache, staging and path-race attack resistance | C | P0 | Are attacker-controlled links, replacements and shared paths rejected? |
| FC-SEC-08 | Ownership-aware cleanup and integration collision policy | B | P0 | Can update or uninstall overwrite another product's resources? |
| FC-SEC-09 | Redacted logs, minimal process environment and privacy policy | C | P0 | Are secrets and sensitive identifiers absent from retained diagnostics? |
| FC-SEC-10 | Threat model and independent security review | I | P0 | Are trust boundaries reviewed separately from implementation claims? |

## Security scanning and release gates

| ID | Capability | Boundary | Priority | Acceptance question |
|---|---|---|---|---|
| FC-SCAN-01 | Framework and native-dependency SAST/SCA | I | P0 | Can source findings and dependency advisories be traced to shipped bytes? |
| FC-SCAN-02 | Application-payload dependency and vulnerability scanning | I | P0 | Are nested native, Electron and Python dependencies inventoried? |
| FC-SCAN-03 | SBOM generation, merge and export | I | P0 | Are framework, embedded libraries and product payloads represented without identity loss? |
| FC-SCAN-04 | Open-source license and notice analysis | I | P1 | Are obligations, unknown licenses and notice omissions visible? |
| FC-SCAN-05 | Secret, credential and private-key scanning | I | P0 | Does the gate reject credentials accidentally packaged in payloads or configs? |
| FC-SCAN-06 | Malware and sandbox checks of final signed artifacts | I | P0 | Is the scan tied to the distributed digest and is upload consent explicit? |
| FC-SCAN-07 | Binary hardening, signatures and dynamic-dependency inspection | I | P0 | Do final binaries satisfy platform protection and dependency policies? |
| FC-SCAN-08 | Digest-bound reports and build-provenance attestations | C | P0 | Can altered reports, subjects or builder identities pass release verification? |
| FC-SCAN-09 | Gate policy, VEX and expiring finding exceptions | C | P0 | Are exceptions attributable, scoped and expired without changing test outcomes? |
| FC-SCAN-10 | Post-release rescanning and offline advisory freshness | I | P1 | Can new advisories trigger action without modifying immutable artifacts? |

## Operations, compliance and support

| ID | Capability | Boundary | Priority | Acceptance question |
|---|---|---|---|---|
| FC-OPS-01 | Structured phase events and installation logs | B | P1 | Can support distinguish trust, transport, filesystem and application failures? |
| FC-OPS-02 | Crash diagnostics and redacted support bundles | C | P1 | Does export preserve useful evidence without disclosing secrets? |
| FC-OPS-03 | Opt-in telemetry, consent and retention controls | I | P2 | Can the product operate with telemetry disabled and consent revoked? |
| FC-OPS-04 | Release inventory and audit evidence retention | I | P0 | Can installed releases be traced to signed artifacts and test reports? |
| FC-OPS-05 | Vulnerability disclosure and incident response | I | P0 | Are reporting, triage, withdrawal and recovery responsibilities explicit? |
| FC-OPS-06 | Maintainer key backup and disaster recovery | I | P0 | Can recovery restore authorized publication without recreating past artifacts? |
| FC-OPS-07 | Product entitlement and commercial-license integrations | I | P2 | Does application-owned activation avoid blocking transaction recovery? |
| FC-OPS-08 | Upgrade/uninstall user-data policy documentation | I | P1 | Can users predict data retention independently of deployment ownership? |
| FC-OPS-09 | Toolchain and dependency support lifecycle | I | P1 | Are upstream advisories and end-of-support dates assigned to maintainers? |
| FC-OPS-10 | Accessibility, legal and export/compliance evidence | I | P2 | Are jurisdiction-specific conclusions reviewed by the responsible operator? |

## Quality, portability and performance

| ID | Capability | Boundary | Priority | Acceptance question |
|---|---|---|---|---|
| FC-QA-01 | Static, unit, fault, contract, scenario and real-OS lanes | B | P0 | Does each claimed capability identify the lane that actually ran? |
| FC-QA-02 | Install/update/repair/uninstall and portable scenario matrix | C | P0 | Are online, offline and interrupted paths covered across profiles? |
| FC-QA-03 | Kill points, seeded simulation and malicious-input fuzzing | B | P0 | Do recovery and parser invariants hold under repeated faults? |
| FC-QA-04 | OS/architecture/scope tiers and real-machine evidence | B | P0 | Are platform claims gated by actual contract and OS evidence? |
| FC-QA-05 | UI golden, accessibility and worst-case content coverage | C | P1 | Are focus, scale, contrast and text overflow checked without blanket snapshot updates? |
| FC-QA-06 | Public ABI, schema and CLI compatibility tests | C | P0 | Do older consumers retain their documented behavior? |
| FC-QA-07 | Installer size, memory, CPU and dependency budgets | C | P1 | Are budgets explicit and measured on release artifacts? |
| FC-QA-08 | Startup, download, extraction and recovery benchmarks | C | P1 | Are phase costs measured for small, large and many-file payloads? |
| FC-QA-09 | Clean-host installation and final-byte release qualification | I | P0 | Are signed and notarized shipping artifacts tested rather than rebuilt substitutes? |
| FC-QA-10 | Cold-cache, warm-cache and constrained-environment tests | C | P1 | Are low disk space, slow networks, offline hosts and unavailable dependencies covered? |

## Technology compatibility assessment

| ID | Capability | Boundary | Priority | Acceptance question |
|---|---|---|---|---|
| FC-COMP-01 | Native C/C++/Rust/Go application payloads | I | P1 | Do producer-built native objects survive packaging with identity and trust intact? |
| FC-COMP-02 | Electron payloads and a single update owner | I | P1 | Can the application avoid concurrent Squirrel/NSIS and Niobium maintenance? |
| FC-COMP-03 | PyInstaller onedir/onefile payloads | I | P1 | Are bootloader extraction, bundled libraries and privilege behavior qualified? |
| FC-COMP-04 | Qt applications independent of Qt IFW | I | P1 | Can native Qt application objects be deployed through Niobium contracts? |
| FC-COMP-05 | Existing NSIS/Inno/MSI installation migration | C | P2 | Can discovery and ownership transfer occur without executing arbitrary old installers? |
| FC-COMP-06 | CMake/CPack and other producer build integration | I | P1 | Can CI consume ordinary Niobium artifacts without runtime coupling? |
| FC-COMP-07 | .NET/Java/Python runtime prerequisites | I | P1 | Are runtimes bundled or externally provisioned under explicit ownership? |
| FC-COMP-08 | Windows native formats and deployment coexistence | C | P2 | Are MSI/MSIX restrictions, ownership and update responsibility documented? |
| FC-COMP-09 | macOS app/DMG/PKG signing workflow coexistence | I | P1 | Does wrapping preserve the tested app signature and notarization result? |
| FC-COMP-10 | Linux package managers, AppImage and desktop coexistence | I | P2 | Is each package lifecycle owned by one manager with explicit interoperability? |

## Explicit exclusions

| ID | Capability | Boundary | Priority | Acceptance question |
|---|---|---|---|---|
| FC-OUT-01 | Manifest shell, PowerShell or generic command fields | X | None | Do schemas and negative tests reject executable product instructions? |
| FC-OUT-02 | Runtime plugins, custom DLLs and product-authored feature modules | X | None | Can unreviewed product code enter the installer or elevated helper? |
| FC-OUT-03 | Preinstall/postinstall script hooks | X | None | Does product business logic remain in the App Bootstrap contract? |
| FC-OUT-04 | Arbitrary nested installer execution and custom elevated actions | X | None | Can downloaded EXE/MSI packages become generic privileged operations? |
| FC-OUT-05 | HTML/CSS/QML/JavaScript product-defined installer layouts | X | None | Does customization stay within the closed renderer and validated data model? |
| FC-OUT-06 | In-place rewriting of active artifacts or unsigned emergency updates | X | None | Can any escape hatch bypass immutable artifacts or release trust? |
| FC-OUT-07 | Installer-owned business databases, language compilation or license servers | X | None | Are application semantics and producer toolchains assigned to their actual owners? |
| FC-OUT-08 | Mandatory runtime cloud scanning or automatic private-payload upload | X | None | Can installation work without turning scanning services into release trust authorities? |

## Evidence and source ownership

Each implemented row needs a linked contract, scenario, platform/scope matrix and retained evidence. Use only PASS, FAIL, BLOCKED, NOT_RUN or DEFERRED for execution results. A scanner outage or stale database is an explicit outcome, never a clean scan. No new product PASS is asserted by this catalog.

Security gates cover source and dependencies, payloads, final signed installers and retained releases. Reports record tool version, advisory snapshot, scope, omissions, findings and artifact digest. Scan immutable final bytes before promotion; remediation creates new artifacts under a new authorized release sequence. Signing, SBOM presence, provenance verification and malware scanning answer different questions.

The governing owners are [manifest](spec/manifest-v1.md), [component](spec/component-v1.md), [artifact](spec/artifact-format-v1.md), [TUF](spec/tuf-profile-v1.md), [CLI](spec/cli-v1.md), [ABI](spec/abi-v1.md), [Bootstrap](spec/bootstrap-v1.md), [platform](spec/platform-contract-v1.md), [IPC](spec/ipc-v1.md), [UI](spec/ui-ir-v1.md), [transactions](architecture/transaction-model.md) and [testing lanes](development/testing-lanes.md). A broad B row does not expand these contracts. Known discovery, cross-user locking, helper and platform restrictions remain applicable.

Feature modules and themes remain proposals in [ADR-0018](adr/0018-built-in-feature-modules.md) and [ADR-0019](adr/0019-presets-and-themes.md). Dependency solving, native exporters, enterprise policy and report formats need their own contracts before implementation. No decision status changes through this catalog.

Upstream references, consulted on 2026-10-07: [NSIS scripting](https://github.com/NSIS-Dev/nsis/blob/master/Docs/src/basic.but), [Inno Setup](https://github.com/jrsoftware/issrc), [WiX](https://github.com/wixtoolset/wix), [Qt IFW](https://github.com/qtproject/installer-framework), [Electron Builder](https://github.com/electron-userland/electron-builder), [PyInstaller](https://github.com/pyinstaller/pyinstaller) and [CPack](https://github.com/Kitware/CMake/tree/master/Modules) identify the technologies considered. Their behavior does not establish Niobium implementation coverage.
Scanning references, consulted on 2026-10-07: [OSV-Scanner](https://github.com/google/osv-scanner) for dependency-advisory matching, [CycloneDX](https://github.com/CycloneDX/specification) for SBOM and exploitability statements, and [SLSA artifact verification](https://github.com/slsa-framework/slsa/blob/main/spec/verifying-artifacts.md) for provenance bound to artifact identity and trusted builders. Integration choices require separate evaluation.
