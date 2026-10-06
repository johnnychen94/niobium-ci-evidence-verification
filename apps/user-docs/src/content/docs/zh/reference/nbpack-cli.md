---
title: nbpack 命令行
description: 发布工具 nbpack 的命令和选项。
---

权威来源：[`apps/nbpack/cli.zig`](https://github.com/niobium-project/niobium/blob/main/apps/nbpack/cli.zig) 中的解析器和用法文本；操作流程见[发布签名运行手册](https://github.com/niobium-project/niobium/blob/main/docs/runbooks/release-signing.md)。`nbpack` 由 Niobium 检出目录中的 `zig build` 构建，或由你的 `build.zig` 中的 `niobium.nbpack(b)` 构建。

除 `--artifact` 外，每个选项只接受一个值，且不能重复。未知的命令或选项、缺少的值和缺少的必需选项都以退出码 2 退出。其他失败会打印 `nbpack: <ErrorName>`，并以对应的[退出码](/zh/reference/exit-codes/)退出，例如 `PackSequenceNotIncreasing` 为 3。

## 命令

| 命令 | 必需 | 可选 | 作用 |
|---|---|---|---|
| `keygen` | `--out <dir>` | | 为五个角色各写出一个密钥文件 |
| `component build` | `--source <component.json>` `--files <dir>` `--version <x.y.z>` `--out <file>` | `--platform <os-arch>`（默认：主机平台） | 构建并验证一个组件制品 |
| `component validate <artifact>` | | `--platform <os-arch>` | 验证一个制品；打印其 id、版本和平台 |
| `product compose` | `--product <product.json>` `--artifact <file>`... `--out <file>` | `--version` `--sequence` | 写出发布清单，不签名 |
| `publish` | `--repo <dir>` `--keys <dir>` `--product <product.json>` `--artifact <file>`... | `--channel`（默认 `stable`）`--version` `--sequence` `--init` 以及时钟选项 | 向仓库添加一次发布并签名 |
| `promote` | `--repo` `--keys` `--product-id <id>` `--sequence <n>` `--channel <c>` | 时钟选项 | 让一个通道指向已有的发布并重新签名 |
| `sign` | `--repo` `--keys` | 时钟选项 | 重新签名元数据以延长有效期 |
| `config` | `--repo` `--product <product.json>` `--out <file>` | `--branding <file>` `--logo <png>` `--repository <url\|dir>` `--channel`（默认 `stable`） | 为带品牌的 `setup` 写出产品配置，并嵌入仓库最新的 root |
| `bundle` | `--repo` `--setup <exe>` `--out <dir>` | | 把 `setup` 和仓库复制到一个空目录，跳过 `*.tmp` 文件 |
| `help`、`--help` | | | 打印用法 |

`product compose` 和 `publish` 上的 `--version` 和 `--sequence` 覆盖 `product.json` 中的 `product.version` 和 `product.release_sequence`。

## 时钟选项

`publish`、`promote` 和 `sign` 接受：

| 选项 | 默认值 | 含义 |
|---|---|---|
| `--now <unix seconds>` | 当前时间 | 签名时间 |
| `--days <n>` | 30 | snapshot、targets 和通道元数据的有效期 |
| `--timestamp-days <n>` | 1 | timestamp 的有效期 |

## 你可能遇到的错误

| 错误 | 退出码 | 含义 |
|---|---|---|
| `PackSequenceNotIncreasing` | 3 | 发布序号不大于通道当前的序号 |
| `PackRepoEmpty` | 3 | 在没有仓库的目录上运行不带 `--init` 的 `publish`、`promote` 或 `sign` |
| `PackRepoNotEmpty` | 3 | 在已有仓库上运行 `publish --init` |
| `PackRootKeyMismatch` | 3 | 密钥目录中的 root 密钥不是仓库的 root 密钥 |
| `PackTemplateHasArtifacts` | 3 | `product.json` 中已经列出了制品；请保持为 `{}` |
| `PackMissingArtifact` | 3 | 清单中的某个组件没有对应的 `--artifact` |
| `PackDuplicateArtifact` | 3 | 同一组件和平台有两个制品 |
| `PackUnknownComponent` | 3 | 某个制品的组件 id 不在清单中 |
