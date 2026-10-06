---
title: 信任模型
description: TUF 如何授权发布，以及这与操作系统代码签名有何不同。
---

Niobium 把两个问题分开。这次发布是否经发布者授权、是否是最新的、是否不比我已有的更旧？这由使用发布者密钥签名的 TUF（The Update Framework）元数据回答。操作系统是否信任这个可执行文件的发布者？这由 Authenticode 或 Apple Developer ID 等平台签名回答。前者保护更新通道；后者决定操作系统向用户显示什么。

## 用 TUF 授权发布

Niobium 仓库为五类角色保存已签名的元数据：

| 角色 | 签名的内容 | 用途 |
|---|---|---|
| root | 每个角色的密钥和阈值 | 信任锚点；嵌入在 `setup` 中 |
| targets | 每个制品和清单：长度和 SHA-256 | 究竟允许安装什么 |
| channel（`stable`、`beta`、`nightly`） | 每个通道提供哪份清单 | 发布决策，由 targets 委托 |
| snapshot | targets 和每个通道的当前版本 | 仓库的一致视图 |
| timestamp | 当前的 snapshot | 新鲜度；默认一天后过期 |

签名是对规范化 JSON 的 Ed25519 签名。`setup` 解析一次发布时会：

1. 从嵌入在其中的可信 root（或安装中记录的更新的 root）开始，逐个版本跟随 `N+1.root.json` 文件，每个文件都由新旧 root 密钥共同签名；
2. 检查 timestamp、snapshot、targets 和通道元数据：签名、阈值、过期时间，以及没有任何版本回退；
3. 下载通道所指的发布清单，并检查其长度和哈希；
4. 只接受摘要列在已签名 targets 中的制品，并在解包前检查每个下载的长度和哈希。

安装之后，已接受的版本会写入安装根目录中的 `trust/state.json`，因此之后的更新不可能被提供更旧的元数据。完整的流程在 [tuf-profile-v1](https://github.com/niobium-project/niobium/blob/main/docs/spec/tuf-profile-v1.md) 中规定。

## 发布序号与版本

每次发布都带有两个编号：

- `release_sequence`，一个正整数，在仓库中每次发布都必须严格递增。回滚保护以它为依据。
- `version`，应用的版本文本，可以下降。

把两者分开，意味着发布者在遇到有问题的发布时，可以发布一个包含较旧应用版本的新发布（更高的序号）来应对，而安装程序不会把它误认为回滚攻击。

## 平台签名

操作系统根据代码签名决定是否对一个可执行文件发出警告或阻止它运行：Windows 上是 Authenticode，macOS 上是 Developer ID 和公证。平台签名会改变二进制字节，因此必须在制品打包和计算哈希之前完成。Niobium v0.1 没有接入证书，其 `setup` 和制品都不带平台签名；这在[状态与平台](/zh/status/)上标为 DEFERRED。预期的顺序见[签名与密钥管理](/zh/guides/sign-and-keys/#platform-code-signing)。

## 信任根从哪里来

`nbpack config` 读取仓库最新的 root 元数据，并把它嵌入编译进你的带品牌 `setup` 的产品配置中。能替换你的 `setup` 下载的人就能替换信任根，因此请通过用户已经信任的渠道分发 `setup` 本身。
