---
title: 仓库与安装布局
description: Niobium 仓库、离线包、安装根目录和每用户缓存中的文件，以及它们的默认位置。
---

权威来源：仓库见 [tuf-profile-v1](https://github.com/niobium-project/niobium/blob/main/docs/spec/tuf-profile-v1.md)，安装根目录见[事务模型](https://github.com/niobium-project/niobium/blob/main/docs/architecture/transaction-model.md)，路径策略见 [`libs/planner/paths.zig`](https://github.com/niobium-project/niobium/blob/main/libs/planner/paths.zig)。

## 仓库

```text
metadata/<N>.root.json        one per root version
metadata/timestamp.json       the only file without a version number
metadata/<N>.snapshot.json
metadata/<N>.targets.json
metadata/<N>.<channel>.json   stable, beta, nightly
targets/<sha256 hex>          manifests and artifacts, named by their hash
```

每个 root 版本对应一个 `<N>.root.json`；`timestamp.json` 是唯一不带版本号的文件；每个通道（stable、beta、nightly）有自己的元数据；`targets/` 存放以哈希命名的清单和制品。无论通过 HTTP 提供还是从目录读取，布局都相同。只有 `nbpack` 会写入它。

## 离线包

```text
<bundle>/
  setup                       setup.exe on Windows
  repository/                 a complete repository, as above
  licenses/Inter-OFL.txt      license of the font compiled into setup
```

`setup` 在 Windows 上是 `setup.exe`；`repository/` 是上述的完整仓库；`licenses/Inter-OFL.txt` 是编译进 `setup` 的字体的许可证。

## 安装根目录

```text
<install root>/
  installation.json           installed product, release, manifest, integrations, bootstrap state
  current -> versions/<n>     the active version
  versions/<n>/<component>/   files of each component
  staging/tx-<n>/             staging of user-scope transactions
  maintainer/setup            copy of setup for update, repair, uninstall (setup.exe on Windows)
  trust/state.json            accepted TUF versions and release sequence
  journal/                    transaction journal
```

- `installation.json`：已安装的产品、发布、清单、系统集成和引导状态。
- `current`：指向活动版本。
- `versions/<n>/<component>/`：每个组件的文件。
- `staging/tx-<n>/`：用户范围事务的暂存区。
- `maintainer/setup`：用于更新、修复和卸载的 `setup` 副本（Windows 上为 `setup.exe`）。
- `trust/state.json`：已接受的 TUF 版本和发布序号。
- `journal/`：事务日志。

## 默认位置

| | macOS | Windows | Linux |
|---|---|---|---|
| 安装根目录，用户范围 | `~/Library/Application Support/<id>` | `%LOCALAPPDATA%\Programs\<id>` | `$XDG_DATA_HOME/<id>`，或 `~/.local/share/<id>` |
| 安装根目录，整机范围 | `/Library/Application Support/<id>` | `%ProgramFiles%\<id>` | `/opt/<id>` |
| 每用户缓存 | `~/Library/Caches/<id>` | `%LOCALAPPDATA%\<id>\Cache` | `$XDG_CACHE_HOME/<id>`，或 `~/.cache/<id>` |

`<id>` 是产品 id。`--install-dir` 替换安装根目录。组件不能选择这些路径中的任何一个。

## 每用户缓存

```text
<cache>/
  lock                        transaction lock, one per user and product
  downloads/                  artifacts being downloaded
  staging/tx-<n>/             staging of machine-scope transactions (user scope stages in the install root)
  logs/crash-<time>.json      crash records
  portable/                   Portable Run cache
    sha256/<hex>/             unpacked component, its component.json and last-use time
    downloads/
    trust.json                accepted TUF versions for Portable Run
```

- `lock`：事务锁，每个用户和产品一个。
- `downloads/`：正在下载的制品。
- `staging/tx-<n>/`：整机范围事务的暂存区（用户范围在安装根目录中暂存）。
- `logs/crash-<time>.json`：崩溃记录。
- `portable/`：便携运行缓存；`sha256/<hex>/` 存放解包后的组件、它的 `component.json` 和最近使用时间，`trust.json` 记录便携运行已接受的 TUF 版本。
