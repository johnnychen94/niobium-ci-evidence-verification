---
title: 打包你的产品
description: 编写组件元数据和产品清单，声明系统集成，并构建组件制品。
---

本指南把你的构建产生的文件变成 Niobium 组件制品和一份产品清单模板。它假定你的产品仓库已像[教程](/zh/start/)中那样依赖 Niobium。

## 描述每个组件

把你的产品拆分成组件：用户可以安装或不安装的单元，例如运行时、命令行工具或文档。至少要有一个必需的组件。为每个组件编写一个 `component.json`：

```json
{
  "schema": 1,
  "id": "runtime",
  "entrypoints": {
    "main": { "path": "bin/hello", "bootstrap": true },
    "agent": { "path": "bin/hello-agent" }
  },
  "executables": ["bin/hello", "bin/hello-agent"]
}
```

- `id` 使用 `[a-z0-9_-]`，最多 64 字节，并且必须与清单中的组件 id 一致。
- 路径相对于组件的文件，且必须存在于其中。
- 只有 `executables` 中的文件会获得可执行位。
- 如果某个入口点实现了 [App Bootstrap](/zh/guides/app-bootstrap/)，把它标记为 `"bootstrap": true`。
- 不要写 `version` 或 `platform`：构建制品时会加上这两者。

当某个路径因平台而异（例如 Windows 上是 `bin/hello.exe`）时，为每个变体保留一个 `component.json`，并在 `build.zig` 中按目标选择，就像 `examples/hello` 用 `component.windows.json` 所做的那样。

## 编写产品清单模板

`product.json` 就是发布清单，只是每个组件的 `artifacts` 留空；`nbpack` 在发布时填入摘要：

```json
{
  "schema": 1,
  "min_installer": "0.1.0",
  "product": {
    "id": "com.example.hello",
    "name": "Hello",
    "publisher": "Example Inc.",
    "version": "1.0.0",
    "release_sequence": 1
  },
  "install": { "default_scope": "user", "allowed_scopes": ["user", "machine"] },
  "components": [
    { "id": "runtime", "title": "Hello Runtime", "required": true, "default": true, "artifacts": {} }
  ],
  "bootstrap": { "entrypoint": "runtime.main", "protocol": 1 }
}
```

`product.id` 是由 `[a-z0-9.-]` 组成的反向域名；它决定安装目录的名称，之后不能更改，否则就成了另一个产品。所有字段都列在[清单参考](/zh/reference/manifest/)中。

## 声明系统集成 { #declare-integrations }

系统集成以 `<component>.<entrypoint>` 的形式指向一个入口点。在 `integrations` 下添加你需要的项：

```json
"integrations": {
  "shortcuts": [{ "name": "Hello", "entrypoint": "runtime.main" }],
  "file_associations": [
    { "extension": ".hello", "entrypoint": "runtime.main", "description": "Hello Document" }
  ],
  "services": [{ "id": "hello-agent", "entrypoint": "runtime.agent", "start": "manual" }]
}
```

每一项最终变成什么，取决于平台和作用域：

| 系统集成 | macOS | Windows | Linux |
|---|---|---|---|
| 快捷方式 | `~/Applications`（用户）或 `/Applications`（整机）中的链接 | 开始菜单 `.lnk` | `.desktop` 文件 |
| 文件关联 | 安装时不注册：请在你的应用包中声明 | `Classes` 注册表项 | `mimeapps.list` 和 `.desktop` MIME 类型 |
| 服务，整机范围 | launchd 守护进程 | 服务控制管理器 | systemd 单元 |
| 服务，用户范围 | launchd 代理 | 不可用 | systemd 用户单元 |

在 v0.1 中，规划器会略过平台和作用域无法提供的系统集成（上表中“不”字开头的两格），安装在没有它们的情况下仍然成功。应用注册无需声明：在 Windows 上，框架自己写入卸载注册表项。每种系统集成最多允许 32 项。

## 构建制品

在 `build.zig` 中，为每个组件和目标构建一个制品：

```zig
const runtime = niobium.addComponent(b, target, .{
    .id = "runtime",
    .metadata = b.path("components/runtime/component.json"),
    .files = runtime_files.getDirectory(),
    .version = version,
});
```

`files` 是要安装到组件根目录下的目录树；其中只能包含普通文件和目录。在构建之外，可以用 `nbpack component build` 完成同样的事：

```sh
nbpack component build --source components/runtime/component.json --files payload/ \
  --version 1.2.0 --platform macos-aarch64 --out runtime-macos-aarch64.tar.zst
```

在写出文件之前，`nbpack` 会让结果经过安装程序使用的同一个严格解包器。要重新检查一个已有的制品：`nbpack component validate runtime-macos-aarch64.tar.zst`。

一次发布需要为清单中的每个组件至少提供一个制品，每个平台最多一个。如果你用操作系统代码签名证书签名你的二进制文件，请在这一步之前完成（[签名与密钥管理](/zh/guides/sign-and-keys/#platform-code-signing)）。

## 为安装程序窗口设置品牌

`branding.json` 设置图形安装程序的文字和颜色：`product_name`、`publisher`、`accent`（`#RRGGBB`）、`welcome_title`、`welcome_body`、`complete_body` 和 `license`，全部是纯文本。用 `nbpack config --logo` 传入 PNG 标志。如果强调色在浅色和深色主题下都无法达到 4.5:1 的对比度，窗口会拒绝启动；命令行会忽略品牌设置。

下一步：[签名与密钥管理](/zh/guides/sign-and-keys/)。
