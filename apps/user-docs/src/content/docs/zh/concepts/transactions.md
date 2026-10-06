---
title: 事务
description: Niobium 如何保证被中断的安装、更新或卸载最终停在旧版本或新版本。
---

每一次安装、更新、修复和卸载都作为一个事务运行，且只有一个不可回退点。在该点之前，旧版本保持生效，恢复时回滚；在该点之后，新版本生效，恢复时前滚。无论在任何时刻杀掉进程、切断电源或写满磁盘：下一次运行 `setup` 都会停在旧版本或新版本，绝不会是两者的混合。

## 安装根目录

```text
<install root>/
  installation.json        what is installed: product, release, manifest, integrations
  current -> versions/<n>  the active version (a symlink, or a junction on Windows)
  versions/<n>/<component>/...
  maintainer/              a copy of setup, used for later update, repair and uninstall
  trust/state.json         the TUF versions this installation has accepted
  journal/                 the transaction journal
```

- `installation.json`：已安装的内容，包括产品、发布、清单和系统集成；
- `current`：当前生效的版本（符号链接，在 Windows 上是目录联接）；
- `maintainer/`：一份 `setup` 副本，用于之后的更新、修复和卸载；
- `trust/state.json`：此安装已接受的 TUF 版本；
- `journal/`：事务日志。

快捷方式、文件关联和服务都通过 `current` 指向路径，因此在切换前后都保持有效。

## 步骤

1. **暂存。** 经过验证的制品被解包到 `versions/<new>/`。当前生效版本使用的任何内容都不会被触碰。
2. **执行。** 计划中的操作逐一运行。每个操作只写入新版本或特定于版本的临时集成文件，并且每个操作都有回滚。
3. **提交。** `current` 以一个原子步骤切换到新版本。这就是不可回退点。
4. **收尾。** 运行 App Bootstrap，清理旧版本和事务日志。

进度记录在一个只追加的事务日志中（`begin`、每个已完成操作一条记录、`ready_to_commit`、`commit`、引导开始与结束、`finalized`），每写一条记录都会刷到磁盘。

## 恢复

`setup` 总是先运行恢复，然后才做其他事情。它读取事务日志的最后一条记录：

| 中断时机 | 恢复 | 结果 |
|---|---|---|
| 在提交记录之前 | 按相反顺序回滚已完成的操作，删除暂存内容 | 旧版本 |
| 在提交记录之后 | 重做切换和提交后的操作（它们都是幂等的） | 新版本 |
| 在 App Bootstrap 运行期间 | 把引导标记为待执行；之后会重试 | 新版本 |

写了一半的最后一行日志视为未写入。每个产品和用户同一时间只运行一个事务；第二个事务会得到退出码 10。进程结束时，锁由操作系统释放，因此崩溃永远不会留下需要手动清理的锁。

## App Bootstrap 在提交之后

你的应用的 [App Bootstrap](/zh/concepts/app-bootstrap/) 入口点在切换之后运行。如果它失败，新版本保持生效，`setup` 以退出码 8（`bootstrap_pending`）退出，引导会在之后的运行中重试。在应用可能已经迁移了数据之后再回滚文件，比重试迁移更糟。

## 如何测试

崩溃注入测试在每一次文件系统变更之后、每一条事务日志记录之后都会杀掉事务，并要求旧、新两种结果都会出现；一个带种子的模拟把注入的故障与反复的恢复混合在一起。结果列在[状态与平台](/zh/status/)的不变式 N1-INV-01 下。完整的状态机在[事务模型](https://github.com/niobium-project/niobium/blob/main/docs/architecture/transaction-model.md)中规定。

一个已知的限制：两个不同的用户在同一时刻操作同一个整机范围的产品时，彼此之间不会互斥。
