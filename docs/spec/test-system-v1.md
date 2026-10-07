# Test system v1

Status: normative. Acceptance: N1-AC-20 (tooling), with product evidence retaining its existing IDs.
The report wire contract is [test-report-v1](../../api/schema/test-report-v1.schema.json).
Operational commands belong to [testing-lanes](../development/testing-lanes.md).

## Identity and selection

`build/test_catalog.zig` owns stable suite and case identifiers and acceptance mappings.
Identifiers are never recycled. A changed assertion meaning requires a new contract version.
`test` defaults to `unit,conformance`; `suite` is a comma-separated set, and `case` selects one
registered case in that set. Unknown, duplicate, empty and zero-match selections fail.
Cases currently exist only for conformance and e2e; other suites report aggregate outcomes.
Compatibility steps share execution nodes with `test`. `verify` rejects suite/case narrowing.
`target` controls compilation only: executing a foreign binary cannot establish native support.
Seed count/start, sanitizer and coverage parameters retain their existing meanings.
There are no automatic test retries. Replay uses the recorded revision, toolchain, target,
selection, seeds and fixture digests. Dirty results identify a working tree, not merely HEAD.

| Suite | Lane | Driver and requirements | Scope / acceptance |
|---|---|---|---|
| unit | L1/L2 | Zig tests, VirtualPlatform and isolated fixtures | Existing test IDs; aggregate only |
| conformance | L3 | Native backend, redirected system roots, no system managers | N1-AC-14; user and redirected machine |
| e2e | L4 | Real setup/nbpack/sample app, loopback HTTP and signed fixtures | N1-UJ-01, N1-UJ-03, N1-UJ-04, N1-UJ-05, N1-UJ-06, N1-UJ-07, N1-INV-05, N1-INV-06 |
| sim | L2 | VirtualPlatform, bounded replay seeds | N1-AC-07; aggregate only |
| golden | L4 | Software renderer, checked-in scoped goldens | Existing UI IDs; aggregate only |
| fuzz | L2 | Bounded corpus replay; continuous fuzz remains explicit | Existing security IDs; aggregate only |
| c-smoke | L4 | Native C client linked to distribution library | N1-AC-10; aggregate only |

## Isolation, probes and failure

Each lifecycle case owns a temporary home, managed root, repository and app-owned data directory.
Windows CLI lifecycle runs require a disposable OS account (as on the hosted runner): environment
variables redirect files, but cannot redirect HKCU. The sample product's native registration is
exercised in that account. Redirected host conformance leaves system managers disabled.
System location redirection is not evidence of native elevation or service-manager behavior.
CLI JSON assertions and independent filesystem assertions are separate. Probes inspect the active
generation, installation metadata and payload hashes, and launch a fresh sample app that reports
its release marker. A sentinel outside the managed root must survive every transition and uninstall.
Cover install, update, incident rollback, no-op, repair, uninstall, offline install and tamper rejection.
Regression probes must reject wrong generations, corrupt bytes and lost user data even if CLI output
claims success. Published fixture/artifact hashes identify the actual bytes used.

Conformance preserves each completed contract result before continuing. Required unsupported
capabilities fail; explicitly optional unsupported capabilities are NOT_RUN with a reason.
Unreached cases remain NOT_RUN; a crash or infrastructure problem cannot turn them into PASS.
The runner writes an initial report before spawning, persists case records incrementally, captures
stdout and stderr separately and finalizes after exit. Evidence-write failures fail the execution.
Limits are owned by `contracts.Limits`: report bytes, attachment count/bytes, output bytes and
subprocess deadline. Deadline and output-limit failures preserve available output. No shell is
constructed from report data. Test subprocesses are terminated on deadline; CI job deadlines remain
the outer boundary for compiler failures or orphan descendants.

## Report and archive

Verdicts are PASS, FAIL, BLOCKED, NOT_RUN and DEFERRED. Each non-PASS has a reason.
Reports include suite/case/contract identity, acceptance IDs, lane, driver, scope, actual OS/CPU,
environment description, source revision and dirty state, CI repository/run/attempt/job and fork
provenance, toolchain, timings, replay parameters and fixture/artifact hashes. Artifact references
include relative filename, immutable object key, SHA-256, byte size and retention class.
Each execution uses a UTC Unix-millisecond prefix and random suffix. The five `parameters` entries
are case filter (empty for all), `seeds=N`, `seed-start=S`, `tsan=BOOL`, `coverage=BOOL`.
Conformance contract names are the catalog's nine platform probes; lifecycle cases use `lifecycle-v1`.
Publisher-added `provenance` is null locally and records GitHub source head/fork and the attempt's
`run_started_ms`. The publisher derives the archive month from GitHub's `run_started_at`; local
publication uses the report's start time. Both use UTC. Retrying next month retains the source keys.
Source run/job/artifact API snapshots and `evidence-status.json` live under
`ci-evidence/YYYY-MM/reports/v1/<repository>/<run>/<attempt>/github/<snapshot-sha256>/`;
a job without an artifact records
`no-saved-evidence`. Artifact presence alone remains unvalidated and cannot imply a PASS.
Snapshots are content-addressed because later attempts and artifact expiry can change GitHub data.
`publisher.json` records the trusted publisher revision separately: a code redeployment cannot
change the same source report during publication recovery.
Initial and partial reports are explicitly incomplete. A publisher cannot infer absent evidence.
Historical results answer what ran at that revision/environment; they never satisfy a current run.

Use a private R2 Standard bucket, configured independently from report data:

| Prefix | Contents | Retention |
|---|---|---|
| `ci-evidence/YYYY-MM/reports/v1/` | Compact reports | No expiry |
| `ci-evidence/YYYY-MM/evidence/v1/` | Ordinary logs and bundles | 90 days |
| `ci-evidence/YYYY-MM/release-evidence/v1/` | Explicit release evidence | No expiry |

Keys append repository, run, attempt, job, suite and execution identity. Old saved runs with the
pre-prefix keys remain valid offline and are rekeyed on explicit publication; no writes occur
outside `ci-evidence/`. Timestamp conversion is bounded to 1970–9999. Each segment is validated;
filenames cannot contain separators, traversal or links. Upload evidence first, report last. At most
`contracts.Limits.test_archive_workers` attachment transfers are in flight; each owns its scratch
files. A transfer failure prevents report publication, and completed objects can be reused.
AWS CLI standard transport retries have at most three attempts within the subprocess deadline;
they do not rerun tests or alter their verdicts.
Create objects with `If-None-Match: *`. On an existing object, read and compare length and SHA-256:
identical content is success; conflicting content fails without replacement. Readback also checks
that ordinary objects have an expiry and permanent objects do not; missing monthly retention
configuration fails publication without changing the test verdict. An interrupted upload
leaves at most unreferenced attachments; replaying saved publication is safe. Readers paginate
ListObjectsV2 and fetch reports/objects directly. There is no mutable latest index or server.

Ordinary local tests never contact the archive. `test -Dsuite=unit -Dr2-live=true` explicitly checks
the configured service, requires pinned transport and credentials, and records its flag in the
environment description. Its isolated protocol fixtures are NOT_RUN, not conformance evidence. Explicit publication uses the pinned AWS CLI as
transport ([ADR-0021](../adr/0021-ci-evidence-transport.md)); credentials, endpoint and bucket are
deployment inputs and never report fields. Bucket-scoped credentials permit object read/write only.
Lifecycle configuration uses a separate administrator identity. Since lifecycle matching is
prefix-based, each configured month has its own 90-day ordinary-evidence rule. Provision months
ahead and renew the reviewed configuration before its horizon; preserve other bucket rules.
Verify configuration and real
upload/readback, digests, duplicate/conflicting creates, interruption and pagination before declaring
R2 supported. [R2 S3 API](https://developers.cloudflare.com/r2/api/s3/api/) and
[lifecycle rules](https://developers.cloudflare.com/r2/buckets/object-lifecycles/) define transport.

## CI trust boundary and platform obligations

Test jobs have no R2 credentials. A separate workflow triggered on completed test workflows builds
the publisher from trusted default-branch code pinned to the event SHA, without PR caches. Downloaded artifacts are bounded
data: never execute them, import their configuration, use their paths as shell text or trust their
provenance assertions. GitHub supplies run/attempt/repository/head/fork/job identity. Preserve both
the tested checkout revision and GitHub head revision (a PR merge checkout may differ).
Publisher inputs have global workflow budgets in `contracts.Limits`: 256 MiB compressed ZIP
bytes, 1 GiB unpacked data, and 16,384 entries. Metadata downloads are capped before parsing;
each extracted tree is removed immediately after its reports are published.
Archive failed and PR runs too. Keep GitHub artifacts for recovery; publication failure fails its
own job and does not rewrite the test verdict. Missing artifacts are recorded as missing evidence.
The `CI / linux` aggregate requires every selected job to succeed; failure, cancellation and
unexpected skip fail it. Docs-only runs still execute static checks.

[ADR-0014](../adr/0014-tier-based-platform-support.md) owns tier obligations and
[Platform support](../../apps/user-docs/src/content/docs/platforms.md) owns assignments. L0 is static,
L1/L2 are model/security evidence, L3 is platform contract, L4 is scenario evidence and L5 is the
reference OS with real desktop/elevation. Hosted L3/L4 does not close missing L5 evidence.
Tier 2 stays best effort; Tier 3 has no automatic execution obligation. VM execution is explicit.
Containers, GUI automation, visual services, VM orchestration and the results viewer are deferred.
Construction states and exit criteria live in the [maintainer roadmap](../roadmap-v0.2.md).
