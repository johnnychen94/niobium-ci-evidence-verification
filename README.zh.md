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

## 文档

除用户文档网站外，其余文档均为英文。

- 用户文档（中英文）：https://niobium-project.dev/zh/
- 约定：[AGENTS.md](AGENTS.md)
- 术语：[GLOSSARY.md](GLOSSARY.md)
- 文档索引：[docs/README.md](docs/README.md)
- 路线图与延后项：[docs/roadmap-v0.1.md](docs/roadmap-v0.1.md)
- 验收状态：[docs/acceptance-plan-v0.1.md](docs/acceptance-plan-v0.1.md)

## 许可证

[MIT](LICENSE)
