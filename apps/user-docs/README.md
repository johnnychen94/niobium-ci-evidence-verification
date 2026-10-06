# User documentation site

The public documentation for people who build installers with Niobium, published at https://niobium-project.dev in English and Simplified Chinese. It is an Astro Starlight site and the only part of the repository that uses Node.js ([ADR-0015](../../docs/adr/0015-node-toolchain-for-user-docs.md)). Maintainer documentation stays in [docs/](../../docs/README.md).

## Build

```sh
cd apps/user-docs
npm ci
npm run dev              # local preview with reload
npm run build            # static site in dist/, fails on broken internal links
npm run build:versions   # every published version in dist-versions/, as deployed
```

The Node.js major version is in `.nvmrc`. Dependencies are pinned to exact versions; upgrade them deliberately and commit `package-lock.json`. The site is built and deployed by [.github/workflows/user-docs.yml](../../.github/workflows/user-docs.yml): pull requests build `/next/` only, and pushes to `main`, pushes of `v*` tags and manual runs assemble and deploy all versions.

## Versions

| Path | Built from |
|---|---|
| `/next/` | `main` (locally: the working tree; `--next-ref <ref>` picks another ref) |
| `/vX.Y/` | The highest tag `vX.Y.Z` of each minor line whose tree contains `apps/user-docs/package.json` |
| `/latest/` | The newest release line, built a second time |
| `/` | `versions.json`, `CNAME`, `llms*.txt` and redirects to `/latest/`, or `/next/` before the first release; `/zh/` likewise |

- Release tags match `vX.Y.Z` exactly, without pre-release or build suffixes; other tags are ignored. At most the 12 newest release lines are built; older ones are logged as not published.
- Each tag is built in a temporary `git worktree` with its own lockfile and config, so the build needs the full history and tags (`fetch-depth: 0`). A tag that fails to build fails the whole deploy.
- One build is controlled by two variables, which `build:versions` sets: `DOCS_VERSION` (`next`, `latest` or `vX.Y`; default `next`) and `DOCS_BASE` (`/` or `/<name>/`; default `/`).
- The version switcher in the header reads `/versions.json` at run time and keeps the page path and locale when switching, falling back to that version's home page. `next` and older release lines show a banner.
- Each version has `llms.txt`, `llms-full.txt` and `llms-small.txt`, generated from the English pages only.

## Writing pages

- Pages are Markdown in `src/content/docs/`; the sidebar is in `astro.config.mjs`, with its labels in `src/content/i18n/`. Keep each page one kind: tutorial, how-to guide, concept or reference.
- Link to other pages by root-relative route with a trailing slash: `/guides/package/`, `/reference/exit-codes/#codes`. Do not add the version base; the build adds it.
- Link to repository files by `https://github.com/niobium-project/niobium/blob/main/<path>`, or `tree/main/<path>` for a directory. `zig build check-docs` fails if the path does not exist.
- The specifications in `docs/spec/` are the source of truth. Summarize and link to them instead of copying them.
- Status claims use only `PASS`, `FAIL`, `BLOCKED`, `NOT_RUN` and `DEFERRED`, and come from the [acceptance plan](../../docs/acceptance-plan-v0.1.md).

## Chinese pages

The Chinese site is a translation of the English one ([ADR-0017](../../docs/adr/0017-chinese-user-documentation.md)).

- Every page in `src/content/docs/` has a translation at the same path under `src/content/docs/zh/`; adding, moving or removing a page changes both, or `zig build check-docs` fails.
- Chinese pages link to `/zh/...` routes only.
- A Chinese heading that other pages link to keeps the English ID: `## 事件错误码 { #event-error-codes }`.
- Code, commands, identifiers, paths, JSON fields, error names and status words stay in English.
- A translation never claims more than the English page. When they disagree, the English page is right.

Terms:

| English | Chinese |
|---|---|
| manifest | 清单 |
| artifact | 制品 |
| component | 组件 |
| transaction | 事务 |
| commit | 提交 |
| recovery | 恢复 |
| release | 发布, 发布版本 |
| release sequence | 发布序号 |
| repository | 仓库 |
| channel | 通道 |
| promote | 晋升 |
| desired state | 期望状态 |
| elevated helper | 提权助手 |
| privilege boundary | 权限边界 |
| capability | 能力 |
| staging | 暂存 |
| install root | 安装根目录 |
| active version | 活动版本 |
| scope (user, machine) | 作用域 (用户范围, 整机范围) |
| integration | 系统集成 |
| shortcut | 快捷方式 |
| file association | 文件关联 |
| entrypoint | 入口点 |
| maintainer | 维护程序 |
| offline bundle | 离线包 |
| signing key | 签名密钥 |
| metadata | 元数据 |
| trust root | 信任根 |
| exit code | 退出码 |
| event | 事件 |
| runbook | 运行手册 |
| tier | 层级 |
| Portable Run | 便携运行 |
| App Bootstrap | App Bootstrap (应用引导), kept in English |
