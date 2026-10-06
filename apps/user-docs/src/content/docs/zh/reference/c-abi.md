---
title: C ABI
description: libdistribution 的函数、结构体和状态码。
---

权威来源：头文件 [`api/c/distribution.h`](https://github.com/niobium-project/niobium/blob/main/api/c/distribution.h) 和 [abi-v1](https://github.com/niobium-project/niobium/blob/main/docs/spec/abi-v1.md) 规范。完整的使用流程见[通过 C ABI 嵌入](/zh/guides/embed-c-abi/)。

## 入口

```c
int32_t dist_get_api(uint32_t requested_version, const dist_api_v1 **out_api);
```

`requested_version` 必须是 `DIST_ABI_V1`（1）；其他任何值都返回 `DIST_E_USAGE`。成功时，`*out_api` 指向一张静态函数表。

## 函数表 `dist_api_v1`

| 成员 | 作用 |
|---|---|
| `struct_size` | 函数表的大小；之后的版本只会在末尾追加成员 |
| `context_create(config, &ctx)` | 根据 `dist_config_v1` 创建上下文 |
| `context_destroy(ctx)` | 释放上下文及其事务锁；接受 NULL |
| `check_update(ctx, &info)` | 解析通道并填写 `dist_update_info_v1` |
| `resolve(ctx)` | 解析并验证发布清单 |
| `fetch(ctx)` | 下载并验证制品 |
| `stage(ctx)` | 解包到暂存区 |
| `transaction_commit(ctx)` | 执行并提交事务，先运行恢复 |
| `portable_resolve(ctx, target, &buffer)` | 解析便携运行目标并返回其缓存路径 |
| `portable_run(ctx, target, argv, &exit_code)` | 运行它；`argv` 以 NULL 结尾或为 NULL |
| `event_subscribe(ctx, callback, user)` | 注册[事件](/zh/reference/events/)回调 |
| `cancel(ctx)` | 请求取消；可以从任意线程调用 |
| `last_error(ctx, &buffer)` | 最近一次错误的 JSON：`{"code":...,"message":...,"exit_code":N}` |

## 结构体

**`dist_config_v1`**：`struct_size`；`repository`（URL 或目录，UTF-8）；`trust_root` 和 `trust_root_len`（一个 `<N>.root.json` 的字节）；`product_id`；`channel`（`"stable"`、`"beta"`、`"nightly"`，或 NULL 表示 stable）；`scope`（`DIST_SCOPE_USER` 0 或 `DIST_SCOPE_MACHINE` 1）；`install_dir` 和 `work_dir`（NULL 表示平台默认值）。

**`dist_update_info_v1`**：`struct_size`；`update_available`（通道提供更高的 `release_sequence` 时为 1）；`release_sequence`；`installed_release_sequence`；`version`（提供的应用版本，存放在 64 字节数组中，以 NUL 结尾）。

**`dist_buffer`**：`{ const uint8_t *data; size_t len; }`，归库所有，在同一上下文的下一次调用之前有效。

## 状态码

`DIST_OK` 为 0。每个错误都是负数，其绝对值等于同一故障的[退出码](/zh/reference/exit-codes/)：`DIST_E_INTERNAL` -1、`DIST_E_USAGE` -2、`DIST_E_VALIDATION` -3、`DIST_E_TRUST` -4、`DIST_E_NETWORK` -5、`DIST_E_FILESYSTEM` -6、`DIST_E_PERMISSION` -7、`DIST_E_BOOTSTRAP_PENDING` -8、`DIST_E_CANCELLED` -9、`DIST_E_BUSY` -10、`DIST_E_UNSUPPORTED_SCHEMA` -11、`DIST_E_NOT_INSTALLED` -12、`DIST_E_UNSUPPORTED_PLATFORM` -13。

## 规则

- 一个上下文就是一个事务。锁在第一次 `check_update` 或 `resolve` 时获取，在 `context_destroy` 时释放；锁被占用时返回 -10。
- `check_update` 和 `resolve` 都会执行解析；哪个先调用都可以，第二个复用结果。
- 在 resolve 之前调用 `fetch`、`stage` 和 `transaction_commit` 返回 -2。没有可用更新时，它们什么也不做并返回 0。
- `cancel` 之后，正在运行的调用和之后的每个调用都返回 -9。
- 每次失败还会向已订阅的回调发送一个 `error` 事件。
- 没有任何 Zig 类型、分配器或错误跨越边界。
- 该库从不请求提权；整机范围需要一个已经提权的进程（否则返回 -7）。
- 环境变量：在 Linux 上从 `/proc/self/environ` 读取，因为该库不链接 libc，所以进程启动之后调用的 `setenv` 不会被看到；在 macOS 上从 `environ` 读取；在 Windows 上从进程环境块读取。
