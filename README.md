# Port Linux

Linux 跨平台移植工具集 —— 收集将其他平台（主要是 Windows/macOS）应用移植到 Linux 的一键脚本与教程。

## 项目简介

很多商业闭源应用只提供更新缓慢的 Linux 版本，或其 Linux 版缺少 Windows/macOS 版的最新功能。本项目收录针对这类应用的移植方案：利用 Electron 等跨平台框架的分层特性，从最新版安装包中提取跨平台业务代码，替换到 Linux 原生运行时上，并重新打包为 rpm/deb（或跨发行版 tar.gz）。

每个移植案例以独立子目录形式收录，包含移植脚本、流程文档与所需源包说明。

## 收录案例

| 案例 | 应用 | 移植方式 | 产物 | 文档 |
|---|---|---|---|---|
| [`mimo-desktop/`](mimo-desktop/) | Xiaomi MiMo 桌面客户端 | Linux deb + Windows exe 分层移植，内置 node-machine-id 登录修复 | rpm / deb | [README](mimo-desktop/README.md) |
| [`deveco-studio/`](deveco-studio/) | DevEco Studio（HarmonyOS IDE） | Mac DMG + Linux CLI 工具 + IntelliJ IDEA Linux 组件重组，IDEA 基线自动解析 | 跨发行版 tar.gz | [README](deveco-studio/README.md) |
| [`workbuddy/`](workbuddy/) | 腾讯 WorkBuddy（AI Agent 办公工具） | 基底合并：官方 Linux deb 为基底（rpm 兼容），合并 macOS 新版 zip 的 app.asar，复用基底 Electron runtime 与 Linux 原生模块 | deb / rpm | [README](workbuddy/README.md) |
| [`codearts/`](codearts/) | 华为云 CodeArts 桌面智能体 | macOS zip 解压 app.asar + Electron Linux runtime；agent-kernel 从 CodeArts IDE Linux deb 提取并经 wrapper 协议转接 | deb / rpm (x64) | [README](codearts/README.md) |

> **⚠️ 状态说明**：`codearts/` 的智能体功能依赖华为的 agent-kernel 原生二进制。
> 桌面端上游无 Linux 构建，但可从 CodeArts IDE 的官方 Linux deb
> （`codearts-agent-linux-x64-*.deb`，内含 `agentkernelServer-linux-x64`）中提取，
> 经脚本 `-k` 指定后随移植包安装；缺失时仅界面可用、聊天功能不可用。
> officecli 等部分原生 sidecar 仍无 linux-x64 产物。详见该 README 的「已知限制」。

各案例 README 均配有 SVG 移植流程图（`assets/port-flow.svg`），可先看图了解整体移植思路。

## 目录约定

每个案例子目录建议包含：

```
<app>/
├── port-<app>.sh    # 一键移植脚本（自包含全部逻辑）
├── README.md        # 移植原理、用法、产物说明
└── assets/          # 流程图等资源（可选）
```

大型源安装包（`.deb` / `.rpm` / `.exe` / `.zip` / `.dmg`）不纳入版本控制，由使用者按各案例 README 自行下载。

## 通用依赖

> 移植过程统一在 Docker 容器内执行（基础镜像 `debian:13`，中国网络环境先替换 apt
> 源为清华大学源），不依赖宿主环境。各案例在容器内需安装的前置依赖清单见
> [`AGENTS.md`](AGENTS.md)，容器内一键构建命令见各案例 README 的「构建」一节。

本地直跑时，各案例脚本大同小异，通常需要（按案例取舍）：

```bash
# Fedora
sudo dnf install unzip p7zip bsdtar jq tar binutils nodejs npm curl python3 rpm-build

# Debian/Ubuntu
sudo apt install unzip p7zip-full bsdtar jq tar binutils nodejs npm curl python3 dpkg-dev
```

- `unzip` / `p7zip` / `bsdtar`：解压 zip / exe / DMG（`bsdtar` 用于必须保留符号链接的场景）
- `node` + `npx`：通过 `asar@3.2.0` 解压 `app.asar`
- `python3`：icns → PNG 图标转换
- `curl` 或 `wget`：下载源包与运行时
- `ar`（`binutils`）：从官方 deb 提取原生二进制
- `dpkg-deb`：打 deb（缺失时降级用 `ar` + `xz` 手工拼装，二者皆缺才跳过 deb）
- `rpmbuild`：打 rpm（缺失则跳过 rpm）

具体以各案例 README 的「依赖」一节为准；容器内构建的前置依赖以 [`AGENTS.md`](AGENTS.md) 为准。

## 许可证

[Apache License 2.0](LICENSE)
