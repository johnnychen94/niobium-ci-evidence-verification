# ADR-0005: tar.zst component payload format

- **Status:** Accepted
- **Date:** 2026-10-07

## Context

Source architecture v0.1 suggests zip and v0.2 suggests tar.zst. Zig std provides zstd decompression and tar iteration, but no zstd compression.

## Decision

- A multi-file component payload is `artifact-format-v1`: a zstd-compressed ustar/pax tar.
- The runtime uses `std.compress.zstd.Decompress` and the framework's own strict tar walker. Only regular files and directories are allowed; paths must be normalized and relative, with no `..`, no absolute paths and no drive letters. Symlinks, hardlinks, devices and FIFOs are always rejected.
- File permissions and the executable bit are described by component metadata; the archive defines no machine semantics.
- Only the packager links libzstd ([ADR-0011](0011-third-party-fetch.md)), for compression; the runtime contains no C compressor.
- Extraction has limits on the total expanded size and the compression ratio; exceeding either is a rejection (archive-bomb defense).

## Consequences

- No artifact can write outside the staging root. This is a hard invariant covered by malicious fixtures.
