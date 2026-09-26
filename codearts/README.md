# CodeArts — 跨平台移植脚本（port-codearts.sh）

> 将华为云 CodeArts 桌面智能体移植到 Linux，重新打包为 **deb / rpm**。
> 上游仅提供 macOS (arm64 zip) / Windows (x64 NSIS exe)，无 Linux 版。
>
> 本案例是 [port-linux](../README.md) 移植工具集收录的移植方案之一。

华为云 CodeArts 桌面智能体（AI 开发助手，**非** VSCode fork，与本仓库
[`codearts-agent/`](../codearts-agent/) 是两个不同产品）目前没有官方 Linux
客户端。本脚本下载（或使用本地）macOS 应用资源（`CodeArts-<ver>-arm64.zip`），
解压 `app.asar`，清理 darwin 原生模块，用 Electron Linux runtime 启动，
重新打包为 deb / rpm。

## 移植原理

`port-codearts.sh` 自包含全部逻辑，自动完成从 macOS 源包到 deb/rpm 的全流程：

![CodeArts 跨平台移植流程](assets/port-flow.svg)

应用为 Electron 39.3.0 架构：

```
CodeArts-<ver>-arm64.zip
  └─ CodeArts.app/Contents/Resources/
       ├─ app.asar                (平台无关 JS 业务代码，~218MB)
       ├─ app.asar.unpacked/      (asar 外置文件 + mcp-servers)
       ├─ icon.icns               (应用图标 → 转 hicolor PNG)
       └─ bin/                    (agent-kernel / officecli，darwin-arm64 平台绑定)
+
Electron v<ver>-linux-x64.zip      (Linux 原生 runtime)
  └─ /opt/codearts/electron/
=
/opt/codearts/
├── app/                           # 解压后的应用代码
├── app.asar.unpacked/             # asar 外置文件（与 app 同层，按 Electron 约定识别）
└── electron/                      # Electron Linux runtime
/usr/bin/codearts                  # 启动脚本: exec electron app/
/usr/share/applications/codearts.desktop
/usr/share/icons/hicolor/<尺寸>/apps/codearts.png
/usr/share/pixmaps/codearts.png    # 兜底图标
```

## 用法

```bash
# 最简：自动探测当前目录 CodeArts-*.zip，按当前 OS 打包
./port-codearts.sh

# 同时生成 deb 和 rpm
./port-codearts.sh -p all

# 显式指定源 zip
./port-codearts.sh -p deb CodeArts-0.1.26-arm64.zip

# 覆盖 Electron 版本（默认 39.3.0，与 CodeArts 内置 Electron Framework 对齐）
./port-codearts.sh -e 39.3.0
```

### 参数

| 参数 | 说明 |
|---|---|
| `-p, --platform rpm\|deb\|all` | 构建目标；省略时按当前 OS 自动检测（Fedora 系 → rpm，Debian 系 → deb） |
| `-s, --source PATH\|URL` | 源 zip：本地路径或 `http(s)://` 下载地址；省略时自动探测当前目录 `CodeArts-*.zip` |
| `-e, --electron VERSION` | Electron runtime 版本（默认 `39.3.0`） |
| `<*.zip>` | 位置参数：直接传源 zip 路径（等价 `-s`） |

### 版本提取

版本号从文件名提取：`CodeArts-0.1.26-arm64.zip` → `0.1.26`（打包时以
`app.asar` 内 `package.json` 的 `version` 为准，两者一致）。

## 产物

```
build/
├── cache/   # 下载缓存（源 zip、Electron），跨次复用
├── work/    # 中间解压产物，跨次复用
└── out/
    ├── codearts_<ver>_amd64.deb
    └── codearts-<ver>-1.fc<NN>.x86_64.rpm
```

安装：

```bash
# Debian/Ubuntu
sudo apt install ./codearts_*.deb

# Fedora/RHEL
sudo dnf install ./codearts-*.rpm
```

安装后从应用菜单启动 CodeArts，或终端运行 `codearts`。

## 依赖

```bash
# Fedora
sudo dnf install unzip tar nodejs npm curl python3 rpm-build

# Debian/Ubuntu
sudo apt install unzip tar nodejs npm curl python3 dpkg-dev
```

- `unzip`、`tar`：解压 zip
- `node` + `npx`：通过 `asar@3.2.0` 解压 `app.asar`；读版本号
- `python3`：icns → PNG 图标转换
- `curl` 或 `wget`：下载 Electron
- `dpkg-deb`：打 deb（缺失则跳过 deb）
- `rpmbuild`：打 rpm（缺失则跳过 rpm）

## 来源

- 官方产品页：<https://www.huaweicloud.com/product/codearts.html>
- Windows 安装包为 NSIS 双层压缩（外层 exe → `$PLUGINSDIR/app-64.7z`），
  Linux 下可用 `7z` 两级解包提取 `app.asar` 对照验证

## 已知限制

- **智能体（agent-kernel）与 officecli 功能不可用**：这两个原生 sidecar
  上游只发布了 `darwin-arm64`（mac zip）与 `win32-x64`（NSIS exe 内
  `agent-kernel.exe` / `officecli.exe`）两个平台版本，无 linux-x64 产物，
  移植包中已跳过。IDE 界面与 MCP 服务（纯 JS 的 `app.asar.unpacked/out/mcp-servers/`）
  可正常使用。
- darwin 原生 `.node` 模块无 Linux 替代，已移除（脚本日志会标注清单）。
- 上游界面更新可能使兼容补丁失效。
- 仅支持 x86_64（amd64）。
- `process.resourcesPath` 类补丁未做：本应用未发现硬编码 macOS 资源路径；
  若后续版本出现，可参考 [`workbuddy/`](../workbuddy/) 的 sed 补丁方式。

## 许可

打包脚本以 Apache 2.0 许可。CodeArts 应用、商标及资源归华为或相应权利人所有，
本项目与华为无隶属关系。公开分发前请确认上游条款允许。
