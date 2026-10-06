---
title: 期望状态清单
description: 为什么 Niobium 的发布以数据描述，以及安装程序从中推导出什么。
---

Niobium 的一次发布是一份 JSON 文档，它说明机器上应该有什么，而不是怎样把它放上去。安装程序把这个期望状态与已安装的内容对比，自己规划操作。清单中的任何内容都不会被执行。

## 清单描述什么

产品清单给出产品、发布、组件及其各平台制品、要创建的操作系统集成，以及 App Bootstrap 入口点：

- **product**：反向域名形式的 `id`、显示名称 `name`、`publisher`、`version` 文本和 `release_sequence`；
- **install**：允许哪些作用域（`user`、`machine`）以及默认作用域；
- **components**：每个组件有一个 `id`、一个标题、是否必需或默认选中，以及每个平台一个制品摘要；
- **integrations**：快捷方式、文件关联和服务，每项都指向某个组件的具名入口点；
- **bootstrap**：实现 [App Bootstrap](/zh/concepts/app-bootstrap/) 的入口点；
- **experience**：强调色、许可证和欢迎文本、图标。

字段级规则见[清单参考](/zh/reference/manifest/)。

## 为什么用数据而不是脚本

安装脚本往往是安装程序出问题的地方：它们以提升的权限运行，无法回滚，还会让每个产品都变成特例。Niobium 去掉了它们：

- 每一层的未知字段都会被拒绝，`pre_install`、`post_install`、`script`、`exec`、`shell` 和 `command` 字段无论出现在哪里都会被拒绝；
- 如果清单的 `schema` 更新，或 `min_installer` 高于正在运行的安装程序，就以关闭方式失败，而不是只理解一半；
- 安装程序能对机器做的事情是一个封闭的能力集合：受管的文件和目录、快捷方式、文件关联、服务和应用注册。

需要其他操作（例如迁移数据）的产品，在安装程序完成文件部署之后，通过 App Bootstrap 在自己的进程中完成。

## 从期望状态到计划

当你运行 `setup install`、`update`、`repair` 或 `uninstall` 时，引擎会：

1. 从已签名的仓库解析出发布并验证它（[信任模型](/zh/concepts/trust/)）；
2. 把清单与你的选择（作用域、组件、安装目录）合并为期望状态；
3. 从安装根目录读取已安装状态；
4. 把两者的差异编译成一个带类型的操作计划，每个操作都有应用、回滚和验证三个步骤；
5. 以[事务](/zh/concepts/transactions/)方式执行该计划。

图形界面和命令行构造相同的请求，运行相同的引擎路径，因此在窗口中做出的选择与等价的命令会产生相同的计划。

## 文件放在哪里

框架根据作用域和产品 id 决定每一个机器路径；组件只包含相对路径。例如，macOS 上用户范围的安装位于 `~/Library/Application Support/<product id>`，Linux 上整机范围的安装位于 `/opt/<product id>`。完整的表格见[仓库与安装布局](/zh/reference/repository-layout/)。
