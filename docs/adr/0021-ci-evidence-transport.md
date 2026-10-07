# ADR-0021: CI evidence transport

- **Status:** Accepted
- **Date:** 2026-10-07
- **Amends:** [ADR-0001](0001-repository-baseline-and-zig-only-toolchain.md), allowed non-language tools

## Context

Conformance history must outlive GitHub artifact retention. Implementing S3 authentication in Zig
would create unnecessary security-sensitive code. The approved test-system plan permits AWS CLI
only as a pinned CI transport to Cloudflare R2.

## Decision

Add pinned AWS CLI to ADR-0001's allowed non-language tools solely for CI evidence transport and
its deployment verification. Test logic, report validation, archive key construction, conditional
publication decisions and build entrypoints remain Zig. The CLI receives explicit argv, never
shell text from a report. Local tests need neither AWS CLI nor credentials.

A separate trusted publisher consumes untrusted test artifacts as bounded data. R2 credentials
are bucket-scoped deployment inputs available only to publication. Reports are published last
and immutable; a repeated create succeeds only for identical content. The versioned protocol is
[test-system-v1](../spec/test-system-v1.md).

## Consequences

AWS CLI is not a product dependency and cannot be used as a general repository scripting runtime.
Its version and installation integrity must be pinned in CI. Publication can be retried from saved
GitHub artifacts without repeating tests. Real R2 deployment checks remain necessary before the
archive integration receives a supported construction status.
