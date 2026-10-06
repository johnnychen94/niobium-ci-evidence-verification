---
title: 事件
description: setup --json 和 C ABI 发出的 JSON 进度事件。
---

权威来源：[cli-v1](https://github.com/niobium-project/niobium/blob/main/docs/spec/cli-v1.md#events) 的事件一节和 [event-v1.schema.json](https://github.com/niobium-project/niobium/blob/main/api/schema/event-v1.schema.json)。

`setup --json` 在标准输出上每行写一个 JSON 对象。C ABI 把同样的对象（不带换行）传给通过 `event_subscribe` 注册的回调。

```json
{"schema":1,"phase":"download","progress":0.37}
{"schema":1,"phase":"error","code":"trust.hash_mismatch","message":"...","exit_code":4}
```

## 字段

| 字段 | 是否出现 | 含义 |
|---|---|---|
| `schema` | 总是 | `1` |
| `phase` | 总是 | 引擎阶段，见下文 |
| `progress` | 可选 | 阶段内 0 到 1 之间的数字 |
| `code` | 可选 | 错误或通知的 `<category>.<name>`（[退出码](/zh/reference/exit-codes/#event-error-codes)） |
| `message` | 可选 | 人类可读的文本 |
| `exit_code` | 可选 | 此事件对应的退出码 |

忽略你不认识的字段：可能会增加新字段，而已有字段的含义永远不会改变。

## 阶段

`recover`、`discover`、`validate`、`resolve`、`plan`、`prepare`、`download`、`verify`、`execute`、`commit`、`bootstrap`、`verify_install`、`finalize`、`complete`、`error`。

这个集合是固定的；顺序取决于操作。从本地仓库进行的用户范围安装依次发出 `recover`、`discover`、`resolve`、`validate`、`prepare`、`download`、`verify`、`plan`、`execute`、`commit`、`bootstrap`、`verify_install`、`finalize`、`complete`。成功的运行包含 `complete`；失败的运行恰好发出一个 `error` 事件。当 App Bootstrap 在提交之后失败时，`setup` 还会发出一个 `bootstrap` 事件，其代码为 `bootstrap.pending`，`exit_code` 为 8。
