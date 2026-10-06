---
title: 静默安装
description: 在脚本、部署工具或 CI 中不带窗口地运行 setup，并读取其结果。
---

安装程序窗口提供的每一个操作也都是一条命令。使用 `--silent` 和 `--json` 时，`setup` 无交互地运行，在标准输出上打印机器可读的事件，并通过退出码报告结果。

## 安装

```sh
setup install --silent --json --scope user
```

- `--scope user|machine` 选择安装位置；不指定时使用产品的默认作用域。整机范围需要管理员权限。
- `--components runtime,docs` 列出要安装的可选组件，以替代标记为 `default` 的组件；必需组件总会安装。列出的或必需的组件如果没有适用于此平台的制品，会以退出码 13 失败。
- `--install-dir <dir>` 安装到作用域默认根目录以外的位置。
- `--channel stable|beta|nightly` 覆盖编译进 `setup` 的通道。
- `--repo <url|dir>` 覆盖发布的来源；离线包中的 `repository/` 会被自动使用。

在 Windows 上可执行文件是 `setup.exe`；选项相同。

## 读取结果

以退出码判断是否成功：0 表示成功，其他每个值都有一个唯一的含义，列在[退出码](/zh/reference/exit-codes/)中。自动化中值得处理的代码：

| 代码 | 含义 | 典型动作 |
|---|---|---|
| 0 | 成功，包括“已经是最新版本” | 无 |
| 7 | 权限不足，或取消了提权提示 | 以提升的权限重新运行 |
| 8 | 已安装，但应用的 App Bootstrap 失败 | 版本已就位；检查应用 |
| 10 | 该产品的另一个事务正在运行 | 稍后重试 |
| 12 | 未安装（对于 `update`、`repair`、`uninstall`） | 改为运行 `install` |

使用 `--json` 时，标准输出每行一个 JSON 对象：

```json
{"schema":1,"phase":"download","progress":0.998}
{"schema":1,"phase":"complete"}
```

失败时会产生一个 `error` 事件，带有稳定的 `code`（例如 `trust.hash_mismatch`）和 `exit_code`。字段说明见[事件](/zh/reference/events/)。人类可读的消息输出到标准错误；`--silent` 把它们限制为只有错误。

## 检查、更新、修复、卸载

```sh
setup status --json      # one JSON object, or exit code 12 when not installed
setup update --silent --json
setup repair --silent --json
setup uninstall --silent --json
```

`setup status --json` 输出一个 JSON 对象；未安装时以退出码 12 退出。`update`、`repair` 和 `uninstall` 沿用现有安装的作用域。它们只在每个作用域的默认根目录中查找安装；对于用 `--install-dir` 安装的产品，请再次传入相同的 `--install-dir`。`uninstall` 不需要仓库。

每个安装还在安装根目录的 `maintainer/` 下保留一份自己的 `setup` 副本，部署工具可以调用它来完成之后的更新和移除。

## 整机范围的状态

静默的整机范围安装尚未在真实的 Windows 或 Linux 系统上验证（[状态与平台](/zh/status/)上的 N1-UJ-02）。在依赖它们之前，请先在你的目标系统上验证。
