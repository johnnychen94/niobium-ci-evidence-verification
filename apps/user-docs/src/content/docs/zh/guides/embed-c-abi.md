---
title: 通过 C ABI 嵌入
description: 使用 libdistribution 在你自己的进程中检查、下载并应用更新。
---

`libdistribution` 通过 C ABI 提供与 `setup` 相同的引擎，因此应用或启动器可以自己检查并应用更新。本指南链接该库并完整走一遍一次更新。

## 构建并链接库

在 Niobium 检出目录中，`zig build` 会安装：

```text
zig-out/include/distribution.h
zig-out/lib/libdistribution.a        static library (macOS shown)
zig-out/lib/libdistribution.dylib    dynamic library
```

即头文件、静态库（以 macOS 为例）和动态库。包含 `distribution.h` 并链接任一库；加上 `-Dtarget=<triple>` 可为其他平台构建。在 Linux 上该库不链接 libc，因此不会把你的宿主绑定到某一个 C 库。

## 获取函数表

一切都通过一个导出函数进行，它返回一张带版本的函数表：

```c
#include "distribution.h"

const dist_api_v1 *api = NULL;
if (dist_get_api(DIST_ABI_V1, &api) != DIST_OK) {
    /* library too old or too new for this header */
}
```

如果库相对于该头文件过旧或过新，调用会失败。每个调用都返回 `DIST_OK`（0）或一个负的状态值，其绝对值就是对应的[退出码](/zh/reference/exit-codes/)；例如 `-4` 表示信任验证失败。

## 创建上下文

```c
dist_config_v1 config;
memset(&config, 0, sizeof config);
config.struct_size = sizeof config;
config.repository = "https://dl.example.com/hello";  /* or a directory path */
config.trust_root = root_bytes;                      /* contents of <N>.root.json */
config.trust_root_len = root_len;
config.product_id = "com.example.hello";
config.channel = NULL;                               /* NULL means "stable" */
config.scope = DIST_SCOPE_USER;
config.install_dir = NULL;                           /* NULL: platform default */
config.work_dir = NULL;                              /* NULL: platform cache */

dist_context *ctx = NULL;
int32_t status = api->context_create(&config, &ctx);
```

`repository` 可以是 URL 或目录路径；`trust_root` 是 `<N>.root.json` 的内容；`channel` 为 `NULL` 表示 `stable`；`install_dir` 和 `work_dir` 为 `NULL` 时使用平台默认位置和平台缓存。

一个上下文就是一个事务。它在第一次 `check_update` 或 `resolve` 时获取该产品的事务锁，并在 `context_destroy` 中释放；如果另一个事务持有该锁，你会得到 `DIST_E_BUSY`（-10）。

## 执行一次更新

```c
dist_update_info_v1 info;
memset(&info, 0, sizeof info);
info.struct_size = sizeof info;

status = api->check_update(ctx, &info);
if (status == DIST_OK && info.update_available) {
    status = api->resolve(ctx);
    if (status == DIST_OK) status = api->fetch(ctx);
    if (status == DIST_OK) status = api->stage(ctx);
    if (status == DIST_OK) status = api->transaction_commit(ctx);
}
if (status != DIST_OK && status != DIST_E_BOOTSTRAP_PENDING) {
    dist_buffer error = {0};
    api->last_error(ctx, &error);   /* {"code":"...","message":"...","exit_code":N} */
}
api->context_destroy(ctx);
```

- 在 resolve 之前调用 `fetch`、`stage` 和 `transaction_commit` 会返回 `DIST_E_USAGE`（-2）；如果已经是最新版本，它们什么也不做并返回 `DIST_OK`。
- 当新版本已提交但 App Bootstrap 失败时，`transaction_commit` 返回 `DIST_E_BOOTSTRAP_PENDING`（-8）。
- 通过 `dist_buffer` 返回的缓冲区归库所有，在同一上下文的下一次调用之前保持有效。

## 进度与取消

`event_subscribe(ctx, callback, user)` 以不带末尾换行的 JSON 字节传递每一个[事件](/zh/reference/events/)。`cancel(ctx)` 可以从任意线程调用；正在运行的操作会在下一个检查点以 `DIST_E_CANCELLED`（-9）停止。

## 限制

- 该库从不显示提权提示。只有当你的进程本身已经提权时，整机范围才可用；否则调用返回 `DIST_E_PERMISSION`（-7）。
- 在 Linux 上它从 `/proc/self/environ` 读取环境变量，因此你的进程在启动之后设置的变量不会被看到。

以这种方式安装一个产品的完整程序是 C 冒烟测试 [`tests/c-smoke/main.c`](https://github.com/niobium-project/niobium/blob/main/tests/c-smoke/main.c)。逐个函数的语义见 [C ABI 参考](/zh/reference/c-abi/)。
