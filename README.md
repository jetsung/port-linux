# Port Linux

Linux 跨平台移植工具集 —— 收集将其他平台（主要是 Windows/macOS）应用移植到 Linux 的一键脚本与教程。

## 项目简介

很多商业闭源应用只提供更新缓慢的 Linux 版本，或其 Linux 版缺少 Windows/macOS 版的最新功能。本项目收录针对这类应用的移植方案：利用 Electron 等跨平台框架的分层特性，从最新版安装包中提取跨平台业务代码，替换到 Linux 原生运行时上，并重新打包为 rpm/deb。

每个移植案例以独立子目录形式收录，包含移植脚本、流程文档与所需源包说明。

## 收录案例

| 案例 | 应用 | 移植方式 | 产物 | 文档 |
|---|---|---|---|---|
| [`mimo-desktop/`](mimo-desktop/) | Xiaomi MiMo 桌面客户端 | Linux deb + Windows exe 分层移植，内置 node-machine-id 登录修复 | rpm / deb | [README](mimo-desktop/README.md) |
| [`deveco-studio/`](deveco-studio/) | DevEco Studio（HarmonyOS IDE） | Mac DMG + Linux CLI 工具 + IntelliJ IDEA Linux 组件重组，IDEA 基线自动解析 | 跨发行版 tar.gz | [README](deveco-studio/README.md) |

## 目录约定

每个案例子目录建议包含：

```
<app>/
├── port-<app>.sh    # 一键移植脚本（自包含全部逻辑）
├── README.md        # 移植原理、用法、产物说明
└── assets/          # 流程图等资源（可选）
```

大型源安装包（`.deb` / `.rpm` / `.exe`）不纳入版本控制，由使用者按各案例 README 自行下载。

## 通用依赖

各案例脚本大同小异，通常需要：

```bash
# Fedora
sudo dnf install p7zip binutils tar nodejs rpm-build

# Debian/Ubuntu
sudo apt install p7zip-full binutils tar nodejs
```

## 许可证

[Apache License 2.0](LICENSE)
