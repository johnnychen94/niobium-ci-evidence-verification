---
title: 发布与托管
description: 创建仓库，在通道上发布和晋升发布版本，通过 HTTP 提供仓库，以及分发离线包。
---

Niobium 仓库是一个存放已签名元数据和按内容寻址文件的目录。你只需创建一次，之后用 `nbpack` 把每次发布写入其中，然后通过 HTTP 提供它，或把它复制进离线包。本指南假定你已有组件制品（[打包](/zh/guides/package/)）和密钥（[签名与密钥管理](/zh/guides/sign-and-keys/)）。

## 用第一次发布创建仓库

```sh
nbpack publish --init --repo repo/ --keys keys/ --product product.json \
  --artifact runtime-macos-aarch64.tar.zst --artifact runtime-windows-x86_64.tar.zst
```

`--init` 根据你的密钥创建 root 元数据；如果目录中已有仓库则失败。`build.zig` 中的 `addBundle` 在每次构建时都为一个全新的仓库做同样的事；对于你要长期保留的仓库，请像这里一样自己运行 `publish`。

## 发布后续版本

在 `product.json` 中提升 `product.release_sequence`（通常还有 `product.version`），构建制品，然后：

```sh
nbpack publish --repo repo/ --keys keys/ --product product.json \
  --artifact runtime-macos-aarch64.tar.zst --artifact runtime-windows-x86_64.tar.zst \
  --channel beta
```

- `--channel` 可以是 `stable`（默认）、`beta` 或 `nightly`。
- `--version <x.y.z>` 和 `--sequence <n>` 覆盖 `product.json` 中的值。
- `publish` 拒绝不大于通道当前序号的序号（`PackSequenceNotIncreasing`，退出码 3）。

`publish` 组合出发布清单（填入每个组件的制品摘要），把清单和制品存放在 `targets/<sha256>` 下，先签名通道和 targets 元数据，再签名 snapshot，最后写入 `timestamp.json`。如果只想生成清单而不签名任何东西，使用 `nbpack product compose --product product.json --artifact ... --out manifest.json`。

## 晋升一次发布

在 `beta` 上测试过字节之后，让 `stable` 指向同一次发布：

```sh
nbpack promote --repo repo/ --keys keys/ --product-id com.example.hello --sequence 3 --channel stable
```

`promote` 只重写并重新签名元数据；不重新构建或重新打包任何东西（[通道与晋升](/zh/concepts/channels/)）。

## 让 setup 指向仓库 { #point-setup-at-the-repository }

`setup` 需要知道仓库地址，并信任其 root。两者都会编译进带品牌的 `setup`：

```sh
nbpack config --repo repo/ --product product.json --branding branding.json \
  --repository https://dl.example.com/hello --channel stable --out product-config.json
```

用该配置构建 `setup`：在你的 `build.zig` 中使用 `addSetup(b, target, config)`，或在 Niobium 检出目录中使用 `zig build -Dproduct-config=product-config.json`。在 `addBundle` 中，`repository_url` 选项会替你传入 `--repository`。

`setup` 按以下顺序选择仓库：`--repo` 选项，然后是 `setup` 可执行文件旁边的 `repository/` 目录，然后是其配置中的地址。如果三者都没有，`install`、`update` 和 `repair` 会以用法错误（退出码 2）停止。

## 通过 HTTP 提供

把仓库目录作为静态文件上传；HTTP 布局就是目录布局。由于 `timestamp.json` 是指向其他一切的入口，请先上传 `metadata/` 和 `targets/` 下的新文件，最后替换 `timestamp.json`，与 `nbpack` 写入它们的顺序相同。永远不要在服务器上直接编辑文件：每一次变更都通过 `nbpack` 完成，然后重新上传。

请记住，timestamp 默认一天后过期：至少要以这个频率运行 `nbpack sign` 并上传结果。

## 分发离线包 { #ship-an-offline-bundle }

离线包是一个目录，其中包含 `setup`、仓库的完整副本和字体许可证：

```sh
nbpack bundle --repo repo/ --setup zig-out/bin/setup --out Hello-1.2.0-offline/
```

`--out` 必须是空目录。然后把 Inter 的许可证（由 Niobium 构建获取）复制到 `Hello-1.2.0-offline/licenses/Inter-OFL.txt`。`addBundle` 会生成包含许可证在内的完整目录，即 `Bundle.dir`。

在目标机器上，`setup install` 使用随包附带的 `repository/` 和嵌入在 `setup` 中的 root，验证方式与在线时相同。离线包中的元数据与其他元数据一样会过期，因此签名仓库时请使用能覆盖离线包预期使用期的有效期（`--days`、`--timestamp-days`）；`addBundle` 对两者都使用 365 天。该流程也记录在[离线包运行手册](https://github.com/niobium-project/niobium/blob/main/docs/runbooks/offline-bundle.md)中。
