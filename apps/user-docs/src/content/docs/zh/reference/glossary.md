---
title: 术语表
description: Niobium 文档中使用的术语。
---

项目的权威术语表（包括内部术语）是 [GLOSSARY.md](https://github.com/niobium-project/niobium/blob/main/GLOSSARY.md)。本页列出用户文档所依赖的术语，括号中是英文原文。

**活动版本（Active version）。** 安装根目录的 `current` 指针所指向的版本。它只可能是某个事务的旧版本或新版本。

**App Bootstrap（应用引导）。** 安装程序在提交之后或卸载之前，请你的应用执行它自己的迁移所用的协议。见[安装程序与 App Bootstrap](/zh/concepts/app-bootstrap/)。

**制品（Artifact）。** 由其 SHA-256 摘要标识的不可变文件。组件制品是一个包含 `component.json` 和 `files/` 的 `tar.zst`。

**能力（Capability）。** 安装程序可以对机器做的事情所构成的封闭集合中的一项：受管理的文件、目录、快捷方式、文件关联、服务和应用注册。

**通道（Channel）。** 一个已签名的指针（`stable`、`beta` 或 `nightly`），从通道名指向一个发布。

**提交（Commit）。** 把 `current` 原子地切换到新版本；事务的不可回头点。

**组件（Component）。** 一个可部署的文件单元，带有具名入口点，每个平台构建为一个制品。它不携带脚本，也不包含绝对路径。

**入口点（Entrypoint）。** 组件内的一个具名可执行文件，被系统集成、App Bootstrap 和便携运行以 `<component>.<name>` 的形式引用。

**维护程序（Maintainer）。** 保存在安装根目录 `maintainer/` 中的 `setup` 副本，用于之后的更新、修复和卸载。

**清单（Manifest）。** 一个发布的 JSON 描述：产品、组件、制品、系统集成、引导。

**离线包（Offline bundle）。** 包含 `setup` 和完整仓库的目录，无需网络即可安装。

**便携运行（Portable Run）。** 从经过验证、按内容寻址的缓存中运行组件而不安装它（`setup run`）。

**产品（Product）。** 用户安装的对象：一组组件，带有 `com.example.hello` 这样的 id。

**恢复（Recovery）。** `setup` 在做任何其他事情之前运行的步骤，它完成或回滚被中断的事务。

**发布序号（Release sequence）。** `release_sequence`，为发布排序并防止回滚的整数，与应用版本无关。

**仓库（Repository）。** 由 `nbpack` 写入、由 `setup` 读取的已签名 TUF 元数据和按内容寻址的文件。

**作用域（Scope）。** `user`（为一个用户安装，无需提权）或 `machine`（为所有用户安装，需要管理员权限）。

**暂存（Staging）。** 新版本在成为活动版本之前被解包到的目录。

**事务（Transaction）。** 一次安装、更新、修复或卸载，记录在日志中，从而结束于旧版本或新版本。

**TUF。** The Update Framework，Niobium 仓库签名所遵循的规范。见[信任模型](/zh/concepts/trust/)。
