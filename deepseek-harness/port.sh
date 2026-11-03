#!/usr/bin/env bash
# port.sh — 将 DeepSeek Harness 桌面客户端移植到 Linux x64（deb / rpm）
#
# 上游仅提供 macOS（arm64 / x64 DMG）与 Windows（x64 NSIS exe）安装包，无 Linux 版；
# 本脚本固定以 macOS arm64 DMG 为唯一源包。
# 应用为 Electron 44.7.0 外壳 + 内置 dsh 运行时：
#   1. 解包 macOS arm64 DMG，取得 app.asar、app.asar.unpacked、runtime 与图标
#   2. 解压 app.asar 为目录直接运行（不重打包 asar）
#   3. 把 darwin-arm64 平台包替换为 Linux x64 等价包，node-pty 本机编译，
#      LibreOffice 引擎降级为 WASM
#   4. 自建 primary-runtime（Node / pnpm / CPython + wheels）
#   5. Electron linux-x64 runtime 启动，重打包 deb（可选 rpm）
#
# 用法:
#   ./port.sh                 # 自动探测当前目录源包，按当前 OS 打包
#   ./port.sh -p deb          # 只打 deb
#   ./port.sh -s dsh-latest-macos-arm64.dmg
#
# 依赖: 7z, unzip, tar, node, npx, python3, curl/wget; 打 deb 需 dpkg-deb（缺失时降级 ar + xz）; 打 rpm 需 rpmbuild

usage() {
  cat <<'EOF'
port.sh — 将 DeepSeek Harness 桌面客户端移植到 Linux x64（deb / rpm）

上游仅提供 macOS（DMG）与 Windows（NSIS exe）安装包，无 Linux 版。
本脚本仅以 macOS arm64 DMG 为源：解包后提取平台无关的应用代码，替换
平台绑定的原生模块与内置 primary-runtime，用 Electron linux-x64 启动并重打包。

用法:
  ./port.sh                    # 自动探测当前目录源包，按当前 OS 打包
  ./port.sh -p deb             # 只打 deb
  ./port.sh -p all             # 同时打 deb 和 rpm
  ./port.sh -s ./dsh-latest-macos-arm64.dmg
  ./port.sh -e 44.7.0 ./dsh-latest-macos-arm64.dmg

选项:
  -p, --platform deb|rpm|all   构建目标；省略时按当前 OS 自动检测
  -s, --source PATH|URL        源安装包（macOS arm64 .dmg）：本地路径或下载地址；
                               省略时自动探测当前目录 dsh-*.dmg（arm64 优先）
  -e, --electron VERSION       Electron runtime 版本（默认 44.7.0）
  -h, --help                   显示本帮助

环境变量:
  DEBUG=1                      调试模式（set -eux，打印每条命令）
  IS_CHINA=1                   中国网络环境：GitHub 系域名走 CDN 加速，
                               npm 走镜像，pip 走清华源
  CDN=<url>                    CDN 前缀地址（默认 https://fastfile.asfd.cn/）
  NPM_CONFIG_USERCONFIG        npm 配置文件路径（默认 ~/.npmrc）
  NPM_CONFIG_REGISTRY          npm 镜像地址（~/.npmrc 未配置 registry 时使用）
  PIP_INDEX_URL                PyPI 镜像地址（IS_CHINA=1 时默认清华源）

依赖: 7z, unzip, tar, node, npx, python3, curl 或 wget；打 deb 需 dpkg-deb
      （缺失时降级用 binutils 的 ar + xz）；打 rpm 需 rpmbuild；编译 node-pty
      需 g++ 与 make
EOF
}

if [[ -n "${DEBUG:-}" ]]; then
  set -eux
else
  set -euo pipefail
fi

# ---------- 常量 ----------
APP_NAME="deepseek-harness"
APP_TITLE="DeepSeek Harness"
INSTALL_DIR="/opt/${APP_NAME}"
ELECTRON_VERSION="${ELECTRON_VERSION:-44.7.0}"
SKILL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="${BUILD_ROOT:-${SKILL_DIR}/build}"
CACHE_DIR="${BUILD_ROOT}/cache"
WORK_DIR="${BUILD_ROOT}/work"
OUT_DIR="${BUILD_ROOT}/out"

# ---------- 颜色输出 ----------
C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'; C_NC='\033[0m'
info() { echo -e "${C_GREEN}[信息]${C_NC} $*"; }
warn() { echo -e "${C_YELLOW}[警告]${C_NC} $*"; }
step() { echo -e "${C_BLUE}[步骤]${C_NC} $*"; }
die()  { echo -e "${C_RED}[失败]${C_NC} $*" >&2; exit 1; }

# ---------- 降级项收集 ----------
DEGRADATIONS=()
degrade() { DEGRADATIONS+=("$*"); warn "$*"; }

# ---------- 依赖检查 ----------
check_deps() {
  local missing=()
  for cmd in 7z unzip tar node npx python3; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    missing+=("curl|wget")
  fi
  if (("${#missing[@]}" > 0)); then
    usage >&2
    die "缺少依赖命令: ${missing[*]}"
  fi
}

# ---------- CDN 加速（IS_CHINA=1 时启用，仅对 GitHub 系域名生效） ----------
CDN_URL="${CDN:-https://fastfile.asfd.cn}"
CDN_URL="${CDN_URL%% }"
CDN_URL="${CDN_URL%*/}/"

is_china() { [[ "${IS_CHINA:-}" == "1" ]]; }

cdn_applicable() {
  case "$1" in
    https://github.com/* | https://raw.githubusercontent.com/* | https://objects.githubusercontent.com/*) return 0 ;;
    *) return 1 ;;
  esac
}

# download <url> <dest>：优先 CDN，失败回退直连；已存在且非空则复用
download() {
  local url="$1" dest="$2" tmp
  if [[ -s "$dest" ]]; then
    info "复用缓存: $(basename "$dest")"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  tmp="${dest}.part"
  rm -f "$tmp"
  if is_china && cdn_applicable "$url"; then
    info "CDN 下载: $url"
    if curl -fL --retry 2 --connect-timeout 15 -o "$tmp" "${CDN_URL}${url}"; then
      mv "$tmp" "$dest"
      return 0
    fi
    warn "CDN 下载失败，回退直连: $url"
    rm -f "$tmp"
  fi
  info "下载: $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 20 -o "$tmp" "$url" || { rm -f "$tmp"; die "下载失败: $url"; }
  else
    wget -O "$tmp" "$url" || { rm -f "$tmp"; die "下载失败: $url"; }
  fi
  mv "$tmp" "$dest"
}

# ---------- npm 镜像（优先 ~/.npmrc 的 registry） ----------
NPM_REGISTRY=""
NPM_MIRROR_SRC=""
NPMRC_FILE="${NPM_CONFIG_USERCONFIG:-$HOME/.npmrc}"
if [[ -f "$NPMRC_FILE" ]]; then
  configured_registry=$(sed -n 's/^[[:space:]]*registry[[:space:]]*=[[:space:]]*//p' "$NPMRC_FILE" | head -1)
  if [[ "$configured_registry" == http://* || "$configured_registry" == https://* ]]; then
    NPM_REGISTRY="${configured_registry%/}"
    NPM_MIRROR_SRC="$NPMRC_FILE"
  fi
fi
if [[ -z "$NPM_REGISTRY" && -n "${NPM_CONFIG_REGISTRY:-}" ]]; then
  NPM_REGISTRY="${NPM_CONFIG_REGISTRY%/}"
  NPM_MIRROR_SRC="环境变量 NPM_CONFIG_REGISTRY"
fi
if [[ -n "$NPM_REGISTRY" ]]; then
  export NPM_CONFIG_REGISTRY="$NPM_REGISTRY"
  info "npm 镜像: $NPM_REGISTRY (来自 $NPM_MIRROR_SRC)"
else
  NPM_REGISTRY="https://registry.npmjs.org"
fi

# ---------- pip 镜像（IS_CHINA=1 默认清华源） ----------
PIP_INDEX="${PIP_INDEX_URL:-}"
if [[ -z "$PIP_INDEX" ]] && is_china; then
  PIP_INDEX="https://pypi.tuna.tsinghua.edu.cn/simple"
fi

# ---------- 平台自动检测 ----------
detect_platform() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-} ${ID_LIKE:-}" in
      *fedora* | *rhel* | *centos* | *suse*) echo rpm; return ;;  # opensuse 亦匹配 *suse*
      *debian* | *ubuntu*) echo deb; return ;;
    esac
  fi
  if command -v dpkg-deb >/dev/null 2>&1; then echo deb
  elif command -v rpmbuild >/dev/null 2>&1; then echo rpm
  else echo deb; fi
}

# ---------- 参数解析 ----------
BUILD_TARGET=""
SOURCE_REF=""

while (($# > 0)); do
  case "$1" in
    -p | --platform)
      (($# >= 2)) || { usage >&2; die "选项 $1 缺少参数"; }
      BUILD_TARGET="$2"; shift 2 ;;
    -s | --source)
      (($# >= 2)) || { usage >&2; die "选项 $1 缺少参数"; }
      SOURCE_REF="$2"; shift 2 ;;
    -e | --electron)
      (($# >= 2)) || { usage >&2; die "选项 $1 缺少参数"; }
      ELECTRON_VERSION="$2"; shift 2 ;;
    -h | --help)
      usage; exit 0 ;;
    --)
      shift; break ;;
    -*)
      usage >&2; die "未知选项: $1" ;;
    *)
      [[ -z "$SOURCE_REF" ]] || { usage >&2; die "多余参数: $1"; }
      SOURCE_REF="$1"; shift ;;
  esac
done

case "$BUILD_TARGET" in
  "" ) BUILD_TARGET="$(detect_platform)" ;;
  deb | rpm | all ) ;;
  * ) usage >&2; die "无效的构建目标: $BUILD_TARGET（可选 deb|rpm|all）" ;;
esac

check_deps

# ---------- 目录初始化 ----------
mkdir -p "$CACHE_DIR" "$WORK_DIR" "$OUT_DIR"

# ---------- npm 包获取与平台包替换 ----------
install_npm_pkg() {
  local name="$1" ver="$2" dest="$3"
  local base="${name##*/}"
  local tgz="$CACHE_DIR/npm/${base}-${ver}.tgz"
  if [[ ! -s "$tgz" ]]; then
    mkdir -p "$(dirname "$tgz")"
    download "${NPM_REGISTRY}/${name}/-/${base}-${ver}.tgz" "$tgz"
  fi
  local tmp
  tmp="$(mktemp -d)"
  tar -xzf "$tgz" -C "$tmp" || { rm -rf "$tmp"; die "解包 npm 包失败: $name@$ver"; }
  [[ -d "$tmp/package" ]] || { rm -rf "$tmp"; die "npm 包结构异常: $name@$ver"; }
  python3 - "$tmp/package/package.json" "$name" "$ver" <<'PYEOF'
import json, sys
path, name, ver = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as fh:
    pkg = json.load(fh)
if pkg.get("version") != ver:
    raise SystemExit(f"版本不匹配: 期望 {ver}，实际 {pkg.get('version')} ({name})")
PYEOF
  mkdir -p "$(dirname "$dest")"
  rm -rf "$dest"
  mv "$tmp/package" "$dest"
  rm -rf "$tmp"
  info "已安装 ${name}${ver}"
}

REPLACEMENTS=(
  "@deepseek-ai/node-addon-system-darwin-arm64|@deepseek-ai/node-addon-system-linux-x64|0.1.2"
  "@img/sharp-darwin-arm64|@img/sharp-linux-x64|0.35.5"
  "@img/sharp-libvips-darwin-arm64|@img/sharp-libvips-linux-x64|1.3.4"
  "@koromix/koffi-darwin-arm64|@koromix/koffi-linux-x64|3.1.1"
  "@vscode/ripgrep-darwin-arm64|@vscode/ripgrep-linux-x64|1.18.0"
  "node-addon-require-builtin-darwin-arm64|node-addon-require-builtin-linux-x64-gnu|0.1.9"
  "sherpa-onnx-darwin-arm64|sherpa-onnx-linux-x64|1.13.8"
  "@deepseek-ai/libreoffice-kit-darwin-arm64|@deepseek-ai/libreoffice-kit-wasm|0.1.5"
)

replace_native_packages() {
  step "4/9 替换平台原生模块 ..."
  local modules="$APP_DIR/dsh/node_modules"
  local row darwin linux ver
  for row in "${REPLACEMENTS[@]}"; do
    IFS='|' read -r darwin linux ver <<< "$row"
    [[ -d "$modules/$darwin" ]] || { warn "源包缺少 $darwin，跳过该替换"; continue; }
    rm -rf "${modules:?}/$darwin"
    install_npm_pkg "$linux" "$ver" "$modules/$linux" || die "替换 $darwin → $linux 失败"
  done
}

build_node_pty() {
  step "4/9 编译 node-pty (linux-x64) ..."
  local dir="$APP_DIR/dsh/node_modules/node-pty"
  local out="$dir/prebuilds/linux-x64"
  if [[ -f "$out/pty.node" ]]; then
    info "复用已编译的 node-pty"
    return 0
  fi
  if ! command -v g++ >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1; then
    degrade "缺少 g++/make，跳过 node-pty 编译：终端功能不可用"
    return 0
  fi
  ( cd "$dir" && npm_config_build_from_source=true npx --yes node-gyp@11 rebuild ) || {
    degrade "node-pty 编译失败：终端功能不可用"
    return 0
  }
  mkdir -p "$out"
  cp "$dir/build/Release/pty.node" "$out/pty.node" || { degrade "node-pty 产物缺失：终端功能不可用"; return 0; }
  if [[ -f "$dir/build/Release/spawn-helper" ]]; then
    cp "$dir/build/Release/spawn-helper" "$out/spawn-helper"
    chmod 0755 "$out/spawn-helper"
  fi
  rm -rf "$dir/build"
  info "node-pty 已编译到 prebuilds/linux-x64"
}

check_native_residue() {
  local left
  left="$(find "$APP_DIR" \( -name '*.dylib' -o -name '*-darwin-arm64' \) -print 2>/dev/null | head -20 || true)"
  if [[ -n "$left" ]]; then
    degrade "仍存在 darwin 产物：$left"
  else
    info "检查通过：无 darwin 原生残留"
  fi
}

# ---------- 描述符与 CLI 改写 ----------
prepare_runtime() {
  step "3/9 重写运行时描述符与 CLI 启动脚本 ..."
  python3 - "$APP_DIR/dsh/desktop-runtime.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
data["platform"] = "linux"
data["arch"] = "x64"
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, separators=(",", ":"))
    fh.write("\n")
PYEOF

  python3 - "$APP_DIR/package.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
if "dshMandatoryUpdatePolicy" in data:
    del data["dshMandatoryUpdatePolicy"]
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
PYEOF

  local cli="$RES_DIR/runtime/cli/bin/dsh"
  mkdir -p "$(dirname "$cli")"
  cat > "$cli" <<'SHEOF'
#!/bin/sh
# Run the installed CLI without changing the invoking shell or working directory.
set -e
launcher=$0
while [ -L "$launcher" ]; do
  directory=$(CDPATH= cd -- "$(dirname -- "$launcher")" && pwd -P)
  target=$(readlink "$launcher")
  case "$target" in
    /*) launcher=$target ;;
    *) launcher=$directory/$target ;;
  esac
done
resources=$(CDPATH= cd -- "$(dirname -- "$launcher")/../../.." && pwd -P)
ELECTRON_RUN_AS_NODE=1 exec "$resources/../deepseek-harness" --expose-internals "$resources/app/dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/cli.js" "$@"
SHEOF
  chmod 0755 "$cli"

  if [[ -f "$RES_DIR/app-update.yml" ]]; then
    rm -f "$RES_DIR/app-update.yml"
    info "已移除 app-update.yml（Linux 无自动更新通道）"
  fi
}

# ---------- Electron 与组装 ----------
ELECTRON_DIR="$WORK_DIR/electron"
STAGE="$WORK_DIR/stage"

download_electron() {
  step "6/9 获取 Electron ${ELECTRON_VERSION} (linux-x64) ..."
  local zip="$CACHE_DIR/electron-v${ELECTRON_VERSION}-linux-x64.zip"
  if [[ -x "$ELECTRON_DIR/electron" ]]; then
    info "复用已解压的 Electron"
  else
    download "https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-linux-x64.zip" "$zip"
    rm -rf "$ELECTRON_DIR"
    mkdir -p "$ELECTRON_DIR"
    unzip -q "$zip" -d "$ELECTRON_DIR" || { rm -rf "$ELECTRON_DIR"; die "Electron 解压失败"; }
  fi
  [[ -x "$ELECTRON_DIR/electron" ]] || die "Electron 目录缺少 electron 可执行文件"
  chmod 4755 "$ELECTRON_DIR/chrome-sandbox" 2>/dev/null || true
}

assemble_app() {
  step "7/9 组装应用目录 ..."
  local root="$STAGE/opt/$APP_NAME"
  local res="$root/electron/resources"
  rm -rf "$STAGE"
  mkdir -p "$root"
  cp -a "$ELECTRON_DIR" "$root/electron"
  rm -f "$res/default_app.asar"
  cp -a "$APP_DIR" "$res/app"
  cp -a "$RES_DIR/runtime" "$res/runtime"

  if [[ -f "$RES_DIR/icon.png" ]]; then
    cp "$RES_DIR/icon.png" "$res/icon.png"
  else
    degrade "源包缺少 icon.png，桌面入口将无图标"
  fi
  if [[ -n "$TRAY_ICON" && -f "$TRAY_ICON" ]]; then
    cp "$TRAY_ICON" "$res/tray.ico"
  elif [[ -f "$RES_DIR/icon.png" ]]; then
    cp "$RES_DIR/icon.png" "$res/tray.ico"
    info "托盘图标: 使用 icon.png 兜底"
  fi

  if [[ -x "$root/electron/electron" ]]; then
    mv "$root/electron/electron" "$root/electron/$APP_NAME"
  fi
  chmod 4755 "$res/../chrome-sandbox" 2>/dev/null || true
  if [[ -x "$res/../chrome-sandbox" ]]; then
    info "chrome-sandbox 权限: $(stat -c %a "$res/../chrome-sandbox")"
  fi
}

make_icons() {
  local src="$RES_DIR/icon.png"
  local node="$PRIMARY_RUNTIME/dependencies/node/bin/node"
  local out="$STAGE"
  if [[ ! -f "$src" ]]; then
    degrade "缺少 icon.png，跳过图标生成"
    return 0
  fi
  if [[ -x "$node" ]] && NODE_PATH="$APP_DIR/dsh/node_modules" "$node" - "$src" "$out" <<'JSEOF' 2>/dev/null
const fs = require("fs");
const path = require("path");
const sharp = require("sharp");
const src = process.argv[2];
const out = process.argv[3];
(async () => {
  for (const size of [16, 24, 32, 48, 64, 128, 256, 512]) {
    const dir = path.join(out, "usr/share/icons/hicolor", size + "x" + size, "apps");
    fs.mkdirSync(dir, { recursive: true });
    await sharp(src).resize(size, size, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } }).png().toFile(path.join(dir, "deepseek-harness.png"));
  }
})().catch((error) => { console.error(error); process.exit(1); });
JSEOF
  then
    info "图标已生成 (hicolor 多尺寸)"
  else
    mkdir -p "$out/usr/share/icons/hicolor/512x512/apps"
    cp "$src" "$out/usr/share/icons/hicolor/512x512/apps/$APP_NAME.png"
    degrade "图标缩放失败，仅安装单尺寸图标"
  fi
  mkdir -p "$out/usr/share/pixmaps"
  cp "$src" "$out/usr/share/pixmaps/$APP_NAME.png"
}

# ---------- primary-runtime 重建 ----------
PRIMARY_RUNTIME=""
NODE_RUNTIME_VERSION="${NODE_RUNTIME_VERSION:-24.21.0}"
PNPM_RUNTIME_VERSION="${PNPM_RUNTIME_VERSION:-11.28.5}"
# PY_MM：应用自带 CPython 的次版本（来自源包 runtime.json，默认 3.12 兜底）
PY_MM="3.12"
PY_ASSET_TAG=""
PY_ASSET_NAME=""
PY_ASSET_URL=""

# 从源包 runtime.json 动态读取 node / pnpm / python 版本，缺失字段保留默认值
resolve_runtime_versions() {
  local rj="$EXTRACT_DIR/.source-runtime.json"
  [[ -f "$rj" ]] || { warn "缺少源包 runtime.json，node/pnpm/python 版本使用默认值"; return 0; }
  local ver
  ver="$(python3 - "$rj" <<'PYEOF'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
print(data.get("node", ""))
print(data.get("pnpm", ""))
print(".".join(str(data.get("python", "")).split(".")[:2]))
PYEOF
)"
  local n p py
  { IFS= read -r n; IFS= read -r p; IFS= read -r py; } <<< "$ver"
  if [[ -n "$n" && -z "${NODE_RUNTIME_VERSION_OVERRIDE:-}" ]]; then
    NODE_RUNTIME_VERSION="$n"
  fi
  if [[ -n "$p" && -z "${PNPM_RUNTIME_VERSION_OVERRIDE:-}" ]]; then
    PNPM_RUNTIME_VERSION="$p"
  fi
  if [[ "$py" =~ ^[0-9]+\.[0-9]+$ && -z "${PY_MM_OVERRIDE:-}" ]]; then
    PY_MM="$py"
  fi
  info "runtime.json 锁定: node=$NODE_RUNTIME_VERSION pnpm=$PNPM_RUNTIME_VERSION python=$PY_MM"
}

resolve_python_asset() {
  if [[ -n "${PYTHON_URL:-}" ]]; then
    PY_ASSET_URL="$PYTHON_URL"
    PY_ASSET_NAME="$(basename "${PYTHON_URL%%\?*}")"
    return 0
  fi
  local api="$CACHE_DIR/python-build-standalone-latest.json"
  if [[ ! -s "$api" ]]; then
    download "https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest" "$api"
  fi
  local info
  info="$(python3 - "$api" "$PY_MM" <<'PYEOF'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
py_mm = sys.argv[2]
tag = data.get("tag_name", "")
for asset in data.get("assets", []):
    name = asset.get("name", "")
    if name.startswith(f"cpython-{py_mm}") and name.endswith("x86_64-unknown-linux-gnu-install_only.tar.gz"):
        print(tag)
        print(name)
        break
PYEOF
)"
  [[ -n "$info" ]] || die "未找到 CPython ${PY_MM} linux-x64 发行版；可用 PYTHON_URL 指定"
  PY_ASSET_TAG="$(sed -n '1p' <<< "$info")"
  PY_ASSET_NAME="$(sed -n '2p' <<< "$info")"
  PY_ASSET_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PY_ASSET_TAG}/${PY_ASSET_NAME}"
  info "CPython 资产: $PY_ASSET_NAME"
}

install_runtime_node() {
  local dest="$1/node"
  if [[ -x "$dest/bin/node" ]]; then
    info "复用 Node runtime"
    return 0
  fi
  local tarball="$CACHE_DIR/node-v${NODE_RUNTIME_VERSION}-linux-x64.tar.xz"
  download "https://nodejs.org/dist/v${NODE_RUNTIME_VERSION}/node-v${NODE_RUNTIME_VERSION}-linux-x64.tar.xz" "$tarball"
  local tmp
  tmp="$(mktemp -d)"
  tar -xJf "$tarball" -C "$tmp" || { rm -rf "$tmp"; die "解包 Node runtime 失败"; }
  local src="$tmp/node-v${NODE_RUNTIME_VERSION}-linux-x64"
  rm -rf "$dest"
  mkdir -p "$dest/bin" "$dest/node_modules"
  install -m 0755 "$src/bin/node" "$dest/bin/node"
  [[ -f "$src/LICENSE" ]] && cp "$src/LICENSE" "$dest/LICENSE"
  printf 'Bundled Node.js runtime; npm packages are not included.\n' > "$dest/node_modules/README.txt"
  rm -rf "$tmp"
  info "Node runtime: $("$dest/bin/node" -v)"
}

install_runtime_pnpm() {
  local dest="$1/pnpm"
  if [[ -f "$dest/bin/pnpm.mjs" ]]; then
    info "复用 pnpm runtime"
    return 0
  fi
  install_npm_pkg "pnpm" "$PNPM_RUNTIME_VERSION" "$dest"
  [[ -f "$dest/bin/pnpm.mjs" ]] || die "pnpm 包缺少 bin/pnpm.mjs"
}

install_runtime_python() {
  local dest="$1/python" site="$1/python/lib/python${PY_MM}/site-packages"
  local tarball="$CACHE_DIR/$PY_ASSET_NAME"
  if [[ ! -x "$dest/bin/python${PY_MM}" ]]; then
    download "$PY_ASSET_URL" "$tarball"
    local tmp
    tmp="$(mktemp -d)"
    tar -xzf "$tarball" -C "$tmp" || { rm -rf "$tmp"; die "解包 CPython 失败"; }
    [[ -d "$tmp/python" ]] || { rm -rf "$tmp"; die "CPython 资产结构异常（缺少 python/）"; }
    rm -rf "$dest"
    mv "$tmp/python" "$dest"
    rm -rf "$tmp"
    rm -rf "$dest/include" "$dest/share/man" "$dest/share/doc"
  else
    info "复用 CPython runtime"
  fi
  if [[ ! -f "$dest/.trimmed" ]]; then
    trim_python_runtime "$dest"
    touch "$dest/.trimmed"
  fi
  (
    cd "$dest/bin"
    ln -sfn "python${PY_MM}" python3
    ln -sfn "python${PY_MM}" python
  )
  mkdir -p "$site"
  info "CPython runtime: $("$dest/bin/python${PY_MM}" -V 2>&1)"
}

trim_python_runtime() {
  local dest="$1"
  rm -rf "$dest/lib/python${PY_MM}/test" "$dest/lib/python${PY_MM}/ensurepip" 2>/dev/null || true
  find "$dest" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
  if command -v strip >/dev/null 2>&1; then
    find "$dest/lib" -type f -name '*.so*' ! -type l -exec strip --strip-unneeded {} + 2>/dev/null || true
  fi
}

install_python_packages() {
  local deps="$1" site="$1/python/lib/python${PY_MM}/site-packages"
  local manifest="$PRIMARY_RUNTIME/runtime.json"
  local pkgs=()
  mapfile -t pkgs < <(python3 - "$manifest" <<'PYEOF'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
installers = {"pip", "setuptools", "wheel", "packaging"}
for name, version in data.get("pythonPackages", {}).items():
    if name.lower().replace("-", "_") in installers:
        continue
    print(f"{name}=={version}")
PYEOF
)
  if (("${#pkgs[@]}" == 0)); then
    info "runtime.json 未声明 Python 包，跳过"
    return 0
  fi
  local marker="$site/.dsh-wheels-installed"
  if [[ -f "$marker" ]]; then
    info "复用已安装的 Python wheels"
    return 0
  fi
  local args=(install --no-cache-dir --no-warn-script-location --target "$site")
  [[ -n "$PIP_INDEX" ]] && args+=(-i "$PIP_INDEX")
  info "安装 Python wheels（${#pkgs[@]} 个）..."
  "$deps/python/bin/python3" -m pip "${args[@]}" "${pkgs[@]}" || die "Python wheels 安装失败"
  rm -rf "${site:?}/bin" "${site:?}/__pycache__"
  find "$site" "$deps/python/lib/python${PY_MM}" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
  touch "$marker"
}

canonical_python_packages() {
  "$1/python/bin/python3" - "$1/python/lib/python${PY_MM}/site-packages" <<'PYEOF'
import json, pathlib, sys
site = pathlib.Path(sys.argv[1])
result = {}
for dist in sorted(site.glob("*.dist-info")):
    meta = dist / "METADATA"
    if not meta.exists():
        continue
    name = version = None
    for line in meta.read_text(encoding="utf-8", errors="ignore").splitlines():
        if line.startswith("Name: "):
            name = line[6:].strip()
        elif line.startswith("Version: "):
            version = line[9:].strip()
        if name and version:
            break
    installer = {"pip", "setuptools", "wheel", "packaging"}
    if name and version and name.lower().replace("-", "_") not in installer:
        result[name] = version
print(json.dumps(result, ensure_ascii=False))
PYEOF
}

payload_digest() {
  python3 - "$1" <<'PYEOF'
import hashlib, os, pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
digest = hashlib.sha256()
for path in sorted(root.rglob("*")):
    rel = str(path.relative_to(root))
    if path.is_symlink():
        digest.update(b"L" + rel.encode() + b"\0" + os.readlink(path).encode() + b"\0")
    elif path.is_file():
        digest.update(b"F" + rel.encode() + b"\0")
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                digest.update(chunk)
        digest.update(b"\0")
print(digest.hexdigest())
PYEOF
}

rewrite_runtime_manifest() {
  local runtime_json="$PRIMARY_RUNTIME/runtime.json"
  local python_version actual_packages digest
  python_version="$("$PRIMARY_RUNTIME/dependencies/python/bin/python3" -c 'import platform;print(platform.python_version())')"
  actual_packages="$(canonical_python_packages "$PRIMARY_RUNTIME/dependencies")"
  find "$PRIMARY_RUNTIME/dependencies/python" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
  digest="$(payload_digest "$PRIMARY_RUNTIME/dependencies")"
  python3 - "$runtime_json" "$python_version" "$actual_packages" "$digest" <<'PYEOF'
import json, sys
path, python_version, packages, digest = sys.argv[1:5]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
data["platform"] = "linux"
data["arch"] = "x64"
data["python"] = python_version
data["pythonPackages"] = json.loads(packages)
data["payloadDigest"] = digest
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PYEOF
  info "runtime.json: python=$python_version digest=${digest:0:12}"
}

check_payload_layout() {
  local deps="$PRIMARY_RUNTIME/dependencies"
  local errors=()
  [[ -f "$deps/node/bin/node" ]] || errors+=("node/bin/node")
  [[ -d "$deps/node/node_modules" ]] || errors+=("node/node_modules")
  [[ -f "$deps/pnpm/bin/pnpm.mjs" ]] || errors+=("pnpm/bin/pnpm.mjs")
  [[ -f "$deps/python/bin/python3" ]] || errors+=("python/bin/python3")
  [[ -d "$deps/python/lib/python${PY_MM}/site-packages" ]] || errors+=("python/lib/python${PY_MM}/site-packages")
  [[ "$(readlink "$deps/python/bin/python3" 2>/dev/null)" == "python${PY_MM}" ]] || errors+=("python/bin/python3 应为相对链接")
  [[ "$(readlink "$deps/python/bin/python" 2>/dev/null)" == "python${PY_MM}" ]] || errors+=("python/bin/python 应为相对链接")
  if (("${#errors[@]}" > 0)); then
    die "primary-runtime 布局不完整: ${errors[*]}"
  fi
  info "primary-runtime 布局校验通过"
}

build_primary_runtime() {
  step "5/9 重建 primary-runtime ..."
  PRIMARY_RUNTIME="$RES_DIR/runtime/primary-runtime"
  local deps="$PRIMARY_RUNTIME/dependencies"
  local stamp="$deps/.linux-x64-payload"
  if [[ ! -f "$stamp" ]]; then
    info "清理源包内的非 Linux primary-runtime"
    rm -rf "$deps"
  fi
  mkdir -p "$deps"
  resolve_runtime_versions
  resolve_python_asset
  install_runtime_node "$deps"
  install_runtime_pnpm "$deps"
  install_runtime_python "$deps"
  install_python_packages "$deps"
  find "$deps/python" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
  rewrite_runtime_manifest
  check_payload_layout
  touch "$stamp"
  du -sh "$deps" 2>/dev/null || true
}

# ---------- 缓存键 ----------
CACHE_KEY=""
compute_cache_key() {
  local src="$1" hash
  hash="$(sha256sum "$src" | awk '{print $1}')"
  CACHE_KEY="${APP_VERSION}-${hash:0:12}"
  printf '%s\n' "$CACHE_KEY" > "$WORK_DIR/cache-key"
}

# ---------- 源包探测 ----------
SRC_PKG=""
EXTRACT_DIR="$WORK_DIR/extract"
RES_DIR=""

probe_source() {
  if [[ -n "$SOURCE_REF" ]]; then
    if [[ "$SOURCE_REF" == http://* || "$SOURCE_REF" == https://* ]]; then
      local name
      name="$(basename "${SOURCE_REF%%\?*}")"
      SRC_PKG="$CACHE_DIR/$name"
      download "$SOURCE_REF" "$SRC_PKG"
    else
      SRC_PKG="$SOURCE_REF"
    fi
  else
    local arm=() other=() f
    for f in "$SKILL_DIR"/dsh-*.dmg "$PWD"/dsh-*.dmg; do
      [[ -f "$f" ]] || continue
      if [[ "$f" == *arm64* ]]; then arm+=("$f"); else other+=("$f"); fi
    done
    if (("${#arm[@]}" > 0)); then
      SRC_PKG="${arm[0]}"
      info "自动探测到 macOS arm64 DMG：$(basename "$SRC_PKG")"
    elif (("${#other[@]}" > 0)); then
      SRC_PKG="${other[0]}"
      warn "未找到 arm64 DMG，尝试非 arm64 包（将由内容校验拒绝）：$(basename "$SRC_PKG")"
    fi
  fi

  [[ -n "$SRC_PKG" ]] || { usage >&2; die "未找到源安装包（dsh-*.dmg），请用 -s 指定 macOS arm64 DMG"; }
  [[ -f "$SRC_PKG" ]] || { usage >&2; die "源安装包不存在: $SRC_PKG"; }
  [[ -s "$SRC_PKG" ]] || die "源安装包为空: $SRC_PKG"
  case "$SRC_PKG" in
    *.dmg) ;;
    *.exe) die "仅支持 macOS arm64 DMG，不再支持 Windows exe: $SRC_PKG" ;;
    *) die "不支持的源包类型（仅 .dmg）: $SRC_PKG" ;;
  esac
  info "源包: $SRC_PKG"
}

# ---------- 源包解包 ----------
extract_source() {
  local hash
  hash="$(sha256sum "$SRC_PKG" | awk '{print $1}')"
  if [[ -f "$EXTRACT_DIR/.source-hash" && "$(cat "$EXTRACT_DIR/.source-hash")" == "$hash" ]]; then
    RES_DIR="$(find "$EXTRACT_DIR" -type d -path '*.app/Contents/Resources' -print -quit 2>/dev/null || true)"
    if [[ -n "$RES_DIR" && -f "$RES_DIR/app.asar" ]]; then
      info "复用已解包的源包"
      if [[ ! -f "$EXTRACT_DIR/.source-runtime.json" ]]; then
        mkdir -p "$EXTRACT_DIR/.meta"
        7z e -y -bso0 -bsp0 -o"$EXTRACT_DIR/.meta" "$SRC_PKG" "-ir!*primary-runtime/runtime.json" >/dev/null 2>&1 || true
        if [[ -f "$EXTRACT_DIR/.meta/runtime.json" ]]; then
          mv "$EXTRACT_DIR/.meta/runtime.json" "$EXTRACT_DIR/.source-runtime.json"
          rmdir "$EXTRACT_DIR/.meta" 2>/dev/null || true
        fi
      fi
      return 0
    fi
  fi

  step "1/9 解包 macOS DMG ..."
  local tmp="$EXTRACT_DIR.tmp"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  7z x -y -bso0 -bsp0 -o"$tmp/dmg" "$SRC_PKG" >/dev/null || { rm -rf "$tmp"; die "DMG 解包失败: $SRC_PKG"; }
  local res
  res="$(find "$tmp/dmg" -type d -path '*.app/Contents/Resources' -print -quit 2>/dev/null || true)"
  [[ -n "$res" ]] || { rm -rf "$tmp"; die "DMG 内未找到 *.app/Contents/Resources"; }
  [[ -f "$res/app.asar" ]] || { rm -rf "$tmp"; die "资源目录缺少 app.asar: $res"; }

  rm -rf "$EXTRACT_DIR"
  mv "$tmp" "$EXTRACT_DIR"
  RES_DIR="${res/"$tmp"/"$EXTRACT_DIR"}"
  cp "$RES_DIR/runtime/primary-runtime/runtime.json" "$EXTRACT_DIR/.source-runtime.json" 2>/dev/null || true
  printf '%s\n' "$hash" > "$EXTRACT_DIR/.source-hash"
  info "资源目录: $RES_DIR"
}

validate_source_arch() {
  local rj="$EXTRACT_DIR/.source-runtime.json"
  if [[ ! -f "$rj" ]]; then
    warn "缺少源包 runtime.json 记录，跳过架构校验"
    return 0
  fi
  local meta
  meta="$(python3 - "$rj" <<'PYEOF'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
print(f"{data.get('platform', '')} {data.get('arch', '')}")
PYEOF
)"
  if [[ "$meta" != "darwin arm64" ]]; then
    die "仅支持 macOS arm64 DMG（源包为 ${meta// /-}）"
  fi
  info "源包架构校验通过: darwin arm64"
}

# ---------- 托盘图标（DMG 源不含，组装时用 icon.png 兜底） ----------
TRAY_ICON=""

# ---------- app.asar 解压 ----------
APP_DIR="$WORK_DIR/app"
extract_asar() {
  step "2/9 解压 app.asar ..."
  if [[ -f "$APP_DIR/package.json" && -d "$APP_DIR/dsh" ]]; then
    info "复用已解压的应用目录"
    if [[ -d "$RES_DIR/app.asar.unpacked" ]]; then
      cp -a "$RES_DIR/app.asar.unpacked/." "$APP_DIR/" 2>/dev/null || true
    fi
    return 0
  fi
  rm -rf "$APP_DIR"
  mkdir -p "$APP_DIR"
  npx --yes asar@3.2.0 extract "$RES_DIR/app.asar" "$APP_DIR" >/dev/null || { rm -rf "$APP_DIR"; die "app.asar 解压失败"; }
  if [[ -d "$RES_DIR/app.asar.unpacked" ]]; then
    cp -a "$RES_DIR/app.asar.unpacked/." "$APP_DIR/" || die "合并 app.asar.unpacked 失败"
  fi
  [[ -f "$APP_DIR/package.json" ]] || { rm -rf "$APP_DIR"; die "解压后应用目录缺少 package.json"; }
  [[ -d "$APP_DIR/dsh" ]] || { rm -rf "$APP_DIR"; die "解压后应用目录缺少 dsh/"; }
  info "应用目录: $APP_DIR"
}

# ---------- 版本提取 ----------
APP_VERSION=""
detect_version() {
  local pkg="$WORK_DIR/app/package.json"
  if [[ -f "$pkg" ]]; then
    APP_VERSION="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$pkg" 2>/dev/null || true)"
  fi
  if [[ -z "$APP_VERSION" ]]; then
    local plist
    plist="$(find "$EXTRACT_DIR" -name Info.plist -path '*.app/Contents/*' -print -quit 2>/dev/null || true)"
    if [[ -n "$plist" ]]; then
      APP_VERSION="$(python3 - "$plist" <<'PYEOF'
import plistlib, sys
with open(sys.argv[1], "rb") as fh:
    print(plistlib.load(fh).get("CFBundleShortVersionString", ""))
PYEOF
)"
    fi
  fi
  [[ -n "$APP_VERSION" ]] || die "无法从应用包提取版本号"
  printf '%s\n' "$APP_VERSION" > "$WORK_DIR/version"
  info "应用版本: $APP_VERSION"
}

# ---------- 桌面入口与打包 ----------
DEB_DEPENDS="libasound2t64 | libasound2, libatk-bridge2.0-0, libatk1.0-0, libatspi2.0-0, libcairo2, libcups2, libdbus-1-3, libdrm2, libexpat1, libgbm1, libglib2.0-0, libgtk-3-0, libnotify4, libnspr4, libnss3, libpango-1.0-0, libsecret-1-0, libuuid1, libx11-6, libxcb1, libxcomposite1, libxdamage1, libxext6, libxfixes3, libxkbcommon0, libxrandr2, libxss1, libxtst6, xdg-utils"

write_desktop_entries() {
  step "8/9 生成启动脚本与桌面入口 ..."
  mkdir -p "$STAGE/usr/bin" "$STAGE/usr/share/applications"
  cat > "$STAGE/usr/bin/$APP_NAME" <<SHEOF
#!/bin/sh
exec ${INSTALL_DIR}/electron/${APP_NAME} "\$@"
SHEOF
  chmod 0755 "$STAGE/usr/bin/$APP_NAME"

  cat > "$STAGE/usr/share/applications/$APP_NAME.desktop" <<DESKEOF
[Desktop Entry]
Name=DeepSeek Harness
Comment=DeepSeek Harness desktop AI agent
Comment[zh_CN]=DeepSeek Harness 桌面智能体
Exec=/usr/bin/$APP_NAME %U
Terminal=false
Type=Application
Icon=$APP_NAME
StartupWMClass=$APP_NAME
Categories=Development;Utility;
DESKEOF
  chmod 0644 "$STAGE/usr/share/applications/$APP_NAME.desktop"
}

write_maintainer_scripts() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/postinst" <<'SHEOF'
#!/bin/sh
set -e
SANDBOX=/opt/deepseek-harness/electron/chrome-sandbox
if [ -f "$SANDBOX" ]; then
  if [ "$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo 1)" = "1" ]; then
    chmod 0755 "$SANDBOX" 2>/dev/null || true
  else
    chmod 4755 "$SANDBOX" 2>/dev/null || true
  fi
fi
if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database -q /usr/share/applications 2>/dev/null || true; fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then gtk-update-icon-cache -q /usr/share/icons/hicolor 2>/dev/null || true; fi
exit 0
SHEOF
  cat > "$dir/postrm" <<'SHEOF'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database -q /usr/share/applications 2>/dev/null || true; fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then gtk-update-icon-cache -q /usr/share/icons/hicolor 2>/dev/null || true; fi
exit 0
SHEOF
  chmod 0755 "$dir/postinst" "$dir/postrm"
}

write_copyright() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/copyright" <<'CPEOF'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: DeepSeek Harness
Source: https://harness.deepseek.com

Files: *
Copyright: DeepSeek
License: MIT
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 .
 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.
 .
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.
CPEOF
  chmod 0644 "$dir/copyright"
}

build_deb() {
  step "9/9 构建 deb ..."
  local root="$WORK_DIR/deb"
  rm -rf "$root"
  mkdir -p "$root/DEBIAN"
  cp -a "$STAGE/." "$root/"
  local size
  size="$(du -sk "$root/opt" | awk '{print $1}')"
  cat > "$root/DEBIAN/control" <<CTLEOF
Package: $APP_NAME
Version: $APP_VERSION
Section: utils
Priority: optional
Architecture: amd64
Maintainer: port-linux <noreply@localhost>
Installed-Size: $size
Depends: $DEB_DEPENDS
Homepage: https://harness.deepseek.com
Description: DeepSeek Harness desktop AI agent (Linux port)
 Electron desktop shell with a bundled dsh runtime, ported from the
 upstream macOS/Windows packages for Linux x64.
CTLEOF
  write_maintainer_scripts "$root/DEBIAN"
  write_copyright "$root/usr/share/doc/$APP_NAME"
  chmod 0644 "$root/DEBIAN/control"

  local out="$OUT_DIR/${APP_NAME}_${APP_VERSION}_amd64.deb"
  rm -f "$out"
  if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb --root-owner-group -Zxz --build "$root" "$out" >/dev/null || die "dpkg-deb 打包失败"
  elif command -v ar >/dev/null 2>&1 && command -v xz >/dev/null 2>&1; then
    warn "dpkg-deb 不可用，降级用 ar + xz 手工拼装 deb"
    local work="$WORK_DIR/ar-deb"
    rm -rf "$work"; mkdir -p "$work"
    printf '2.0\n' > "$work/debian-binary"
    ( cd "$root/DEBIAN" && tar --owner=0 --group=0 --numeric-owner -cJf "$work/control.tar.xz" . )
    ( cd "$root" && tar --owner=0 --group=0 --numeric-owner -cJf "$work/data.tar.xz" --exclude=./DEBIAN . )
    ( cd "$work" && ar rc "$out" debian-binary control.tar.xz data.tar.xz ) || die "ar 拼装 deb 失败"
  else
    die "dpkg-deb 与 ar 均不可用，无法构建 deb（应用目录保留在 $STAGE）"
  fi
  [[ -s "$out" ]] || die "deb 产物为空: $out"
  info "deb: $out ($(du -h "$out" | cut -f1))"
}

build_rpm() {
  if ! command -v rpmbuild >/dev/null 2>&1; then
    warn "rpmbuild 不可用，跳过 rpm"
    return 0
  fi
  step "9/9 构建 rpm ..."
  local top="$WORK_DIR/rpmbuild"
  rm -rf "$top"
  mkdir -p "$top"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
  local spec="$top/SPECS/$APP_NAME.spec"
  cat > "$spec" <<SPECEOF
Name: $APP_NAME
Version: $APP_VERSION
Release: 1
Summary: DeepSeek Harness desktop AI agent (Linux port)
License: MIT
BuildArch: x86_64
AutoReqProv: no

%description
Electron desktop shell with a bundled dsh runtime, ported from the
upstream macOS/Windows packages for Linux x64.

%install
mkdir -p %{buildroot}
cp -a "$STAGE/." %{buildroot}/

%files
/opt/$APP_NAME
/usr/bin/$APP_NAME
/usr/share/applications/$APP_NAME.desktop
/usr/share/icons/hicolor
/usr/share/pixmaps/$APP_NAME.png
/usr/share/doc/$APP_NAME

%post
SANDBOX=/opt/$APP_NAME/electron/chrome-sandbox
if [ -f "\$SANDBOX" ]; then
  if [ "\$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo 1)" = "1" ]; then
    chmod 0755 "\$SANDBOX" 2>/dev/null || true
  else
    chmod 4755 "\$SANDBOX" 2>/dev/null || true
  fi
fi
update-desktop-database -q /usr/share/applications 2>/dev/null || true
gtk-update-icon-cache -q /usr/share/icons/hicolor 2>/dev/null || true

%postun
update-desktop-database -q /usr/share/applications 2>/dev/null || true
gtk-update-icon-cache -q /usr/share/icons/hicolor 2>/dev/null || true
SPECEOF
  rpmbuild --define "_topdir $top" -bb "$spec" >/dev/null || { warn "rpmbuild 失败，跳过 rpm"; return 0; }
  local built
  built="$(find "$top/RPMS" -name '*.rpm' -print -quit)"
  [[ -n "$built" ]] || { warn "未产出 rpm"; return 0; }
  cp "$built" "$OUT_DIR/"
  info "rpm: $OUT_DIR/$(basename "$built")"
}

print_summary() {
  echo
  info "========== 构建摘要 =========="
  info "应用: $APP_TITLE $APP_VERSION"
  info "Electron: $ELECTRON_VERSION"
  info "产物目录: $OUT_DIR"
  local f
  for f in "$OUT_DIR"/*.deb "$OUT_DIR"/*.rpm; do
    [[ -f "$f" ]] && info "  $(basename "$f") — $(du -h "$f" | cut -f1)"
  done
  if (("${#DEGRADATIONS[@]}" > 0)); then
    warn "降级项:"
    local d
    for d in "${DEGRADATIONS[@]}"; do warn "  - $d"; done
  else
    info "无降级项"
  fi
}

main() {
  step "0/9 初始化"
  info "构建目标: $BUILD_TARGET"
  info "Electron: $ELECTRON_VERSION"
  info "工作目录: $BUILD_ROOT"

  probe_source
  extract_source
  validate_source_arch
  extract_asar
  prepare_runtime
  replace_native_packages
  build_node_pty
  check_native_residue
  build_primary_runtime
  detect_version
  download_electron
  assemble_app
  make_icons
  write_desktop_entries
  compute_cache_key "$SRC_PKG"
  info "缓存键: $CACHE_KEY"

  case "$BUILD_TARGET" in
    deb) build_deb ;;
    rpm) build_rpm ;;
    all) build_deb; build_rpm ;;
  esac

  print_summary
}

main "$@"
