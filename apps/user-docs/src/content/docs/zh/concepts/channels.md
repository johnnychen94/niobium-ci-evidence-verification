---
title: 通道与晋升
description: 发布如何到达 stable、beta 和 nightly 用户，以及为什么晋升只改变元数据。
---

通道是一个已签名的指针，从通道名称指向某个产品的一次发布。把用户迁移到新的发布，意味着重新签名这个指针；制品永远不会被重新构建或重新打包。其背后的规则是：只构建一次，只签名一次，测试最终的字节，然后只通过元数据晋升。

## 三个通道

Niobium 有三个固定的通道：`stable`、`beta` 和 `nightly`。每个通道都是一个被委托的 TUF 角色，其唯一内容是 `manifests/<product id>.json` 以及该发布的 `release_sequence` 和应用版本。

带品牌的 `setup` 从 `nbpack config --channel` 写入的产品配置中获取通道（默认 `stable`）；命令行选项 `--channel` 可以覆盖它。每个安装都会记录它安装自哪个通道，`setup status` 会显示出来。

## 发布与晋升

- `nbpack publish ... --channel beta` 向仓库添加一次新的发布（清单和制品），并让 `beta` 指向它。不带 `--channel` 时发布到 `stable`。
- `nbpack promote --product-id <id> --sequence <n> --channel stable` 让 `stable` 指向一个已经在仓库中的发布。它只写入并签名元数据。

典型的流程是：发布到 `beta`，针对用户将收到的完全相同的字节运行兼容性测试，然后把同一个序号晋升到 `stable`。具体命令见[发布与托管](/zh/guides/publish-and-host/)。

## 排序与回滚 { #ordering-and-rollback }

在一个通道内，`release_sequence` 必须严格递增：`nbpack publish` 拒绝不大于通道当前序号的序号，`setup update` 拒绝把安装移到更低的序号。应用的 `version` 可以自由取值。

要撤回一个有问题的发布，请发布一个序号更高、包含之前那个正常应用版本的新发布。各个安装会像更新到其他任何发布一样更新到它；旧发布的任何内容都不需要删除。这条路径由[状态与平台](/zh/status/)上的验收条目 N1-UJ-04 覆盖。
