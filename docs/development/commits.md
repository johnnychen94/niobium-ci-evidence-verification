# Commit conventions

Format: `<type>(<scope>): <summary>`, with an English summary of ≤ 72 characters that does not end with a period.

- `type`: `feat`, `fix`, `test`, `docs`, `refactor`, `chore`, `adr`, `build`.
- `scope`: a module name (`trust`, `transaction`, `ui-kit`…) or `repo`.
- The body explains the reason, contract changes, and verification commands and results; when the change exceeds 300 net lines, explain why.

Example: `feat(trust): implement root rotation`.

`zig build check-commits -Drange=origin/main..HEAD` validates the format.
