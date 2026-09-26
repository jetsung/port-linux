# WorkBuddy — 跨平台移植脚本（port-workbuddy.sh）

> 将腾讯 WorkBuddy 的 macOS 版移植到 Linux，重新打包为 **deb / rpm**。
> 参考 AUR [`workbuddy`](https://aur.archlinux.org/packages/workbuddy) 配方与
> [`forkdo/workbuddy-linux`](https://github.com/forkdo/workbuddy-linux) 的构建逻辑。
>
> 本案例是 [port-linux](../README.md) 移植工具集收录的移植方案之一。

腾讯 WorkBuddy 目前没有官方 Linux 客户端。本脚本下载（或使用本地）WorkBuddy 官方
macOS 应用资源（`WorkBuddy-darwin-x64-<ver>.zip`），解压 `app.asar`，将其中依赖
平台的 `better-sqlite3` 与 `node-pty` 替换为 Linux 构建，用 Electron Linux runtime
启动，重新打包为 deb / rpm。

## 移植原理

`port-workbuddy.sh` 自包含全部逻辑，自动完成从 macOS 源包到 deb/rpm 的全流程：

![WorkBuddy 跨平台移植流程](assets/port-flow.svg)

安装布局（deb / rpm 一致）：

```
/opt/workbuddy/
├── app.asar.unpacked/    # 解压后的应用代码（含已替换的 Linux 原生模块）
└── electron/             # Electron Linux runtime
/usr/bin/workbuddy        # 启动脚本: exec electron app.asar.unpacked
/usr/share/applications/workbuddy.desktop
/usr/share/icons/hicolor/1024x1024/apps/workbuddy.png
```

## 用法

```bash
# 最简：自动探测当前目录的 WorkBuddy-darwin-x64-*.zip，按当前 OS 打包
./port-workbuddy.sh

# 同时生成 deb 和 rpm
./port-workbuddy.sh -p all

# 显式指定源 zip
./port-workbuddy.sh -p deb WorkBuddy-darwin-x64-5.6.2.39298511-37a65c0b.zip

# 从 URL 下载源（文件名须含版本号）
./port-workbuddy.sh -s "https://download.codebuddy.cn/.../WorkBuddy-darwin-x64-5.6.2.39298511-37a65c0b.zip"

# 覆盖 Electron 版本（默认 37.10.3，与 WorkBuddy 内置 Electron Framework 对齐）
./port-workbuddy.sh -e 37.10.3
```

### 参数

| 参数 | 说明 |
|---|---|
| `-p, --platform rpm\|deb\|all` | 构建目标；省略时按当前 OS 自动检测（Fedora 系 → rpm，Debian 系 → deb） |
| `-s, --source PATH\|URL` | 源 zip：本地路径或 `http(s)://` 下载地址；省略时自动探测当前目录 `WorkBuddy-darwin-x64-*.zip` |
| `-e, --electron VERSION` | Electron runtime 版本（默认 `37.10.3`） |
| `-v, --pkgver VERSION` | 上游版本号；省略时从源文件名提取（如 `5.6.2.39298511`） |
| `<*.zip>` | 位置参数：直接传源 zip 路径（等价 `-s`） |

### 自动探测

不指定 `-s` 时，脚本在当前目录按 glob `WorkBuddy-darwin-x64-*.zip` 查找源文件。
版本号从文件名提取：`WorkBuddy-darwin-x64-5.6.2.39298511-37a65c0b.zip` →
版本 `5.6.2.39298511`，hash `37a65c0b`。

- deb `Version`: `5.6.2.39298511-37a65c0b`
- rpm `Version`/`Release`: `5.6.2.39298511` / `1.37a65c0b`

## 产物

```
build/
├── cache/   # 下载缓存（源 zip、electron、原生模块 tgz），跨次复用
├── work/    # 中间解压产物，跨次复用
└── out/     # 最终产物
    ├── workbuddy_<ver>_amd64.deb
    └── workbuddy-<ver>-1.<hash>.x86_64.rpm
```

安装：

```bash
# Debian/Ubuntu
sudo apt install ./workbuddy_*.deb

# Fedora/RHEL
sudo dnf install ./workbuddy-*.rpm
```

安装后从应用菜单启动 WorkBuddy，或终端运行 `workbuddy`。

## 依赖

```bash
# Fedora
sudo dnf install unzip tar nodejs npm curl rpm-build

# Debian/Ubuntu
sudo apt install unzip tar nodejs npm curl dpkg-dev
```

- `unzip`、`tar`：解压 zip / tgz
- `node` + `npx`：通过 `asar@3.2.0` 解压 `app.asar`
- `curl` 或 `wget`：下载源 / Electron / 原生模块
- `dpkg-deb`：打 deb（缺失则跳过 deb）
- `rpmbuild`：打 rpm（缺失则跳过 rpm）

## 来源

- 官方产品页：<https://www.workbuddy.cn/app>
- 官方更新接口：<https://copilot.tencent.com/v2/update?platform=workbuddy-darwin-x64>
- AUR 参考包：<https://aur.archlinux.org/packages/workbuddy>
- 原始构建脚本参考：[`forkdo/workbuddy-linux`](https://github.com/forkdo/workbuddy-linux)

## 已知限制

- 这是从 macOS 资源移植的非官方版本，部分依赖 macOS 的功能可能不可用。
- 上游界面更新可能使兼容补丁失效。
- 仅支持 x86_64（amd64）；arm64 需 `darwin-arm64` 源 zip 与对应原生模块。
- `process.resourcesPath` 补丁硬编码 `/opt/workbuddy`，故仅支持装到 `/opt`（deb / rpm 均如此）。

## 许可

打包脚本以 Apache 2.0 许可。WorkBuddy 应用、商标及资源归腾讯或相应权利人所有，
本项目与腾讯无隶属关系。公开分发前请确认上游条款允许。
