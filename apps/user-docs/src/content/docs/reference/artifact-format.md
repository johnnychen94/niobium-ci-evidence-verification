---
title: Artifact format
description: Layout, unpacking rules and limits of component artifacts (tar.zst).
---

Canonical source: [artifact-format-v1](https://github.com/niobium-project/niobium/blob/main/docs/spec/artifact-format-v1.md).

## Layout

A component artifact is a sequence of zstd frames that decompresses to a ustar tar archive (pax `path` headers allowed).

| Rule | Value |
|---|---|
| First entry | the regular file `component.json` |
| All other entries | `files` or paths under `files/` |
| Entry order | `component.json`, then entries under `files/` sorted by path bytes |
| Timestamps, owners | mtime 0, uid and gid 0 |
| Integrity | SHA-256 of the whole file equals the digest in the manifest and the signed targets; checked before unpacking |

`files/X` is installed as `current/<component>/X`. `nbpack component build` produces this layout; you do not build archives by hand.

## Accepted entries

| Entry type | Handling |
|---|---|
| Regular file, directory | Allowed |
| pax extended header | Only the `path` and `size` keys are used |
| Symbolic link, hard link, character or block device, FIFO, GNU extensions, global pax header | Rejected: `ForbiddenEntryType` |

## Path rules

Paths are UTF-8, separated by `/`, at most 1024 bytes and 64 segments. Rejected with `UnsafePath`: a leading `/`, a drive letter, a backslash, NUL, `:`, `.` or `..` segments, repeated `/`, control characters, any of `<>"|?*`, a segment ending in `.` or a space, and Windows reserved names (`CON`, `PRN`, `AUX`, `NUL`, `COM0` to `COM9`, `LPT0` to `LPT9`, with any extension). A path that appears twice, compared without ASCII case, is rejected with `DuplicateEntry`, as is a collision the file system reports while creating files.

## Limits

| Limit | Value | Error |
|---|---|---|
| Entries | 65 536 | `ArchiveTooManyEntries` |
| Single file | 2 GiB | `ArchiveEntryTooLarge` |
| Total unpacked size | 8 GiB | `ArchiveBomb` |
| Unpacked size divided by compressed size | 200, applied above 1 MiB | `ArchiveBomb` |
| `component.json` | 1 MiB | |

Each entry's declared size is charged before anything is written. Bytes after the end-of-archive blocks must be zero, otherwise `ArchiveCorrupt`. All these errors exit with code 3.
