---
title: 实现 App Bootstrap
description: 在你的应用中处理安装程序的 activate 和 deactivate 请求。
---

本指南为你的应用加上 App Bootstrap，使它能在安装、更新或修复之后迁移自己的数据，并在卸载之前做清理。请先阅读[安装程序与 App Bootstrap](/zh/concepts/app-bootstrap/)，了解为什么这部分放在你的应用中。

## 1. 声明入口点

在组件的 `component.json` 中，标记处理引导的入口点：

```json
"entrypoints": { "main": { "path": "bin/hello", "bootstrap": true } }
```

在 `product.json` 中，让清单指向它：

```json
"bootstrap": { "entrypoint": "runtime.main", "protocol": 1 }
```

入口点可以就是你的普通应用二进制文件：引导模式由其参数选择。

## 2. 识别调用

`setup` 启动入口点时恰好传入一个参数 `--installer-bootstrap-v1`，不经过 shell。把这个参数当作你程序的一种独立模式，在其中不做任何别的事：不显示窗口，除非迁移需要否则不访问网络，不弹出提示。

## 3. 读取请求

标准输入携带一个 JSON 对象，然后关闭：

```json
{ "protocol": 1, "operation": "activate", "transaction_id": "tx-3-...",
  "from_version": "1.1.0", "to_version": "1.2.0", "scope": "user",
  "install_root": "/Users/a/Library/Application Support/com.example.hello" }
```

- `operation` 在安装、更新或修复之后为 `activate`，在卸载之前为 `deactivate`。
- 首次安装时 `from_version` 为 `null`。
- 崩溃之后，同一个 `transaction_id` 可能再次到来：请让这项工作幂等。

## 4. 回答

在标准输出上写一行 JSON，成功时以退出码 0 退出：

```json
{ "protocol": 1, "status": "ok", "message": "migrated 2 tables" }
```

失败时使用 `"status": "error"` 并附上消息。非零退出码、缺少或无效的响应、标准输出超过 64 KiB，或运行超过 120 秒，都算作失败。

## 5. 遵守限制

- 该进程以启动安装的用户身份运行，即使是整机范围的安装也是如此，且永远不会被提权。不要尝试提权；把服务等机器级需求声明在清单中。
- 只有 `PATH`、`HOME`、`USERPROFILE`、`LANG`、`TMPDIR`、`TEMP`、`TMP` 和 `SystemRoot` 会从环境中传入。
- `activate` 失败之后，新版本保持安装状态，`setup` 以退出码 8 退出，安装把引导记录为待执行，直到之后的某次运行成功。

## 示例

[`examples/hello/app/main.zig`](https://github.com/niobium-project/niobium/blob/main/examples/hello/app/main.zig) 中的示例应用用大约 70 行 Zig 实现了该协议：它解析请求，把 `<operation> <from> <to> <scope>` 追加到主目录中的一个日志文件，并回答 `ok`。[教程](/zh/start/)展示了它在安装、更新和卸载之后的日志。

规范性的协议是 [bootstrap-v1](https://github.com/niobium-project/niobium/blob/main/docs/spec/bootstrap-v1.md)，另有[请求](https://github.com/niobium-project/niobium/blob/main/api/schema/bootstrap-request-v1.schema.json)和[响应](https://github.com/niobium-project/niobium/blob/main/api/schema/bootstrap-response-v1.schema.json)的 JSON Schema。
