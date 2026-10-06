# Artifact format v1 (tar.zst)

- **Status:** Baseline
- **Decision:** [ADR-0005](../adr/0005-tar-zst-artifact-format.md)

## Structure

A sequence of zstd frames that decompresses to a ustar tar (pax `path` extended headers are allowed). Entry order: `component.json`, then the directories and files under `files/`, sorted by path bytes; mtime is fixed at 0 and uid/gid are 0, for reproducibility.

## Runtime unpacking rules (strict walker)

| Entry | Handling |
|---|---|
| regular file (`0`, `\0`) | Allowed |
| directory (`5`) | Allowed |
| pax extended header (`x`) | Only the `path` and `size` keys are accepted; other keys are ignored |
| symlink, hardlink, char/block device, FIFO, GNU extensions, global pax header | `error.ForbiddenEntryType` |

Path rules: UTF-8, non-empty, ≤ 1024 bytes, ≤ 64 segments, separated by `/`; must not start with `/`, and must not contain a drive letter (`C:`), backslash, NUL, `:`, `.` or `..` segments, or repeated `/`. For portability across the three platforms, a segment also must not contain control characters or `<>"|?*`, must not end with `.` or a space, and must not be a Windows reserved name (`CON`, `PRN`, `AUX`, `NUL`, `COM0-9`, `LPT0-9`, with any extension). Violations return `error.UnsafePath`. Directory entries may have one trailing `/`.

A path that appears more than once returns `error.DuplicateEntry`; the comparison uses ASCII case folding. In addition, files are created exclusively, so collisions on the file system caused by case or Unicode normalization, and files and directories overwriting each other, also return `error.DuplicateEntry`.

Entry layout: the first entry must be the regular file `component.json` (≤ `manifest_bytes`), and all other entries must be `files` or located under `files/`; otherwise `error.ArchiveLayout` is returned.

Limits (`contracts.Limits`):

| Limit | Value | Error |
|---|---|---|
| Entry count | ≤ 65 536 | `error.ArchiveTooManyEntries` |
| Single file | ≤ 2 GiB | `error.ArchiveEntryTooLarge` |
| Total expanded size | ≤ 8 GiB | `error.ArchiveBomb` |
| Expanded size / compressed size | ≤ 200, applied above a 1 MiB floor (tar padding in small artifacts compresses extremely well) | `error.ArchiveBomb` |

An entry's declared size is charged to the budget before anything is written, so an entry with an oversized declaration produces no writes at all; actual decompressed bytes are also charged to the budget block by block. After the end-of-archive blocks only all-zero padding is allowed; any other bytes return `error.ArchiveCorrupt`.

The unpacking target is the staging directory; the walker writes only through `Dir.createFile` (`exclusive`, `resolve_beneath`) and `Dir.createDirPath`, using relative paths under the staging handle, and never concatenates absolute paths. `files/X` is written to `staging/X`, which after commit is `current/<component>/X`. `component.json` is returned only as in-memory bytes; the caller validates it with `manifest.parseComponent` and then calls `package.markExecutables` to set the executable bit according to `executables`. The walker also returns the size and SHA-256 of every file, for repair verification.

Malicious fixtures are constructed byte by byte by `libs/package/fixture.zig`: ustar headers plus zstd frames made of raw / RLE blocks, with no dependency on libzstd.

## Integrity

The SHA-256 of the artifact bytes must equal the value declared in TUF targets and in the manifest; verification completes before unpacking.
