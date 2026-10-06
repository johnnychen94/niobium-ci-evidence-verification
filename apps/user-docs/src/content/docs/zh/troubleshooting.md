---
title: 故障排查与常见问题
description: 找到日志，把退出码对应到原因和解决办法，并在中断后恢复。
---

从退出码入手：`setup` 和 `nbpack` 的每次失败都以一个退出码结束；使用 `--json` 时，还会输出一个 `error` 事件，其 `code` 指明原因。

## 日志与崩溃记录 { #logs-and-crash-records }

- **进度和错误**以可读的文本行输出到标准错误。加上 `--json` 后，会改为在标准输出上输出结构化的[事件](/zh/reference/events/)。
- **崩溃记录**在 `setup` 发生 panic 或遇到致命信号时写入：位于每用户缓存的 `logs` 目录中的 `crash-<UTC time>.json`。

| 平台 | 缓存目录（`<cache>`） |
|---|---|
| macOS | `~/Library/Caches/<product id>` |
| Windows | `%LOCALAPPDATA%\<product id>\Cache` |
| Linux | `$XDG_CACHE_HOME/<product id>`，或 `~/.cache/<product id>` |

同一个目录还存放事务锁和下载内容。崩溃记录包含版本、产品、引擎阶段、事务编号、时间以及最多 32 个返回地址；请把它附在缺陷报告中。在 Linux 上，发布的二进制文件不带调试信息，因此需要用同一提交的未剥离构建来解析地址。

## 退出码：原因与解决办法 { #exit-codes-cause-and-fix }

| 代码 | 原因 | 怎么做 |
|---|---|---|
| 1 | 内部错误 | 这是缺陷：请附上命令、`--json` 输出和崩溃记录（如有）报告它 |
| 2 | 用法错误：未知或重复的选项、缺少值，或没有配置仓库或信任根 | 对照 [setup 参考](/zh/reference/setup-cli/)检查命令；传入 `--repo` 或使用带品牌的 `setup` |
| 3 | 清单、组件或归档被拒绝，或 `nbpack` 输入无效（例如 `PackSequenceNotIncreasing`） | 修正输入；对于 `nbpack publish`，提升 `release_sequence` |
| 4 | 信任验证失败：签名、过期、回滚或哈希 | 如果元数据已过期，由发布者运行 `nbpack sign` 并上传结果。否则说明仓库被改动过，或与 `setup` 中的信任根不匹配 |
| 5 | 仓库或网络不可用 | 检查地址和网络连通性，或使用离线包 |
| 6 | 文件系统错误，包括磁盘已满或文件被锁定 | 释放空间，关闭应用，然后重试 |
| 7 | 权限不足，或取消了提权提示 | 整机范围请以管理员权限重新运行，或改用用户范围 |
| 8 | 已安装，但 App Bootstrap 失败（`bootstrap_pending`） | 新版本已生效；修复应用的引导逻辑。之后的运行会重试 |
| 9 | 已取消，或窗口在安装前被关闭 | 重新运行 |
| 10 | 该产品的另一个事务正在运行 | 等待它结束；那个进程退出时锁会被释放 |
| 11 | 此发布需要更新的安装程序，或使用了未知的 schema | 使用更新的 `setup` |
| 12 | 产品未安装（`update`、`repair`、`uninstall`、`status`） | 先安装；如果安装在自定义位置，请传入相同的 `--install-dir` |
| 13 | 平台或能力不可用，例如没有适用于此平台的制品 | 确认该发布包含此平台的制品 |

完整的表格（C ABI 以负值共用）见[退出码](/zh/reference/exit-codes/)。

## 中断之后

用任意命令再次运行 `setup`。它会首先恢复被中断的事务：如果中断发生在提交之前，就回到旧版本；如果发生在提交之后，就前进到新版本（[事务](/zh/concepts/transactions/)）。不要手动删除安装根目录中的文件；那是 `setup repair` 的工作。

如果一个事务以退出码 8 结束，说明安装已经完成，只是 App Bootstrap 尚待执行；在之后的某次运行成功之前，`setup status --json` 会把 `"bootstrap"` 显示为待执行。

## 常见问题

**有没有 `setup` 或 `nbpack` 的下载？** 没有。两者都用 Zig 0.17.0 从源码构建：由你的产品构建通过 Niobium 构建 API 完成，或在 Niobium 检出目录中运行 `zig build`。

**能在安装过程中运行脚本吗？** 不能。把产品逻辑放进 [App Bootstrap](/zh/concepts/app-bootstrap/)；在[清单](/zh/guides/package/#declare-integrations)中声明操作系统集成。

**如何把用户回滚到之前的版本？** 发布一个 `release_sequence` 更高、但包含较旧应用版本的新发布（[通道与晋升](/zh/concepts/channels/#ordering-and-rollback)）。

**不带参数运行 `setup` 时打印了帮助，而不是打开窗口。** 在没有 `DISPLAY` 的 Linux 上，以及在没有产品配置的 `setup` 构建中，它都会这样做。请构建一个带品牌的 `setup`（[发布与托管](/zh/guides/publish-and-host/#point-setup-at-the-repository)）。

**安装程序窗口支持 Wayland 吗？** Linux 窗口后端是 X11；原生 Wayland 后端已推迟（[状态与平台](/zh/status/)）。
