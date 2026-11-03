# 网络规则（中国网络代理）

当环境变量 `IS_CHINA` 的值为 `1`（中国网络环境）时，在使用 WebFetch 等工具抓取网页或下载文件**之前**，必须先检查 `IS_CHINA` 的值：若为 `1` 且链接命中下方「代理域名清单」中的域名，先在其前面添加前缀 `https://filetas.asfd.cn`，**然后再执行**抓取。严禁先
发起请求、失败后再补充代理前缀。

## 代理域名清单

| 域名 | 改写示例 |
| --- | --- |
| raw.githubusercontent.com | `https://filetas.asfd.cn/https://raw.githubusercontent.com/xxx` |

后续发现其他需要走代理的域名，直接在上表末尾追加一行即可（仅填域名与示例）。

若访问未在清单中的域名或链接失败（如超时、连接被重置），可先按上述方式将该域名加入清单并加前缀 `https://filetas.asfd.cn` 后，重新抓取尝试。

# 移植脚本编写约束（port.sh）

本仓库各移植脚本（`deveco-studio/`、`mimo-desktop/`、`workbuddy/` 等）统一命名为所在目录下的 `port.sh`，并统一遵循以下约束，新增脚本时同样适用：

## 案例子目录结构

每个案例子目录建议包含：

```
<app>/
├── port.sh          # 一键移植脚本（自包含全部逻辑，统一命名）
├── README.md        # 移植原理、用法、产物说明
└── assets/
    └── port-flow.svg  # 移植流程图（统一命名）
```

- 移植流程图统一放在所在案例的 `assets/port-flow.svg`（如 `workbuddy/assets/port-flow.svg`），README 中引用该文件。
- 生成或修改 `port-flow.svg` 时，必须使用 `svg-diagram` skill（技能）来绘制 SVG 流程图，保持全仓库图形风格一致。

以方便下次创建新的软件移植。

## 0. Docker 运行环境

- 移植过程不再依赖宿主环境，统一在 Docker 容器内执行，基础镜像为 `debian:13`。
- 仓库根目录提供统一基础环境镜像 `Dockerfile`（合并各移植项目的前置依赖，预配置中国镜像源：apt 清华 TUNA、npm/bun 走 npmmirror、pip 走清华 PyPI；`WORKDIR /src`），优先使用：

```bash
docker build -t port-linux-base .
# 非中国网络环境：docker build --build-arg IS_CHINA=0 -t port-linux-base .
```

- 运行时在 `port.sh` 脚本及移植包所在路径下执行，将该目录挂载为 `/src`（镜像已设 `WORKDIR /src`，无需再传 `-w`）：

```bash
cd <项目目录>   # 例如 workbuddy/，目录内含 port.sh 与移植包
docker run --rm -it -v "$PWD":/src port-linux-base bash          # 交互式
docker run --rm -v "$PWD":/src port-linux-base ./port.sh -p deb  # 一键构建
```

- 直接使用 `debian:13` 时，若 `IS_CHINA=1`（中国网络环境），启动容器后必须先将 apt 镜像源替换为清华大学源，再执行 `apt` 相关操作：

```bash
sed -i 's|deb.debian.org|mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list.d/debian.sources
```

- 若 `IS_CHINA=1`（中国网络环境），npm 相关操作（`npm install`、`npx` 下载包等）统一使用 npmmirror 镜像源：

```bash
npm config set registry https://registry.npmmirror.com
```

- 若 `IS_CHINA=1`（中国网络环境），pip 相关操作统一使用清华大学的 PyPI 镜像源：

```bash
pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple
```

## 1. set 模式（脚本顶部）

```bash
if [[ -n "$DEBUG" ]]; then
  set -eux
else
  set -euo pipefail
fi
```

- 支持 `DEBUG=1` 调试模式，打印每条执行的命令。

## 2. CDN 加速下载

下载函数统一走 CDN 加速：`IS_CHINA=1` 且 URL 命中代理域名清单时使用 `<CDN>/<完整原始 URL>` 形式下载，失败自动回退直连。

- 默认 CDN：`https://fastfile.asfd.cn/`，可通过环境变量 `CDN=<url>` 覆盖
- `CDN` 归一化：无论传入是否带 `/` 结尾，统一归一为末尾恰好一个 `/`
- 仅对 CDN 适用域名生效（如 `github.com`、`raw.githubusercontent.com`、`objects.githubusercontent.com` 等 GitHub 系域名）；npm registry 等其他域名不走 CDN
- 仅 `IS_CHINA=1` 时启用，否则行为与直连一致

## 3. 必须提供帮助信息

- 脚本必须支持 `-h` / `--help` 查看帮助信息（独立 `usage()` 函数）
- 帮助内容包含：脚本简介、用法示例、选项说明、环境变量、依赖
- 未知选项 / 参数报错时也应先打印帮助到 stderr 再退出

## 4. workbuddy 移植构建前置依赖（debian:13）

`workbuddy/port.sh` 在 `debian:13` 容器内构建（基底 deb + macOS x64 zip 源 → 产物 deb）时，需安装以下前置依赖：

```bash
sed -i 's|deb.debian.org|mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list.d/debian.sources
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl unzip file nodejs npm
```

| 依赖 | 用途 |
| --- | --- |
| `ca-certificates` + `curl` | 基础镜像无下载器，拉取源 zip / npm tgz |
| `unzip` | 解 macOS 源 zip（`WorkBuddy-darwin-x64-*.zip`） |
| `file` | 识别 Mach-O / ELF，清理 darwin 原生模块残留 |
| `nodejs` + `npm` | 提供 `npx`，运行 `asar@3.2.0` 解压 `app.asar` |
| `dpkg-deb` | 基础镜像自带（`dpkg` 包），解 deb 基底与打 deb 产物 |

- 可选：使用 rpm 基底时另需 `apt-get install -y --no-install-recommends rpm cpio`（`rpm` 包提供 `rpm2cpio`）
- 打 rpm 产物需 `rpmbuild`，Debian 仓库不提供；容器内构建时脚本自动跳过 rpm，仅产出 deb
- npm 下载 sandbox / node-pty 等包走镜像加速：挂载宿主 `~/.npmrc`（`-v ~/.npmrc:/root/.npmrc:ro`）或设置 `NPM_CONFIG_USERCONFIG`，脚本自动读取其中的 registry

