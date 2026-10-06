---
title: 退出码
description: setup 和 nbpack 的稳定退出码、对应的 C ABI 状态码，以及事件错误码。
---

权威来源：[cli-v1](https://github.com/niobium-project/niobium/blob/main/docs/spec/cli-v1.md#exit-codes) 中的退出码表及其实现 [`libs/core/exit_code.zig`](https://github.com/niobium-project/niobium/blob/main/libs/core/exit_code.zig)。退出码是公开的兼容性契约：一个代码的含义永远不会改变。

C ABI 以负数返回相同的代码；常量定义在 [`distribution.h`](https://github.com/niobium-project/niobium/blob/main/api/c/distribution.h) 中。

| 退出码 | C ABI 状态 | 事件类别 | 含义 |
|---|---|---|---|
| 0 | `DIST_OK`（0） | | 成功，包括已经是最新版本时的更新 |
| 1 | `DIST_E_INTERNAL`（-1） | `internal` | 内部错误（缺陷） |
| 2 | `DIST_E_USAGE`（-2） | `usage` | 用法错误 |
| 3 | `DIST_E_VALIDATION`（-3） | `validation` | 清单、组件、归档或输入验证失败，包括被禁止的字段 |
| 4 | `DIST_E_TRUST`（-4） | `trust` | 信任验证失败：签名、过期、回滚、哈希或长度 |
| 5 | `DIST_E_NETWORK`（-5） | `network` | 仓库或网络不可用 |
| 6 | `DIST_E_FILESYSTEM`（-6） | `fs` | 文件系统错误，包括磁盘空间不足和文件被锁定 |
| 7 | `DIST_E_PERMISSION`（-7） | `permission` | 权限不足，或取消了提权 |
| 8 | `DIST_E_BOOTSTRAP_PENDING`（-8） | `bootstrap` | 已提交，但 App Bootstrap 失败 |
| 9 | `DIST_E_CANCELLED`（-9） | `cancelled` | 被用户取消 |
| 10 | `DIST_E_BUSY`（-10） | `busy` | 该产品的另一个事务正在进行 |
| 11 | `DIST_E_UNSUPPORTED_SCHEMA`（-11） | `schema` | 安装程序过旧，或 schema 不受支持 |
| 12 | `DIST_E_NOT_INSTALLED`（-12） | `not_installed` | 产品未安装 |
| 13 | `DIST_E_UNSUPPORTED_PLATFORM`（-13） | `platform` | 平台或能力不可用 |

`setup run` 是例外：它返回所运行程序的退出码，或 128 加上信号编号。

## 事件错误码 { #event-error-codes }

使用 `--json` 时，失败会发出一个 `error` 事件，其 `code` 为 `<category>.<name>`：类别来自上表，名称是内部错误名去掉类别前缀后的蛇形命名。例如 `TrustHashMismatch` 变为 `trust.hash_mismatch`，`NotInstalled` 变为 `not_installed.not_installed`。类别与退出码表一致；规范没有列举点号之后的名称。请按类别或退出码匹配，把名称展示给人看。

原因与解决办法见[故障排查](/zh/troubleshooting/#exit-codes-cause-and-fix)。
