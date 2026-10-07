# Niobium

[![codecov](https://codecov.io/gh/niobium-project/niobium/graph/badge.svg)](https://codecov.io/gh/niobium-project/niobium)

[English](README.md) | 简体中文

用 Zig 实现的 native、declarative、transactional 安装与分发框架：一个小而可审计的部署 substrate，语义被刻意限制。

- **Manifest 是数据，不是代码**：没有 pre/post install 脚本，没有 exec。
- **事务化**：任意时刻崩溃后只会恢复到旧版本或新版本。
- **TUF 信任**：发布授权、新鲜度与反回滚；`release_sequence` 与应用版本分离。
- **Library-first**：GUI、CLI 与 C ABI 共用同一个 engine。
- **自有 UI**：封闭组件词汇 + tokens + 软件渲染器，嵌入 AppKit / Win32 / X11 原生窗口。

## 快速开始

需要 Zig 0.17.0。

```sh
zig build                 # 主机二进制：zig-out/bin/setup、nbpack
zig build test            # 单元测试
zig build verify          # 完成定义门禁（check + test + sim + golden + e2e + example + cross + size-gate）
zig build gallery         # UI 组件画廊 PNG → .evidence/ui-gallery/
```

拉取请求在 GitHub Actions 上运行。必需检查是 `CI / linux`。代码变更还会运行 `zig build test` 与 `zig build c-smoke`；完整的 `zig build verify` 在 `main` 有新提交时每天运行一次。详见 [testing lanes](docs/development/testing-lanes.md)。

## 示例产品

`examples/hello` 是依赖本仓库的独立 Zig 包，构建方式与其他产品仓库相同（[在其他仓库中使用 Niobium](docs/development/consuming.md)）。

```sh
zig build example                                        # 离线包：zig-out/example/
zig-out/example/setup install --silent --scope user
zig-out/example/setup status --json
```

## 路线图

✅ 0.1 中已提供 · 🚧 正在开发，按优先级排列 · 🔜 接下来 · 🗓️ 之后 · ⛔ 不在计划内。验证结果见[状态与平台](apps/user-docs/src/content/docs/zh/status.md)。

| 状态 | 功能 |
|---|---|
| ✅ | 在线和离线安装 |
| ✅ | 发布通道（`stable`、`beta`、`nightly`） |
| ✅ | 以事务方式安装、更新、修复和卸载 |
| ✅ | 安全回滚 |
| ✅ | 便携运行 |
| ✅ | 通过 C ABI 在应用内部更新 |
| 🚧 1 | 内置功能模块 |
| 🚧 2 | 用于快速构建安装程序的预设和主题 |
| 🚧 3 | 在 macOS、Windows 和 Linux 上可用于生产环境：真实系统测试、整机范围安装、操作系统代码签名 |
| 🚧 4 | 更容易上手：预构建的下载包和稳定的构建 API |
| 🚧 5 | 更多系统集成：`myapp://` 链接、`PATH` 和环境变量 |
| 🚧 6 | 适用于任何应用的应用内更新，首先提供 Electron 和 Node.js |
| 🔜 | 与发布一起签名的“新功能说明” |
| 🔜 | 登录时启动 |
| 🔜 | 通过 `nbpack` 轮换密钥 |
| 🔜 | 带私密报告渠道的安全策略 |
| 🗓️ | 屏幕阅读器支持 |
| 🗓️ | Linux 上的原生文件夹选择器 |
| 🗓️ | 以用户的语言显示安装程序窗口 |
| 🗓️ | 更多平台：ARM 版 Windows、麒麟、统信 |
| ⛔ | 安装脚本、自定义动作、插件和运行时扩展 |
| ⛔ | 以管理员权限运行任意命令 |
| ⛔ | 单文件自解压安装程序 |
| ⛔ | 原生 Wayland 后端 |

每项功能对你意味着什么、为什么不做 ⛔ 项：[路线图](apps/user-docs/src/content/docs/zh/roadmap.md)。

## 背景

Niobium 是一个独立的开源安装程序框架，由作者利用业余时间维护。它源于作者在同元软控工作时遇到的安装程序需求，并以通用框架为设计目标。本项目独立维护，不受同元软控的直接支持或方向指导。维护以尽力而为为原则，平台范围保持精简：参见 [About the project](apps/user-docs/src/content/docs/about.md) 与 [Platform support](apps/user-docs/src/content/docs/platforms.md)。

## 文档

除用户文档网站外，其余文档均为英文。

- 用户文档（中英文）：https://niobium-project.dev/zh/
- 功能路线图：[路线图](apps/user-docs/src/content/docs/zh/roadmap.md)
- 平台分级与路线图：[Platform support](apps/user-docs/src/content/docs/platforms.md)
- 约定：[AGENTS.md](AGENTS.md)
- 术语：[GLOSSARY.md](GLOSSARY.md)
- 文档索引：[docs/README.md](docs/README.md)
- 开发路线图与延后项：[docs/roadmap-v0.2.md](docs/roadmap-v0.2.md)
- 验收状态：[docs/acceptance-plan-v0.1.md](docs/acceptance-plan-v0.1.md)

## 许可证

[MIT](LICENSE)
