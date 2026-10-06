---
title: 制品格式
description: 组件制品（tar.zst）的布局、解包规则和限制。
---

权威来源：[artifact-format-v1](https://github.com/niobium-project/niobium/blob/main/docs/spec/artifact-format-v1.md)。

## 布局

组件制品是一串 zstd 帧，解压后是一个 ustar tar 归档（允许 pax `path` 头）。

| 规则 | 值 |
|---|---|
| 第一个条目 | 普通文件 `component.json` |
| 其他所有条目 | `files` 或 `files/` 之下的路径 |
| 条目顺序 | 先是 `component.json`，然后是按路径字节排序的 `files/` 下的条目 |
| 时间戳、属主 | mtime 为 0，uid 和 gid 为 0 |
| 完整性 | 整个文件的 SHA-256 等于清单和已签名 targets 中的摘要；在解包之前检查 |

`files/X` 安装为 `current/<component>/X`。`nbpack component build` 生成这种布局；你不需要手工构建归档。

## 接受的条目

| 条目类型 | 处理 |
|---|---|
| 普通文件、目录 | 允许 |
| pax 扩展头 | 只使用 `path` 和 `size` 键 |
| 符号链接、硬链接、字符或块设备、FIFO、GNU 扩展、全局 pax 头 | 拒绝：`ForbiddenEntryType` |

## 路径规则

路径为 UTF-8，以 `/` 分隔，最多 1024 字节、64 个段。以下情况以 `UnsafePath` 拒绝：开头的 `/`、盘符、反斜杠、NUL、`:`、`.` 或 `..` 段、重复的 `/`、控制字符、`<>"|?*` 中的任一字符、以 `.` 或空格结尾的段，以及 Windows 保留名称（`CON`、`PRN`、`AUX`、`NUL`、`COM0` 到 `COM9`、`LPT0` 到 `LPT9`，带任何扩展名）。忽略 ASCII 大小写比较后出现两次的路径以 `DuplicateEntry` 拒绝，创建文件时文件系统报告的冲突也一样。

## 限制

| 限制 | 值 | 错误 |
|---|---|---|
| 条目数 | 65 536 | `ArchiveTooManyEntries` |
| 单个文件 | 2 GiB | `ArchiveEntryTooLarge` |
| 解包后总大小 | 8 GiB | `ArchiveBomb` |
| 解包后大小与压缩大小之比 | 200，超过 1 MiB 后适用 | `ArchiveBomb` |
| `component.json` | 1 MiB | |

每个条目声明的大小在写入任何内容之前就被计入。归档结束块之后的字节必须为零，否则报 `ArchiveCorrupt`。所有这些错误都以退出码 3 退出。
