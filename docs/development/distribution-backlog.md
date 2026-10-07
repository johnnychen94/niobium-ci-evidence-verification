# Distribution delivery backlog

The milestones in [ADR-0020](../adr/0020-distribution-delivery-milestones.md) require the design decisions and tests below before release.
This backlog owns the work items; the [user roadmap](../../apps/user-docs/src/content/docs/roadmap.md) owns feature names and priority.
All tasks are `NOT_RUN`. These are planning IDs, not acceptance IDs or evidence of implemented features.

## Milestone outcomes

| Milestone | Delivery outcome | Completion evidence |
|---|---|---|
| Online installer | One native installer obtains authorized components from a repository | Final signed installer tested with HTTP failures, interrupted downloads, cached payloads and real-OS protection enabled |
| Complete offline file | One downloadable file contains the installer and every required payload; opening or unpacking it precedes installation | Installation with networking disabled, preserved payload signatures, documented validity period and tested outer-container handling |
| SFX | One self-extracting offline installer starts installation without a separate unpacking step | Declared platform/container matrix, bounded reads, tamper rejection, final signature checks and crash recovery throughout extraction and installation |

The implementation ADR must declare targets and scopes for each form.
Do not infer that Windows EXE resources, a macOS DMG, an app bundle and a Linux executable have identical delivery semantics.
Online and directory-bundle coverage in [v0.1 acceptance](../acceptance-plan-v0.1.md) does not close these release milestones.

## Upstream evidence

These primary sources were reviewed on 2026-10-07.
They describe historical defects or documented mechanisms, not a measured SFX failure rate or a reproduction on every current version.

| Source | Reported mechanism | Tasks |
|---|---|---|
| [NSIS false positives](https://nsis.sourceforge.io/NSIS_False_Positives) | Antivirus signatures sometimes match a shared installer stub rather than its payload | DIST-02 |
| [NSIS uninstaller signing](https://nsis.sourceforge.io/Docs/Chapter5.html#uninstfinalize), [CPack signing discussion](https://discourse.cmake.org/t/is-there-a-best-practices-correct-way-of-code-signing-the-installer-via-cpack/5043) | Generated executable objects need their own signing steps | DIST-01, DIST-09 |
| [NSIS #1284](https://sourceforge.net/p/nsis/bugs/1284/), [#1306](https://sourceforge.net/p/nsis/bugs/1306/) | Integer representation, mmap ranges and size calculations fail around large-file boundaries | DIST-03, DIST-04 |
| [NSIS #240](https://sourceforge.net/p/nsis/bugs/240/) | Solid compression can require a large intermediate temporary file | DIST-04 |
| [CPack STGZ permissions](https://discourse.cmake.org/t/cpack-archive-changing-destination-directory-permissions/9919), [CMake #11958](https://cmake.org/Bug/view.php?id=11958) | Extraction tools apply directory modes or disagree about extended archive metadata | DIST-07 |
| [NSIS #1315](https://sourceforge.net/p/nsis/bugs/1315/) | Restricted-directory creation failures were not fully reported; the ticket records a fix in 2025 | DIST-05, DIST-11 |
| [VirusTotal private scanning](https://docs.virustotal.com/docs/private-scanning), [analysis results](https://docs.virustotal.com/reference/analyses-object) | Private analysis omits partner antivirus verdicts; failed or unsupported scans differ from an undetected result | DIST-02 |

## Design and verification tasks

### DIST-01: Final signing and immutable release bytes

- [ ] Release owner: specify payload signing, macOS notarization and stapling, packaging, TUF hashing, outer-installer signing, scanning and promotion order for each form.
- [ ] Resolve the order in [release-signing](../runbooks/release-signing.md): signing `setup` precedes the later branded build, which has no explicit final signing step.
- [ ] Test a signed outer package containing an unsigned executable, payload mutation, wrong publisher, altered branding and missing offline notarization tickets.
- [ ] Verify all executable identities, including maintainer and helper. Final candidate hashes must match scanned and published bytes; promotion must not rebuild them.

### DIST-02: Antivirus, reputation and CI scan policy

- [ ] Release owner: choose licensed scanning providers, required engines, report freshness, sample-sharing policy and bounded upload/poll/retry behavior.
- [ ] Scan the actual branded installer, outer offline file and each executable payload. Unknown container support must not hide unscanned contents.
- [ ] Run install, update, repair and uninstall in clean Windows VMs with current Defender definitions and real-time protection enabled; record exclusions and cloud-protection settings.
- [ ] Test partial reports, quota exhaustion, timeout, unsupported types, new detections and stale hash lookups. Inspect Defender detections as well as exit codes, including successful remediation.
- [ ] Keep signature verification, malware detection, publisher identity and SmartScreen reputation separate. Retain reports and vendor false-positive case IDs for each hash; a low detection count is not approval.

### DIST-03: Container parsing and authenticity

- [ ] Repository/package owners: specify a versioned outer layout, signature coverage, payload lookup and bounds in `contracts.Limits`; retain [artifact-format-v1](../spec/artifact-format-v1.md) for components.
- [ ] Test truncated headers, indexes and payloads; overlapping entries; duplicate names; offset-plus-length overflow; unknown versions; extra bytes; and tampering before and after platform signing.
- [ ] Fuzz the reader and inject allocation failures. Check lengths and TUF digests before extraction through `package.extract`; reject inputs without writes outside staging.
- [ ] Measure bounded streaming reads and memory use on large containers. Define random-access requirements and how signed-file metadata affects payload location.

### DIST-04: Large files and peak resource budgets

- [ ] Packager/engine owners: budget build-time RAM and temporary files, runtime memory, cache, staging, old/new releases and maintainer size on each affected volume.
- [ ] Test sizes around 2 GiB and 4 GiB, maximum counts, incompressible data, compression limits, fragmented free space and disk-full at every write phase.
- [ ] Define a typed rejection above each limit; no overflow, panic or truncated successful output. Select compression granularity using measured space and latency.
- [ ] Keep the runtime size gate separate from total delivery size without relaxing existing gates to hide growth. Publish measured peak resources and cleanup results.

### DIST-05: Extraction ownership and privilege

- [ ] Platform/privilege owners: define private staging ownership, permissions, exclusive creation, handle lifetime and cleanup before introducing an outer unpacking step.
- [ ] Test pre-created directories, wrong ACLs, denied ACL changes, links/reparse points, source replacement and helper loss. A failed security precondition must stop the operation.
- [ ] Keep the UI unelevated and helper operations within [ipc-v1](../spec/ipc-v1.md). Do not execute a randomly named temporary stub or a product-supplied script.
- [ ] Verify source identity across checking and use, and cleanup only directories owned by the transaction.

### DIST-06: Antivirus interference and recovery

- [ ] Transaction/engine owners: specify file-lock, quarantine and missing-file outcomes before staging, at commit, after commit and during recovery.
- [ ] Add kill/fault cases around outer extraction, staging, pointer swap and maintainer activation. Check OLD-or-NEW recovery under the documented crash model.
- [ ] Separately test real-OS quarantine of payload, helper and maintainer; external deletion after commit needs a diagnosable state rather than an unsupported crash guarantee.
- [ ] Verify cancellation, reboot and rerun behavior. Repair must report repeated quarantine without disabling protection or entering an unbounded retry loop.

### DIST-07: Paths, permissions and platform containers

- [ ] Package/platform owners: specify outer-container extraction separately from machine deployment; keep archive metadata from changing unrelated directory permissions.
- [ ] Test spaces, non-ASCII paths, case collisions, long paths, existing directories, read-only media, executable bits, unsupported extended attributes and unexpected entry types.
- [ ] Select macOS app/DMG layout and supported signed payload structure; reconcile any app/framework symlinks with the strict no-link component contract through an ADR.
- [ ] Verify signatures and behavior after unpacking or mounting on the target OS. Do not substitute the host's tar or shell for the component extractor.

### DIST-08: Offline validity and source selection

- [ ] Trust/repository owners: specify offline validity and treatment of expired metadata, clock skew, root rotation and old-media repair under [tuf-profile-v1](../spec/tuf-profile-v1.md).
- [ ] Test fresh installation and repair with networking disabled before, at and after expiry; also test a newer installed release with older media.
- [ ] Define precedence for embedded, sibling, explicit and online repositories. A damaged local source must not silently downgrade trust or enable an unexpected network fallback.
- [ ] Document refreshed media and verified recovery. Any change to expiry enforcement requires an ADR and matching spec/schema/tests.

### DIST-09: Maintainer lifetime and delivery size

- [ ] Planner/executor owners: choose a full SFX maintainer or a separately signed small runtime; account for [the current setup copy](../../libs/executor/root.zig) in space budgets.
- [ ] Test maintenance after deleting or moving the original download, from read-only media, with networking disabled and after a product update.
- [ ] Verify maintainer/helper identity and recovery during replacement. Removing embedded bytes from a signed executable must not be the default maintenance strategy.
- [ ] Record installed size and retained payloads; define cache retention, garbage collection and uninstall cleanup.

### DIST-10: Online transport and source equivalence

- [ ] Repository/engine owners: test interrupted downloads, partial cache entries, wrong length/hash, HTTP errors, redirects and stale metadata against the same final release used offline.
- [ ] Compare selected components, plans and installation state across the three forms for the same manifest, platform, scope and user choices.
- [ ] Confirm offline forms contain every required target for the declared platform. Optional-component selection and unsupported-platform errors must remain explicit.

### DIST-11: Installer security updates and SDK delivery

- [ ] Runtime/release owners: define response to installer, extractor or helper vulnerabilities, including old downloads, installed maintainers and minimum runtime versions.
- [ ] Test an application release that changes no application payload but replaces a vulnerable runtime; metadata-only promotion cannot patch an existing executable.
- [ ] Specify build SDK/`nbpack` entry points for all forms, production key ownership and later-release publication; preserve no-script manifest semantics.
- [ ] Build independent product fixtures through the public API and test runtime upgrade failure, rollback and repair on each declared target.

## Completion and evidence

Before implementation, link each task to its owning ADR/spec and allocate acceptance IDs using [documentation management](docs-management.md#roadmap-and-acceptance-plan).
Use L0 checks, L1 semantic tests, L2 fuzz/allocation/crash cases, L4 scenarios and L5 real-OS tests from [testing lanes](testing-lanes.md).
Update the recovery table whenever extraction or maintenance introduces durable state.

Retain final hashes, commands, exit codes, OS/protection versions, scan reports, signature checks and recovery logs in `.evidence/distribution/<UTC>/`.
Use only `PASS`, `FAIL`, `BLOCKED`, `NOT_RUN` or `DEFERRED`, and name missing engines, targets or scopes.
Close tasks only with linked evidence; static scanning and successful compilation do not replace L5 validation.
