# ADR-0020: Distribution delivery milestones

- **Status:** Accepted
- **Date:** 2026-10-07

## Context

Product teams need an online installer, a complete offline file, and a self-extracting offline installer (SFX).
The current [offline bundle](../runbooks/offline-bundle.md) is a directory, and the user roadmap excludes SFX.
The original [architecture input](../source/architecture-v0.2.md) rejects generic SFX and executable packers because of signing, scanning and runtime risks.

## Decision

- All three delivery forms are milestones in [roadmap-v0.2](../roadmap-v0.2.md).
  An online installer obtains its payload from a repository; a complete offline file contains every required payload and is opened or unpacked before installation.
  An SFX contains every required payload and starts the Niobium installer without a separate unpacking step.
- This decision changes the planned scope of installer delivery, including the SFX exclusion above.
  It does not approve a container layout, a platform matrix or an implementation.
  Those decisions require the work in the [distribution backlog](../development/distribution-backlog.md).
- Every form uses the same manifest, TUF authorization, strict component extraction and transactional engine.
  SFX remains a closed installer profile; it adds no shell scripts, arbitrary execution hooks, runtime plugins or encrypted executable payloads.
  Portable Run retains its existing artifact model.
- [ADR-0005](0005-tar-zst-artifact-format.md), [ADR-0006](0006-transaction-and-pointer-swap-commit.md) and [ADR-0007](0007-same-binary-privilege-helper.md) continue to govern payloads, transactions and privilege.
  Any incompatible implementation needs a separate ADR before code changes.

## Consequences

- The user roadmap and both READMEs list delivery formats as planned work.
  Current directory bundles and historical v0.1 acceptance results remain unchanged.
- Upstream failure reports become tracked design and test cases rather than claims that Niobium reproduces them.
  Each milestone needs real-OS evidence for its declared targets and scopes using the final signed bytes.
- Container limits, signing order, scan policy, offline validity and maintainer lifetime must be settled before delivery.
  A completed scan cannot promise that future antivirus definitions will never flag a release.
