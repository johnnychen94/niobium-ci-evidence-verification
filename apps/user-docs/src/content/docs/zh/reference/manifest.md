---
title: 清单与组件 schema
description: 产品清单（product.json）和组件元数据（component.json）的字段。
---

权威来源：[manifest-v1](https://github.com/niobium-project/niobium/blob/main/docs/spec/manifest-v1.md) 和 [component-v1](https://github.com/niobium-project/niobium/blob/main/docs/spec/component-v1.md) 规范，以及它们的 JSON Schema [manifest-v1.schema.json](https://github.com/niobium-project/niobium/blob/main/api/schema/manifest-v1.schema.json) 和 [component-v1.schema.json](https://github.com/niobium-project/niobium/blob/main/api/schema/component-v1.schema.json)。本页是它们的摘要。

两种文档都按严格模式解析：任意层级的未知字段、重复的键和超过 32 层的嵌套都是错误，`pre_install`、`post_install`、`script`、`exec`、`shell` 和 `command` 字段无论出现在哪里都会被拒绝。

## 产品清单

| 字段 | 类型 | 规则 |
|---|---|---|
| `schema` | integer | 必须为 `1`；更高的值以关闭方式失败（退出码 11） |
| `min_installer` | string | 可以安装此发布的最旧 `setup` 版本；值更新时以退出码 11 失败 |
| `product.id` | string | 反向域名，`[a-z0-9.-]`，3 到 128 字节；决定安装目录的名称 |
| `product.name` | string | 显示名称 |
| `product.publisher` | string | 显示的发布者 |
| `product.version` | string | 应用版本（semver）；在发布之间可以下降 |
| `product.release_sequence` | integer | 至少为 1；每次发布都必须严格递增 |
| `install.default_scope` | `user` 或 `machine` | 必须是 `allowed_scopes` 之一 |
| `install.allowed_scopes` | array | 非空，取值唯一，来自 `user`、`machine` |
| `components[]` | array | 1 到 64 个组件，至少一个带有 `required: true` |
| `components[].id` | string | `[a-z0-9_-]`，1 到 64 字节，唯一；`__installer_runtime` 是保留值 |
| `components[].title` | string | 显示标题 |
| `components[].required` | boolean | 总会安装 |
| `components[].default` | boolean | 用户不选择组件时安装 |
| `components[].artifacts` | object | 键为 `<os>-<arch>`，值为 `sha256:` 加 64 个小写十六进制数字。在由 `nbpack` 填充的模板中为空 `{}` |
| `integrations.shortcuts[]` | array | `name`、`entrypoint`；最多 32 项 |
| `integrations.file_associations[]` | array | `extension`（`.` 加 1 到 16 个 `[a-z0-9]`）、`entrypoint`、`description`；最多 32 项 |
| `integrations.services[]` | array | `id`、`entrypoint`、`start`（`auto` 或 `manual`）；最多 32 项 |
| `bootstrap` | object | `entrypoint` 和 `protocol`（`1`） |
| `experience` | object | 只有 `accent`（`#RRGGBB`）、`license_text`、`welcome_text`、`icon_png`（base64 编码的 PNG，最多 256 KiB） |

平台键为 `macos-aarch64`、`macos-x86_64`、`windows-x86_64`、`windows-aarch64`、`linux-x86_64` 和 `linux-aarch64`。`entrypoint` 引用的形式是 `<component id>.<entrypoint name>`，必须指向该组件元数据中声明的入口点。整个清单的大小上限为 1 MiB。

## 组件元数据

制品中的 `component.json`：

| 字段 | 类型 | 规则 |
|---|---|---|
| `schema` | integer | `1` |
| `id` | string | 与清单中的组件 id 相同 |
| `version` | string | 由 `nbpack component build` 添加 |
| `platform` | string | `<os>-<arch>`；由 `nbpack component build` 添加；必须与引用该制品的清单键一致 |
| `entrypoints` | object | 名称（`[a-z0-9_-]`，1 到 64 字节）映射到 `{ "path": ..., "bootstrap": true? }` |
| `executables` | array | 获得可执行位的路径；归档中的权限位会被忽略 |

路径是组件文件之下经过规范化的相对路径，并且必须存在于载荷中。为 `nbpack component build` 编写 `component.json` 时，不要写 `version` 和 `platform`。

## 产品配置

`nbpack config` 写出编译进带品牌 `setup` 的配置：产品 id、通道、仓库地址、信任根、默认作用域和品牌（`product_name`、`publisher`、`accent`、`welcome_title`、`welcome_body`、`complete_body`、`license`、`logo_png`）。Schema：[product-config-v1.schema.json](https://github.com/niobium-project/niobium/blob/main/api/schema/product-config-v1.schema.json)。
