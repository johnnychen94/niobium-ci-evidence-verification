# Copilot instructions

Follow [AGENTS.md](../AGENTS.md). It is the source of truth for this repository.

- The manifest is data. Do not add a shell, PowerShell, script, `exec`, or generic command field.
- Describe desired state. Installation stays transactional: after a crash, recovery reaches only the old version or the new one.
- Privilege is a closed set of typed operations. There are no runtime plugins, script hooks, or custom DLL hooks.
- Zig 0.17.0. Public functions use explicit error sets. Function bodies stay within 70 lines and lines within 100 columns.
- Do not add `shared/`, `common/`, `utils/`, or `helpers/` directories.
