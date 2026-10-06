---
title: 签名与密钥管理
description: 生成 TUF 签名密钥，妥善保管，刷新即将过期的元数据，并安排平台代码签名的顺序。
---

Niobium 用你生成并保管的 TUF 密钥为每次发布签名。持有这些密钥的人就能向你的用户发布内容，所以请像对待代码签名证书一样对待它们。本指南介绍如何生成密钥、密钥可以存放在哪里、如何避免元数据过期，以及操作系统代码签名处在哪个环节。

## 生成密钥

```sh
nbpack keygen --out keys/
```

`keys/` 中会生成五个文件，每个角色一个：`root.key.json`、`targets.key.json`、`snapshot.key.json`、`timestamp.key.json` 和 `channel.key.json`。在 macOS 和 Linux 上，每个文件的权限为 0600；在 Windows 上依赖目录的访问控制。

在 v0.1 中，`nbpack keygen` 是创建密钥的唯一方式，且一次创建全部五个。第一次 `nbpack publish --init` 会把 root 公钥写入仓库；此后，如果密钥目录中的 root 密钥与仓库不匹配，`publish`、`promote` 和 `sign` 都会拒绝（`PackRootKeyMismatch`）。

## 让密钥远离构建和 CI

- 在产品构建之外、版本控制之外生成并存放密钥。本仓库 `.gitignore` 中的 `*.key.json` 模式在你自己的仓库中也是一个有用的默认设置。
- 永远不要把签名密钥交给外部 CI 或兼容性测试系统。在那里测试暂存的发布字节，在你掌控的机器上签名。
- 不带 `.keys` 的 `addBundle` 每次全新构建都会生成一次性密钥。这样签名的离线包永远无法更新由更早的离线包创建的安装。只把它用于测试和演示。

## 保持元数据新鲜

已签名的元数据会过期，以便发现陈旧或被冻结的仓库：

| 元数据 | 默认有效期 |
|---|---|
| timestamp | 1 天 |
| snapshot、targets、通道 | 30 天 |
| root | 365 天 |

客户端以退出码 4 拒绝过期的元数据。请定期重新签名；内容保持不变，版本递增：

```sh
nbpack sign --repo <repo-dir> --keys keys/
```

`publish`、`promote` 和 `sign` 都接受 `--days <n>` 和 `--timestamp-days <n>` 来修改有效期，以及 `--now <unix seconds>` 来按固定时间签名。timestamp 的有效期很短，这意味着对于希望客户端一直接受的仓库，`sign` 至少每天要运行一次。

## 轮换或恢复密钥 { #rotate-or-recover-keys }

客户端已经能验证 root 轮换：它们跟随 `N+1.root.json` 文件，每个文件都由新旧 root 密钥共同签名，因此轮换 root 不需要重新分发 `setup`。发布者一侧尚未实现：在 v0.1 中，`nbpack` 没有生成新 root 版本的命令。在它实现之前：

- 泄露的在线密钥（timestamp、snapshot 或通道）无法在不建立新仓库和新 `setup` 的情况下替换；
- 泄露的 root 密钥需要通过用户信任的渠道分发一个嵌入了新 root 的新 `setup`。

预期的流程草拟在[密钥轮换运行手册](https://github.com/niobium-project/niobium/blob/main/docs/runbooks/tuf-key-rotation.md)中。

## 平台代码签名 { #platform-code-signing }

操作系统代码签名（Windows 上的 Authenticode `signtool`；macOS 上的 Developer ID、Hardened Runtime 和公证）会改变你的二进制文件的字节。因此它必须在构建制品和计算哈希之前完成：

1. 构建你的二进制文件；
2. 用你的平台证书为它们签名；
3. 用签名后的文件构建组件制品；
4. 用 `nbpack publish` 发布它们。

在第 3 步之后再签名就太晚了：制品中已经包含未签名的二进制文件，而且由于发布按哈希引用制品，制品之后不能再更改。Niobium v0.1 尚未用真实证书执行过这一步，`addBundle` 构建的 `setup` 也没有平台签名；参见[状态与平台](/zh/status/)。完整的有序流程见[发布签名运行手册](https://github.com/niobium-project/niobium/blob/main/docs/runbooks/release-signing.md)。
