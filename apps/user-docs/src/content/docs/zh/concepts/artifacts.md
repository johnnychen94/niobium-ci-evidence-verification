---
title: 制品与便携运行
description: 不可变的组件制品、它们如何被标识，以及不安装就运行一个组件。
---

制品是一个由其 SHA-256 摘要标识的不可变文件。一旦某次发布引用了一个摘要，其背后的字节就永远不能改变；新的构建就是新的制品。正因如此，Niobium 可以测试它之后实际发布的那些字节，并在通道之间晋升一次发布而无需重新构建。

## 组件制品

组件是一个可部署的单元：一组文件加上若干具名入口点。它的制品是一个布局固定的 `tar.zst` 文件：

```text
component.json      metadata: id, version, platform, entrypoints, executables
files/...           everything that is installed under current/<component>/
```

`component.json` 是元数据（id、版本、平台、入口点、可执行文件）；`files/` 下是安装到 `current/<component>/` 之下的全部内容。

条目经过排序，时间戳和属主都被清零，因此相同的输入会产生相同的字节。一个制品只针对一个平台构建（`macos-aarch64`、`windows-x86_64` 等）；在三个平台上发布的组件有三个制品。

组件不携带安装脚本，也不拥有任何绝对路径。哪个文件可执行由 `component.json` 中的 `executables` 列表决定，而不是由归档中存储的权限位决定。

## 制品如何获得信任

发布清单在每个平台键下以 `sha256:<digest>` 列出每个制品，已签名的 TUF targets 元数据列出同一个摘要及其长度。安装程序下载制品，检查长度和摘要，然后才用一个严格的解包器解包；该解包器拒绝链接、设备文件、不安全的路径和压缩炸弹（[安全](/zh/security/#extraction-safety)）。

## 便携运行 { #portable-run }

有些工具不需要安装。`setup run <product>:<component>.<entrypoint>` 通过同一个已签名的仓库解析发布，把组件解包到一个按用户划分、按内容寻址的缓存中并运行它，而不创建安装根目录：

```sh
setup run com.example.hello:runtime.main --repo repo -- --some-argument
```

缓存的组件按摘要复用，因此第二次运行不会再次下载；每次运行都会删除 30 天内未使用的缓存条目。程序的退出码原样返回。

便携运行、已安装的应用和嵌入式更新是相互独立的配置：一个配置允许做的事，另一个配置不会继承。面向 Electron 宿主的嵌入式更新配置在 v0.1 中尚未实现。

## 离线包

离线包是一个目录，而不是自解压归档：`setup` 旁边放着已签名仓库的完整副本。`setup` 会找到与它并列的 `repository/`，并以验证在线仓库完全相同的方式验证它。参见[发布与托管](/zh/guides/publish-and-host/#ship-an-offline-bundle)。
