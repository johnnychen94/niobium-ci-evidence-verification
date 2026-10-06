---
title: 教程：第一次发布
description: 用 Niobium 构建 API 构建示例产品，用开发密钥签名，安装它，发布一次更新，然后卸载。
---

在本教程中，你将拿到示例产品 `Hello`，像你自己的产品仓库那样构建它，用一次性的开发密钥签名，从本地仓库安装，发布第二个版本，更新到该版本，然后卸载。整个过程大约十五分钟，大部分时间花在第一次构建上。

命令适用于 POSIX shell。本流程已在 macOS（arm64）上完整运行过；在 Linux 和 Windows 上安装路径不同，会在出现的地方注明。

## 开始之前

- **Zig 0.17.0。** Niobium 没有预构建的二进制文件：`setup` 和 `nbpack` 由你的构建从源码编译。
- **git**，用于获取示例。
- **第一次构建需要网络**：Zig 从 GitHub 下载 Niobium，Niobium 的构建会下载几个固定版本的上游源码（stb_truetype、zstd、Inter 字体）。之后的构建可以离线进行。

## 1. 获取示例产品

```sh
git clone https://github.com/niobium-project/niobium
cp -R niobium/examples/hello hello
cd hello
```

`hello` 现在是一个完整的产品仓库：应用源码（`app/`）、两个组件（`components/runtime`、`components/docs`）、产品清单模板（`product.json`）、安装程序品牌配置（`branding.json`），以及一个调用 Niobium 构建 API 的 `build.zig`。

## 2. 依赖一个固定的 Niobium 提交

打开 `build.zig.zon`，删除 `.niobium = .{ .path = "../.." },` 这一项及其上方的注释。然后把 Niobium 添加为 URL 依赖，固定到你克隆下来的那个提交：

```sh
zig fetch --save=niobium "git+https://github.com/niobium-project/niobium#$(git -C ../niobium rev-parse HEAD)"
```

`build.zig.zon` 中现在有 `niobium` 的 `.url` 和 `.hash`。务必先删除 path 项：如果它还在，`zig fetch --save` 会把 URL 写进它的 `.path` 字段，导致构建失败。

## 3. 安装发布工具和制品

`build.zig` 已经用 `niobium.addComponent` 构建了两个组件制品，并用 `niobium.addBundle` 构建了一个离线包。为了给之后的版本签名，你还需要 `nbpack` 和制品文件。在 `build` 末尾的 `b.installDirectory(...)` 之前加三行：

```zig
    b.installArtifact(niobium.nbpack(b));
    b.getInstallStep().dependOn(&b.addInstallFile(runtime, "artifacts/runtime.tar.zst").step);
    b.getInstallStep().dependOn(&b.addInstallFile(docs, "artifacts/docs.tar.zst").step);
```

构建：

```sh
zig build
```

第一次构建会编译 `setup` 和 `nbpack`，可能需要一分钟或更久。构建结果包括：

```text
zig-out/bin/nbpack                  the publisher tool
zig-out/artifacts/runtime.tar.zst   component artifacts
zig-out/artifacts/docs.tar.zst
zig-out/bundle/setup                the branded installer
zig-out/bundle/repository/          a signed TUF repository holding release 1
zig-out/bundle/licenses/
```

依次是：发布工具、组件制品、带品牌的安装程序、包含第 1 个版本的已签名 TUF 仓库，以及许可证。

## 4. 生成开发密钥

第一个离线包使用的是在构建缓存中生成的密钥，每次全新构建都会变化。生成一套你自己保留的密钥：

```sh
zig-out/bin/nbpack keygen --out keys
```

`keys/` 中每个签名角色（root、targets、snapshot、timestamp、channel）各有一个 `<role>.key.json`；在 macOS 和 Linux 上每个文件的权限为 0600。这些是开发密钥：不要提交它们，也不要用于真实发布（[签名与密钥管理](/zh/guides/sign-and-keys/)）。

在 `build.zig` 中，把它们传给 `addBundle`：在 `.artifacts = &.{ runtime, docs },` 之后加一个字段：

```zig
        .keys = b.path("keys"),
```

然后再次构建，并把已签名的仓库复制到一个你将要往里发布的目录：

```sh
zig build
cp -R zig-out/bundle/repository repo
```

`repo/` 就是你的本地仓库。`setup` 读取它的方式与读取通过 HTTP 提供的仓库完全相同。

## 5. 安装

```sh
zig-out/bundle/setup install --scope user --repo repo
```

`setup` 会打印每个阶段（`recover`、`discover`、`resolve`……`complete`），最后输出：

```text
installed com.example.hello 1.0.0 (user) in /Users/you/Library/Application Support/com.example.hello
```

检查结果并运行应用：

```sh
zig-out/bundle/setup status
"$HOME/Library/Application Support/com.example.hello/current/runtime/bin/hello"
```

```text
com.example.hello 1.0.0 (user, stable) in /Users/you/Library/Application Support/com.example.hello
Hello from the Niobium sample product.
```

在 Linux 上安装根目录是 `~/.local/share/com.example.hello`；在 Windows 上是 `%LOCALAPPDATA%\Programs\com.example.hello`，二进制文件是 `hello.exe`。

提交之后，`setup` 运行了应用的 [App Bootstrap](/zh/concepts/app-bootstrap/) 入口点。示例会把每次调用记录到 `~/.hello-bootstrap.log`，其内容现在是 `activate - 1.0.0 user`。

## 6. 发布第二个版本

在两处提升版本：

- 在 `build.zig` 中，把 `const version = "1.0.0";` 改为 `"1.1.0"`；
- 在 `product.json` 中，设置 `"version": "1.1.0"` 和 `"release_sequence": 2`。

`release_sequence` 是给发布排序的数字，每次发布都必须增大，而版本文本可以自由填写（[通道与晋升](/zh/concepts/channels/)）。重新构建制品，并把它们签名写入你的仓库：

```sh
zig build
zig-out/bin/nbpack publish --repo repo --keys keys --product product.json \
  --artifact zig-out/artifacts/runtime.tar.zst --artifact zig-out/artifacts/docs.tar.zst
```

```text
published to stable (timestamp 2)
```

再次运行同样的 `publish` 会失败，输出 `nbpack: PackSequenceNotIncreasing`，退出码为 3：一个发布序号只能使用一次。

## 7. 更新

```sh
zig-out/bundle/setup update --silent --repo repo
zig-out/bundle/setup status
```

```text
com.example.hello 1.1.0 (user, stable) in /Users/you/Library/Application Support/com.example.hello
```

引导日志新增了一行 `activate 1.0.0 1.1.0 user`。再次运行 `update` 会以 0 退出，不做任何改动。

`nbpack publish` 写入的元数据会过期：timestamp 一天后过期，其余 30 天后过期。如果你过一段时间再回到本教程，而 `update` 以退出码 4 失败，请用 `zig-out/bin/nbpack sign --repo repo --keys keys` 刷新签名。

## 8. 卸载

每个安装都会在安装根目录中保留一份 `setup` 副本，即维护程序。用它来卸载：

```sh
"$HOME/Library/Application Support/com.example.hello/maintainer/setup" uninstall --silent
```

安装根目录已被删除，引导日志的最后一行是 `deactivate 1.1.0 1.1.0 user`：应用在其文件被删除之前收到了通知。此时 `setup status` 以退出码 12（产品未安装）退出。

## 你完成了什么

你用 Niobium 构建 API 构建了一个产品，把它签名写入 TUF 仓库，安装了它，发布并应用了一次更新，然后卸载了它。每一步都经过了与真实发布相同的签名检查和事务；只有密钥是一次性的。

接下来：

- [打包你的产品](/zh/guides/package/)，编写你自己的清单和组件；
- 在第一次真实发布之前，阅读[签名与密钥管理](/zh/guides/sign-and-keys/)；
- [发布与托管](/zh/guides/publish-and-host/)，提供仓库或分发离线包。
