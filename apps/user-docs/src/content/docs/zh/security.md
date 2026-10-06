---
title: 安全
description: Niobium 防御什么、不防御什么，以及如何报告漏洞。
---

Niobium 的设计目标是：被攻陷的下载服务器、被篡改或重放的仓库、恶意归档文件或一次崩溃，都不能让发布者未授权的软件被安装，也不能让机器停留在更新了一半的状态。它不防御被攻陷的发布者、被攻陷的用户会话，或发布者合法签名的恶意应用。下面每项防御都注明了规范出处；是否已经验证见[状态与平台](/zh/status/)。

## 威胁模型

假定的攻击者：

- 控制网络路径、托管仓库的服务器或其镜像的人；
- 能够向用户提供精心构造的仓库、制品或离线包的人；
- 环境本身：事务进行中的断电、进程被杀、磁盘写满和文件被锁定。

假定可信的：

- 发布者的签名密钥以及用于签名的机器；
- 用户启动的 `setup` 可执行文件，包括编译在其中的信任根；
- 操作系统和管理员账户。

## 非目标

- **恶意或被攻陷的发布者。** 密钥签了什么就安装什么。请让密钥保持离线（[签名与密钥管理](/zh/guides/sign-and-keys/)）。
- **恶意的应用代码。** Niobium 验证字节正是发布者发布的那些，而不验证它们运行起来是否安全。
- **已经控制了执行安装的用户账户的攻击者。** 参见[权限边界](/zh/concepts/privilege/#what-the-boundary-does-not-cover)的剩余风险。
- **被替换的 `setup` 下载。** 信任根就在 `setup` 里；请通过用户已经信任的渠道分发它，并在平台签名可用后对其签名。
- **机密性。** 仓库和制品不加密。

## TUF 配置防御哪些攻击

| 攻击 | 防御 |
|---|---|
| 提供发布者从未发布的制品 | 只接受已签名 targets 元数据中列出的摘要；解包前检查长度和 SHA-256 |
| 伪造或篡改元数据 | Ed25519 签名，每个角色有密钥阈值 |
| 重放较旧的发布让用户降级 | `release_sequence` 和每份元数据的版本都不得回退；已接受的版本按安装分别保存 |
| 让用户停留在陈旧的元数据上 | 每个元数据文件都会过期；timestamp 默认一天后过期 |
| 混用不同仓库状态的文件 | snapshot 固定 targets 和每个通道的版本，timestamp 固定 snapshot |
| 给某个通道提供未委托给它的发布 | 通道角色只能指定 `manifests/<product id>.json`，并用被委托的密钥签名 |
| 用超大元数据耗尽内存 | 元数据文件有大小上限（timestamp 最多 16 KiB）；更大的文件以 `MetadataTooLarge` 失败 |
| 轮换到攻击者的 root | 每个新 root 必须同时由新旧 root 密钥签名，且版本恰好加一 |

由验收条目 N1-INV-05、N1-INV-06 以及 N1-AC-02 到 N1-AC-03 验证。规范：[tuf-profile-v1](https://github.com/niobium-project/niobium/blob/main/docs/spec/tuf-profile-v1.md)。

## 清单中没有代码

清单和组件元数据按严格模式解析：未知字段、重复的键、过深的嵌套和超大的文档都会被拒绝，且 `pre_install`、`post_install`、`script`、`exec`、`shell` 和 `command` 字段在任何位置都会被拒绝。不存在能让安装程序运行命令的字段（N1-INV-03、N1-AC-01）。

## 权限边界

整机范围安装使用一个短生命周期的提权助手。它只接受 `<install base>/<product id>` 内带类型的文件与系统集成操作，并带有会话认证和防重放保护。它不能运行程序、加载库或建立网络连接。细节和已接受的剩余风险见[权限边界](/zh/concepts/privilege/)（N1-INV-04）。

## 解包安全 { #extraction-safety }

制品由一个严格的解包器解包，它只能在暂存目录之下创建普通文件和目录：

- 拒绝符号链接、硬链接、设备文件和 FIFO；
- 拒绝绝对路径、盘符、反斜杠、`..` 段、控制字符以及 Windows 保留名称；
- 拒绝重复路径，包括仅大小写不同的路径；
- 条目数量、单个文件大小、总大小和压缩比都有上限，且在写入任何内容之前就按条目声明的大小计入额度。

由 N1-INV-02 和 N1-AC-04 使用逐字节构造的恶意归档验证。规范：[artifact-format-v1](https://github.com/niobium-project/niobium/blob/main/docs/spec/artifact-format-v1.md)。

## 崩溃保证

在任何时刻中断之后，下一次运行 `setup` 会恢复到旧版本或新版本，绝不会是两者的混合（[事务](/zh/concepts/transactions/)，N1-INV-01）。致命错误会写入一份崩溃记录，其中只包含版本、产品、引擎阶段、事务编号、时间和返回地址（[故障排查](/zh/troubleshooting/#logs-and-crash-records)）。

## 报告漏洞 { #report-a-vulnerability }

<!-- TODO(maintainers): keep in sync with the English page once a security policy is published. -->

Niobium 尚未发布安全策略或私密报告渠道。在此之前，请不要把漏洞细节写进公开 issue：在 [GitHub](https://github.com/niobium-project/niobium/issues) 上开一个 issue，请维护者提供私密联系方式，但不要描述问题本身。
