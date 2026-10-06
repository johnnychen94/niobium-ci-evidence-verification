---
title: setup 命令行
description: setup 可执行文件的命令、选项和设置优先级。
---

权威来源：[cli-v1](https://github.com/niobium-project/niobium/blob/main/docs/spec/cli-v1.md#commands)；解析器是 [`apps/setup/cli.zig`](https://github.com/niobium-project/niobium/blob/main/apps/setup/cli.zig)。

## 命令

| 命令 | 作用 |
|---|---|
| `setup` | 打开安装程序窗口。没有图形会话（Linux 上未设置 `DISPLAY`）或 `setup` 没有产品配置时，改为打印帮助 |
| `setup install [options]` | 安装产品 |
| `setup update [options]` | 更新到通道上最新的发布；已经是最新版本时以 0 退出 |
| `setup repair [options]` | 重新安装已安装的发布，恢复缺失或被更改的文件 |
| `setup uninstall [options]` | 移除产品及其系统集成 |
| `setup run <target> [options] [-- args...]` | [便携运行](/zh/concepts/artifacts/#portable-run)：从缓存运行一个组件而不安装 |
| `setup status [options]` | 打印已安装的产品、版本、作用域、通道和根目录；未安装时以 12 退出 |
| `setup version`、`setup --version` | 打印 `setup` 的版本 |
| `setup --help`、`setup -h` | 打印用法 |

`<target>` 的形式是 `<product id>[:<component>.<entrypoint>]`。不指定入口点时，使用清单中第一个快捷方式的入口点。`--` 之后的所有内容原样传给程序；`run` 返回程序的退出码，如果程序被信号终止，则返回 128 加上信号编号。

## 选项

| 选项 | 含义 |
|---|---|
| `--silent` | 无交互；标准错误上只输出错误 |
| `--json` | 在标准输出上每行一个 JSON [事件](/zh/reference/events/)；`status` 打印一个 JSON 对象 |
| `--scope user\|machine` | 安装位置和权限。不指定时，`install` 使用配置的默认值，`update`、`repair` 和 `uninstall` 沿用已安装的作用域 |
| `--channel stable\|beta\|nightly` | 覆盖配置的通道 |
| `--product <id>` | 产品 id；必须与 `run` 目标的产品一致 |
| `--repo <url\|dir>` | 仓库地址或目录 |
| `--trust-root <file>` | 要信任的 root 元数据文件，替代配置中的 root |
| `--config <file>` | 产品配置文件，替代编译进 `setup` 的配置 |
| `--install-dir <dir>` | 作用域默认位置以外的安装根目录；之后对这种安装执行命令时需要再次指定 |
| `--components a,b` | 要安装的可选组件 id，替代标记为 `default` 的组件；必需组件总会安装 |

用法错误以退出码 2 退出：未知选项、选项给出两次、缺少或无效的值、多余的参数、在 `run` 之外使用 `--`、`run` 没有目标，以及显式的 `gui` 命令。

## 设置从哪里来

命令行选项优先于产品配置。配置是 `--config` 给出的文件，否则是编译进 `setup` 的配置（来自 `nbpack config`），否则是一个不指定任何产品的通用配置。

- 仓库：`--repo`，然后是 `setup` 旁边的 `repository/` 目录（离线包），然后是配置中的地址。
- 信任根：`--trust-root`，然后是配置中的 root。
- 通道：`--channel`，然后是带品牌 `setup` 中配置的通道。
- 作用域：`--scope`；仅对 `install`，使用配置的默认值。

`install`、`update` 和 `repair` 需要仓库和信任根；`uninstall` 两者都不需要。

## 输出

可读的进度和错误输出到标准错误；使用 `--json` 时，事件输出到标准输出。不带 `--silent` 或 `--json` 的成功事务以类似 `installed com.example.hello 1.0.0 (user) in <root>` 的一行结束。`setup status --json` 打印：

```json
{"schema":1,"product_id":"com.example.hello","version":"1.1.0","release_sequence":2,"scope":"user","channel":"stable","root":"<install root>","bootstrap":"done"}
```

`bootstrap` 为 `none`、`done` 或 `pending`。

选项 `--priv-helper-v1` 是提权助手的内部入口，不是公开命令。
