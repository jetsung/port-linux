#!/usr/bin/env bash
# port.sh — 将 OpenDesign 桌面客户端移植到 Linux x64（deb / rpm）
#
# 上游 0.27.0 仅发布 macOS（arm64/x64 DMG）与 Windows（x64 NSIS exe），
# 没有 Linux 包，也没有官方 AppImage。本脚本固定以 win-x64-setup.exe 为唯一源：
#   1. 7z 解 NSIS 双层 payload（base + overlay 覆盖），得到官方发布态业务载荷
#   2. 删除 Windows PE/DLL 与 win32 原生模块，保留 pak/locales/web-standalone
#   3. 原生模块 Linux 化：npm linux-x64 平台包替换 + better-sqlite3/node-pty 本机编译
#   4. 取 Electron（版本从 PE 自动探测）linux-x64 runtime 作为 Linux 主程序
#   5. 组装 /opt/OpenDesign，生成 desktop / 图标 / wrapper / 维护脚本
#   6. 打包 deb（可选 rpm）
#
# 可选 -b/--base：传入一个 Linux AppImage（如自行 tools-pack 构建的产物），
# 只复用其完好的 Linux ELF 运行时（主程序、内置 Node、vela、opencode、
# Linux 原生模块、官方图标），跳过 Electron 下载与原生模块编译。
# 其业务载荷一律丢弃——官方发布态载荷以 Windows 包为准。
#
# 用法:
#   ./port.sh                                   # 自动探测当前目录的 win-x64 setup.exe
#   ./port.sh -p deb -s open-design-0.27.0-win-x64-setup.exe
#   ./port.sh -b ~/Applications/open-design-*.AppImage
#
# 依赖: 7z, unzip, tar, strings, file, node, npx, python3, curl/wget;
#       打 deb 需 dpkg-deb（缺失时降级 ar + xz）；打 rpm 需 rpmbuild

usage() {
  cat <<'EOF'
port.sh — 将 OpenDesign 桌面客户端移植到 Linux x64（deb / rpm）

上游仅提供 macOS（DMG）与 Windows（NSIS exe）安装包，无 Linux 版。本脚本仅以
Windows x64 setup.exe 为源：解 NSIS 双层 payload 得到官方发布态业务载荷
（prebundled daemon/web-sidecar + Next.js web-standalone + 完整 config），
替换 Windows PE 与 win32 原生模块为 Linux 等价物，用 Electron linux-x64
运行时启动，重新打包为 deb / rpm。

用法:
  ./port.sh                                   # 自动探测当前目录源包，按当前 OS 打包
  ./port.sh -p deb                            # 只打 deb
  ./port.sh -p all                            # 同时打 deb 和 rpm（需 rpmbuild）
  ./port.sh -s ./open-design-0.27.0-win-x64-setup.exe
  ./port.sh -s "https://releases.open-design.ai/stable/versions/0.27.0/open-design-0.27.0-win-x64-setup.exe"
  ./port.sh -b ./open-design-0.27.0-linux-x64_xxx.AppImage   # 可选：复用其 Linux ELF 运行时
  ./port.sh -e 41.3.0 -i ./icon.png           # 覆盖 Electron 版本 / 指定图标

选项:
  -p, --platform deb|rpm|all   构建目标；省略时按当前 OS 自动检测
  -s, --source PATH|URL        源安装包（win-x64 setup.exe）：本地路径或下载地址；
                               省略时自动探测当前目录 open-design-*-win-x64-setup.exe
  -b, --base PATH              可选 Linux AppImage 基底：复用其 Linux ELF 运行时
                               （主程序、内置 Node、vela、opencode、原生模块、图标）
  -e, --electron VERSION       Electron runtime 版本；省略时从源包 PE 自动探测
  -i, --icon PATH              PNG 图标；省略时优先取 -b 基底的官方图标，否则生成占位图
  -h, --help                   显示本帮助

环境变量:
  DEBUG=1                      调试模式（set -eux，打印每条命令）
  IS_CHINA=1                   中国网络环境：GitHub 系域名走 CDN 加速，npm 走镜像
  CDN=<url>                    CDN 前缀地址（默认 https://fastfile.asfd.cn/）
  BUILD_ROOT=<dir>             构建工作目录（默认 <脚本目录>/build；磁盘紧张时可指向 /tmp）
  EXPECTED_SHA256=<hex>        期望的源包 sha256；或放在源包同目录的 .sha256 文件
  OPENCODE_BIN=<path>          自备的 Linux opencode 可执行文件（内置兜底 agent）
  VELA_BIN=<path>              自备的 Linux vela 可执行文件（云同步组件）
  NPM_CONFIG_USERCONFIG        npm 配置文件路径（默认 ~/.npmrc）
  NPM_CONFIG_REGISTRY          npm 镜像地址（~/.npmrc 未配置 registry 时使用）

依赖: 7z、unzip、tar、strings、file、node、npx、python3、curl 或 wget；
      编译 better-sqlite3 / node-pty 需 g++、make 与 python3；
      dpkg-deb（缺失时降级 ar + xz）；rpmbuild（缺失则跳过 rpm）
EOF
}

if [[ -n "${DEBUG:-}" ]]; then
  set -eux
else
  set -euo pipefail
fi

# ---------- 常量 ----------
APP_NAME="open-design"
APP_TITLE="Open Design"
INSTALL_DIR="/opt/OpenDesign"
SKILL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="${BUILD_ROOT:-${SKILL_DIR}/build}"
CACHE_DIR="${BUILD_ROOT}/cache"
WORK_DIR="${BUILD_ROOT}/work"
OUT_DIR="${BUILD_ROOT}/out"
EXTRACT_DIR="${WORK_DIR}/extract"
APP_DIR="${EXTRACT_DIR}/app"
LINUX_RUNTIME_DIR="${WORK_DIR}/runtime"
AI_DIR="${WORK_DIR}/appimage"
STAGE="${WORK_DIR}/stage"
STAGE_ROOT="${STAGE}${INSTALL_DIR}"
HDR_DIR=""

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
  for cmd in 7z unzip tar strings file node npx python3; do
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

# ---------- 平台自动检测 ----------
detect_platform() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-} ${ID_LIKE:-}" in
      *fedora* | *rhel* | *centos* | *suse*) echo rpm; return ;;
      *debian* | *ubuntu*) echo deb; return ;;
    esac
  fi
  if command -v dpkg-deb >/dev/null 2>&1; then echo deb; return; fi
  if command -v rpmbuild >/dev/null 2>&1; then echo rpm; return; fi
  echo deb
}

# ---------- 参数解析 ----------
BUILD_TARGET=""
SOURCE_REF=""
BASE_REF=""
ICON_REF=""
ELECTRON_OVERRIDE=""

while (($# > 0)); do
  case "$1" in
    -p | --platform)
      (($# >= 2)) || { usage >&2; die "选项 $1 缺少参数"; }
      BUILD_TARGET="$2"; shift 2 ;;
    -s | --source)
      (($# >= 2)) || { usage >&2; die "选项 $1 缺少参数"; }
      SOURCE_REF="$2"; shift 2 ;;
    -b | --base)
      (($# >= 2)) || { usage >&2; die "选项 $1 缺少参数"; }
      BASE_REF="$2"; shift 2 ;;
    -i | --icon)
      (($# >= 2)) || { usage >&2; die "选项 $1 缺少参数"; }
      ICON_REF="$2"; shift 2 ;;
    -e | --electron)
      (($# >= 2)) || { usage >&2; die "选项 $1 缺少参数"; }
      ELECTRON_OVERRIDE="$2"; shift 2 ;;
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
mkdir -p "$CACHE_DIR" "$WORK_DIR" "$OUT_DIR"

# ============================================================
# 源包探测与校验
# ============================================================
SRC_PKG=""

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
    local f
    for f in "$SKILL_DIR"/open-design-*-win-x64-setup.exe "$PWD"/open-design-*-win-x64-setup.exe; do
      [[ -f "$f" ]] || continue
      SRC_PKG="$f"
      info "自动探测到源包: $(basename "$SRC_PKG")"
      break
    done
  fi

  [[ -n "$SRC_PKG" ]] || { usage >&2; die "未找到源安装包（open-design-*-win-x64-setup.exe），请用 -s 指定"; }
  [[ -f "$SRC_PKG" ]] || { usage >&2; die "源安装包不存在: $SRC_PKG"; }
  [[ -s "$SRC_PKG" ]] || die "源安装包为空: $SRC_PKG"
  case "$SRC_PKG" in
    *.exe) ;;
    *.dmg) die "仅支持 Windows x64 setup.exe（macOS DMG 含 Mach-O，本案例不处理）: $SRC_PKG" ;;
    *) die "不支持的源包类型（仅 .exe）: $SRC_PKG" ;;
  esac
  info "源包: $SRC_PKG ($(du -h "$SRC_PKG" | cut -f1))"
}

verify_checksum() {
  local expected="" actual
  if [[ -n "${EXPECTED_SHA256:-}" ]]; then
    expected="$EXPECTED_SHA256"
  elif [[ -f "${SRC_PKG}.sha256" ]]; then
    expected="$(awk '{print $1}' "${SRC_PKG}.sha256" | head -1)"
  fi
  actual="$(sha256sum "$SRC_PKG" | awk '{print $1}')"
  info "源包 sha256: $actual"
  if [[ -n "$expected" && "$expected" != "$actual" ]]; then
    die "源包 sha256 校验失败: 期望 $expected，实际 $actual"
  elif [[ -n "$expected" ]]; then
    info "sha256 校验通过"
  fi
}

# ============================================================
# 步骤 1: NSIS 双层解包
# ============================================================
extract_nsis() {
  local hash nsis base overlay
  hash="$(sha256sum "$SRC_PKG" | awk '{print $1}')"
  if [[ -f "$EXTRACT_DIR/.source-hash" && "$(cat "$EXTRACT_DIR/.source-hash")" == "$hash" \
        && -f "$APP_DIR/resources/app/prebundled/packaged-main.mjs" ]]; then
    info "复用已解包的源包"
    return 0
  fi

  step "1/8 解包 Windows NSIS 双层 payload ..."
  nsis="$WORK_DIR/nsis"
  rm -rf "$nsis" "$APP_DIR" "$EXTRACT_DIR"
  mkdir -p "$nsis" "$APP_DIR" "$EXTRACT_DIR"
  7z x -y -bso0 -bsp0 -o"$nsis" "$SRC_PKG" >/dev/null || die "NSIS 安装包解包失败: $SRC_PKG"

  base="$(find "$nsis" -name 'payload-base.7z' -print -quit)"
  overlay="$(find "$nsis" -name 'payload-overlay.7z' -print -quit)"
  [[ -n "$base" && -n "$overlay" ]] || die "NSIS 包内未找到 payload-base.7z / payload-overlay.7z（源包不是预期的 OpenDesign 安装包）"
  info "base: $(basename "$base") / overlay: $(basename "$overlay")"

  # 先解 base（26856 条目，含完整 resources/），再以 overlay 覆盖 3 个文件
  7z x -y -bso0 -bsp0 -o"$APP_DIR" "$base" >/dev/null || die "payload-base.7z 解包失败"
  7z x -y -aoa -bso0 -bsp0 -o"$APP_DIR" "$overlay" >/dev/null || die "payload-overlay.7z 解包失败"

  # 校验关键发布态载荷，防止拿错包（例如误用开发态/自构建产物）
  [[ -f "$APP_DIR/Open Design.exe" ]] || die "缺少 Windows 主程序 Open Design.exe"
  [[ -f "$APP_DIR/resources/app/prebundled/packaged-main.mjs" ]] || die "缺少 prebundled/packaged-main.mjs（非官方发布态载荷）"
  [[ -f "$APP_DIR/resources/app/prebundled/web-sidecar.mjs" ]] || die "缺少 prebundled/web-sidecar.mjs"
  [[ -d "$APP_DIR/resources/open-design-web-standalone" ]] || die "缺少 open-design-web-standalone/（非官方发布态载荷）"
  [[ -f "$APP_DIR/resources/open-design-config.json" ]] || die "缺少 open-design-config.json"

  printf '%s\n' "$hash" > "$EXTRACT_DIR/.source-hash"
  info "发布态载荷就绪: $(find "$APP_DIR/resources/open-design-web-standalone" -type f | wc -l) 个 web-standalone 文件"
}

# ============================================================
# 步骤 2: 版本探测（应用版本 + Electron 版本）
# ============================================================
APP_VERSION=""
APP_CONFIG=""
MODULES=""

detect_versions() {
  step "2/8 探测应用与 Electron 版本 ..."
  APP_CONFIG="$APP_DIR/resources/open-design-config.json"
  MODULES="$APP_DIR/resources/app/node_modules"
  APP_VERSION="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["appVersion"])' "$APP_CONFIG" 2>/dev/null || true)"
  [[ -n "$APP_VERSION" ]] || die "无法从 open-design-config.json 读取 appVersion"
  printf '%s\n' "$APP_VERSION" > "$WORK_DIR/version"

  if [[ -n "$ELECTRON_OVERRIDE" ]]; then
    ELECTRON_VERSION="$ELECTRON_OVERRIDE"
    info "Electron 版本（命令行覆盖）: $ELECTRON_VERSION"
  else
    ELECTRON_VERSION="$(strings -a "$APP_DIR/Open Design.exe" 2>/dev/null \
      | grep -oE 'Electron/[0-9]+\.[0-9]+\.[0-9]+' | cut -d/ -f2 | sort -u | head -1 || true)"
    if [[ -z "$ELECTRON_VERSION" ]]; then
      ELECTRON_VERSION="41.3.0"
      degrade "无法从 PE 探测 Electron 版本，回退默认值 $ELECTRON_VERSION"
    else
      info "Electron 版本（从 PE 探测）: $ELECTRON_VERSION"
    fi
  fi
  info "应用版本: $APP_VERSION"
}

# ============================================================
# 步骤 3: 净化 Windows 载荷
# ============================================================
purge_windows_payload() {
  step "3/8 净化 Windows 载荷 ..."
  # 顶层 PE / DLL 一律删除（Linux 侧由 Electron runtime 提供 .so/.pak）
  find "$APP_DIR" -type f \( -iname '*.exe' -o -iname '*.dll' -o -iname '*.pdb' \) -delete

  # 平台专属原生模块目录
  rm -rf "$MODULES/@esbuild/win32-x64" \
         "$MODULES/@ffmpeg-installer/win32-x64" \
         "$MODULES/@img/sharp-win32-x64" \
         "$MODULES/node-pty/prebuilds/win32-x64" \
         "$MODULES/node-pty/prebuilds/win32-arm64" \
         "$MODULES/node-pty/prebuilds/darwin-x64" \
         "$MODULES/node-pty/prebuilds/darwin-arm64" \
         "$MODULES/node-pty/build" \
         "$MODULES/onnxruntime-node/bin/napi-v3/win32" \
         "$MODULES/onnxruntime-node/bin/napi-v3/darwin"
  rm -f "$MODULES/better-sqlite3/build/Release/better_sqlite3.node"

  # 自动更新配置：Linux 无官方更新通道，移除以免误下载 Windows 包
  rm -f "$APP_DIR/resources/app-update.yml" "$APP_DIR/resources/app/package.json.bak"

  if [[ ! -d "$MODULES/onnxruntime-node/bin/napi-v3/linux/x64" ]]; then
    degrade "onnxruntime-node 缺少 linux/x64 NAPI 预编译，本地推理功能可能不可用"
  else
    info "onnxruntime-node 保留包内自带 linux/x64 (NAPI)"
  fi
  info "Windows PE/DLL 与 win32 原生模块已清理"
}

# ============================================================
# 步骤 4a: 可选 AppImage 基底（复用完好的 Linux ELF 运行时）
# ============================================================
BASE_ICON=""

apply_appimage_base() {
  local ai abs root
  ai="$BASE_REF"
  [[ -f "$ai" ]] || die "-b 指定的 AppImage 不存在: $ai"
  abs="$(readlink -f "$ai")"
  chmod +x "$abs" 2>/dev/null || true

  step "4/8 复用 AppImage 的 Linux 运行时基底 ..."
  rm -rf "$AI_DIR"
  mkdir -p "$AI_DIR"
  ( cd "$AI_DIR" && "$abs" --appimage-extract >/dev/null 2>&1 ) || die "AppImage 解包失败: $ai"
  root="$AI_DIR/squashfs-root"
  [[ -d "$root" ]] || die "AppImage 解包后缺少 squashfs-root"
  [[ -x "$root/Open Design" ]] || die "AppImage 内缺少 Linux 主程序 Open Design"

  # 顶层 Linux Electron 运行时（去掉 AppImage 特有的 AppRun/desktop/图标链接）
  rm -rf "$LINUX_RUNTIME_DIR"
  mkdir -p "$LINUX_RUNTIME_DIR"
  cp -a "$root/." "$LINUX_RUNTIME_DIR/"
  rm -f "$LINUX_RUNTIME_DIR/AppRun" "$LINUX_RUNTIME_DIR/Open Design.desktop" \
        "$LINUX_RUNTIME_DIR/Open Design.png" "$LINUX_RUNTIME_DIR/.DirIcon" \
        "$LINUX_RUNTIME_DIR/resources/app-update.yml"
  rm -rf "${LINUX_RUNTIME_DIR:?}/usr"

  # 内置 Node / vela / opencode（Linux ELF）回填业务载荷
  local bin="$APP_DIR/resources/open-design/bin"
  mkdir -p "$bin/libexec/opencode"
  for f in node vela; do
    [[ -f "$root/resources/open-design/bin/$f" ]] && cp -a "$root/resources/open-design/bin/$f" "$bin/$f"
  done
  [[ -f "$root/resources/open-design/bin/libexec/opencode/opencode" ]] && \
    cp -a "$root/resources/open-design/bin/libexec/opencode/opencode" "$bin/libexec/opencode/opencode"

  # Linux 原生模块回填（版本与基底一致，且均为 ELF）
  local src_nm="$root/resources/app/node_modules" item
  for item in better-sqlite3/build/Release/better_sqlite3.node \
              node-pty/build/Release/pty.node \
              node-pty/build/Release/spawn-helper \
              node-pty/prebuilds/linux-x64 \
              @img/sharp-linux-x64 @img/sharp-libvips-linux-x64 \
              @esbuild/linux-x64 @ffmpeg-installer/linux-x64 \
              @next/swc-linux-x64-gnu onnxruntime-node; do
    if [[ -e "$src_nm/$item" ]]; then
      mkdir -p "$(dirname "$MODULES/$item")"
      cp -a "$src_nm/$item" "$MODULES/$item" 2>/dev/null || true
    fi
  done
  # node-pty 的 prebuilds 加载路径
  if [[ -f "$MODULES/node-pty/build/Release/pty.node" ]]; then
    mkdir -p "$MODULES/node-pty/prebuilds/linux-x64"
    cp -f "$MODULES/node-pty/build/Release/pty.node" "$MODULES/node-pty/prebuilds/linux-x64/pty.node"
    [[ -f "$MODULES/node-pty/build/Release/spawn-helper" ]] && \
      cp -f "$MODULES/node-pty/build/Release/spawn-helper" "$MODULES/node-pty/prebuilds/linux-x64/spawn-helper"
  fi

  # 官方多尺寸图标
  local icon
  icon="$(find "$root/usr/share/icons" -type f -name '*.png' -size +10k -print -quit 2>/dev/null || true)"
  if [[ -n "$icon" ]]; then
    BASE_ICON="$icon"
    info "复用基底官方图标: $(basename "$icon")"
  fi

  info "Linux 运行时基底就绪（跳过 Electron 下载与原生模块编译）"
}

# ============================================================
# 步骤 4b: 默认路径 —— npm 平台包替换 + 本机编译
# ============================================================
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
  info "已安装 ${name}@${ver}"
}

# 从源包各主包的 optionalDependencies 动态解析 linux-x64 平台包及版本
resolve_linux_packages() {
  local out="$WORK_DIR/linux-packages.txt"
  python3 - "$MODULES" "$APP_DIR/resources/app/package.json" > "$out" <<'PYEOF'
import json, os, sys
root, app_pkg = sys.argv[1], sys.argv[2]
def load(name):
    with open(os.path.join(root, *name.split("/"), "package.json"), encoding="utf-8") as fh:
        return json.load(fh)
def emit(name, ver):
    if ver:
        print(f"{name}|{ver.lstrip('^~>=< ')}")
want = {
    "sharp": ("@img/sharp-linux-x64", "@img/sharp-libvips-linux-x64"),
    "esbuild": ("@esbuild/linux-x64",),
    "@ffmpeg-installer/ffmpeg": ("@ffmpeg-installer/linux-x64",),
}
for main, names in want.items():
    try:
        opt = load(main).get("optionalDependencies", {})
    except Exception:
        continue
    for name in names:
        emit(name, opt.get(name))
# 发布态精简包只带预编译 .node，不含 binding.gyp / src，本机无法编译；
# 需下载同版本完整 npm 包替换后再编译（N-API 模块，产物跨 Node ABI 可用）
try:
    deps = json.load(open(app_pkg, encoding="utf-8")).get("dependencies", {})
except Exception:
    deps = {}
for name in ("better-sqlite3", "node-pty"):
    ver = deps.get(name)
    if not ver:
        try:
            ver = load(name)["version"]
        except Exception:
            ver = None
    emit(name, ver)
PYEOF
  cat "$out"
}

# Electron 原生模块必须用与 Electron 一致的 Node ABI 编译：系统 Node 20 的
# NODE_MODULE_VERSION 为 115，而 Electron 41 内置 Node 24 为 145；用系统 headers
# 编译出的 .node 会在 Electron 里报 ABI 不匹配。该下载可降级，失败回退系统 headers。
fetch_electron_headers() {
  local url="https://artifacts.electronjs.org/headers/dist/v${ELECTRON_VERSION}/node-v${ELECTRON_VERSION}-headers.tar.gz"
  local zip="$CACHE_DIR/node-v${ELECTRON_VERSION}-headers.tar.gz"
  HDR_DIR="$WORK_DIR/electron-headers"
  if [[ ! -s "$zip" ]]; then
    info "下载 Electron ${ELECTRON_VERSION} headers ..."
    if ! curl -fL --retry 2 --connect-timeout 15 --max-time 90 -o "${zip}.part" "$url" 2>/dev/null; then
      rm -f "${zip}.part"
      return 1
    fi
    mv "${zip}.part" "$zip"
  fi
  rm -rf "$HDR_DIR"
  mkdir -p "$HDR_DIR"
  tar -xzf "$zip" -C "$HDR_DIR" --strip-components=1 || return 1
  [[ -f "$HDR_DIR/include/node/node_version.h" ]] || return 1
  return 0
}

linuxify_native_modules() {
  step "4/8 原生模块 Linux 化 ..."
  local list="$WORK_DIR/linux-packages.txt" name ver dest
  resolve_linux_packages >/dev/null
  if [[ ! -s "$list" ]]; then
    degrade "未能从源包解析 linux-x64 平台包版本，skip 平台包替换"
  else
    while IFS='|' read -r name ver; do
      [[ -n "$name" && -n "$ver" ]] || continue
      dest="$MODULES/$name"
      install_npm_pkg "$name" "$ver" "$dest" || degrade "替换 $name@$ver 失败"
    done < "$list"
  fi

  # better-sqlite3 / node-pty：上一步已用完整 npm 包替换精简包（含 binding.gyp + src）。
  # 必须用 Electron 对应版本的 Node headers 编译，否则 ABI 不匹配（见 fetch_electron_headers）。
  local nodedir="/usr"
  if fetch_electron_headers; then
    nodedir="$HDR_DIR"
    info "使用 Electron ${ELECTRON_VERSION} headers 编译原生模块（ABI 145）"
  else
    degrade "Electron headers 获取失败，回退系统 Node headers：原生模块可能与 Electron ABI 不匹配"
  fi

  local bs="$MODULES/better-sqlite3"
  if [[ -d "$bs" ]]; then
    rm -rf "$bs/build"
    if ( cd "$bs" && npm_config_build_from_source=true npx --yes node-gyp@11 rebuild --nodedir="$nodedir" >/dev/null 2>&1 ); then
      info "better-sqlite3: 用 Electron headers 编译成功"
    else
      degrade "better-sqlite3 本机编译失败：daemon 本地数据库功能不可用"
    fi
  fi

  # node-pty：完整包自带的 linux-x64 预编译针对标准 Node，同样需按 Electron ABI 重编译
  local pty="$MODULES/node-pty"
  local out="$pty/prebuilds/linux-x64"
  if [[ -d "$pty" ]]; then
    rm -rf "$pty/build" "$out"
    mkdir -p "$out"
    if ( cd "$pty" && npm_config_build_from_source=true npx --yes node-gyp@11 rebuild --nodedir="$nodedir" >/dev/null 2>&1 ); then
      cp -f "$pty/build/Release/pty.node" "$out/pty.node" || true
      if [[ -f "$pty/build/Release/spawn-helper" ]]; then
        cp -f "$pty/build/Release/spawn-helper" "$out/spawn-helper"
        chmod 0755 "$out/spawn-helper"
      fi
      info "node-pty 已编译到 prebuilds/linux-x64"
    else
      degrade "node-pty 编译失败：内置终端功能不可用"
    fi
  fi
}

# ============================================================
# 步骤 5a: 下载 Electron linux-x64 runtime
# ============================================================
download_electron() {
  step "5/8 获取 Electron ${ELECTRON_VERSION} (linux-x64) ..."
  local zip="$CACHE_DIR/electron-v${ELECTRON_VERSION}-linux-x64.zip"
  if [[ -x "$LINUX_RUNTIME_DIR/electron" || -x "$LINUX_RUNTIME_DIR/Open Design" ]]; then
    info "复用已解压的 Electron runtime"
    return 0
  fi
  download "https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-linux-x64.zip" "$zip"
  rm -rf "$LINUX_RUNTIME_DIR"
  mkdir -p "$LINUX_RUNTIME_DIR"
  unzip -q "$zip" -d "$LINUX_RUNTIME_DIR" || { rm -rf "$LINUX_RUNTIME_DIR"; die "Electron 解压失败"; }
  [[ -x "$LINUX_RUNTIME_DIR/electron" ]] || die "Electron runtime 缺少 electron 可执行文件"
  info "Electron runtime 就绪"
}

# ============================================================
# 步骤 5b: sidecar 可选二进制（vela / opencode）
# ============================================================
prepare_sidecar_bin() {
  local bin="$APP_DIR/resources/open-design/bin"
  mkdir -p "$bin/libexec/opencode"

  if [[ -n "${VELA_BIN:-}" && -f "$VELA_BIN" ]]; then
    cp -f "$VELA_BIN" "$bin/vela"; chmod 0755 "$bin/vela"
    info "vela: 使用自备 Linux 二进制"
  elif [[ -f "$bin/vela" ]]; then
    info "vela: 复用基底内置 Linux 二进制"
  else
    degrade "vela 无公开 Linux 构建：云同步/遥测相关功能不可用（可用 VELA_BIN 自备）"
  fi

  if [[ -n "${OPENCODE_BIN:-}" && -f "$OPENCODE_BIN" ]]; then
    cp -f "$OPENCODE_BIN" "$bin/libexec/opencode/opencode"
    chmod 0755 "$bin/libexec/opencode/opencode"
    info "opencode: 使用自备 Linux 二进制"
  elif [[ -f "$bin/libexec/opencode/opencode" ]]; then
    info "opencode: 复用基底内置 Linux 二进制"
  else
    degrade "内置 opencode 不可用：请在 PATH 安装 opencode 或设 OPENCODE_BIN（agent 兜底功能降级）"
  fi
}

# ============================================================
# 步骤 6: 组装 /opt/OpenDesign
# ============================================================
assemble_app() {
  step "6/8 组装 ${INSTALL_DIR} ..."
  # 直接 mv 运行时与业务载荷，避免大目录重复复制占用磁盘（源包解开后 >1.5G）
  rm -rf "$STAGE"
  mkdir -p "$STAGE/opt"
  mv "$LINUX_RUNTIME_DIR" "$STAGE_ROOT"
  rm -rf "${STAGE_ROOT:?}/resources" "${STAGE_ROOT:?}/usr"
  rm -f "$STAGE_ROOT/AppRun" "$STAGE_ROOT/Open Design.desktop" \
        "$STAGE_ROOT/Open Design.png" "$STAGE_ROOT/.DirIcon"

  # 主程序统一命名为 "Open Design"（Windows 官方与 AppImage 均用此名）
  if [[ -f "$STAGE_ROOT/electron" && ! -f "$STAGE_ROOT/Open Design" ]]; then
    mv "$STAGE_ROOT/electron" "$STAGE_ROOT/Open Design"
  fi
  [[ -x "$STAGE_ROOT/Open Design" ]] || die "组装后缺少 Linux 主程序 Open Design"
  chmod 0755 "$STAGE_ROOT/Open Design"

  # 业务载荷：以官方 Windows 发布态 resources/ 为准
  mv "$APP_DIR/resources" "$STAGE_ROOT/resources"
  [[ -f "$STAGE_ROOT/resources/app/prebundled/packaged-main.mjs" ]] || die "组装后缺少 packaged-main.mjs"
  [[ -d "$STAGE_ROOT/resources/open-design-web-standalone" ]] || die "组装后缺少 web-standalone"

  # config 保持官方原值（namespace 参与 launcher payload 一致性校验，不改）
  chmod 4755 "$STAGE_ROOT/chrome-sandbox" 2>/dev/null || true

  # 完整 npm 包（node-pty 等）在 Linux 化阶段会重新带入 win32 预编译，
  # 组装后统一清理一次并复核；这些文件在 Linux 上不会被加载
  local left
  find "$STAGE_ROOT" -type f \( -iname '*.exe' -o -iname '*.dll' -o -iname '*.pdb' \) -delete
  rm -rf "${STAGE_ROOT:?}/resources/app/node_modules/node-pty/prebuilds/win32-x64" \
         "${STAGE_ROOT:?}/resources/app/node_modules/node-pty/prebuilds/win32-arm64" \
         "${STAGE_ROOT:?}/resources/app/node_modules/node-pty/prebuilds/darwin-x64" \
         "${STAGE_ROOT:?}/resources/app/node_modules/node-pty/prebuilds/darwin-arm64" \
         "${STAGE_ROOT:?}/resources/app/node_modules/node-pty/third_party/conpty"
  left="$(find "$STAGE_ROOT" -type f \( -iname '*.exe' -o -iname '*.dll' -o -iname '*.pdb' \) -print | head -20 || true)"
  [[ -z "$left" ]] || degrade "组装后仍有 Windows 残留: $left"

  # 断链清理
  local lnk target
  while IFS= read -r -d '' lnk; do
    target="$(readlink "$lnk")"
    [[ "$target" == /* ]] || rm -f "$lnk"
  done < <(find "$STAGE_ROOT" -type l -print0) 2>/dev/null || true

  info "应用目录就绪: $STAGE_ROOT"
}

# ============================================================
# 步骤 7: 图标 / desktop / 维护脚本 / copyright
# ============================================================
make_placeholder_icon() {
  python3 - "$1" <<'PYEOF'
import struct, sys, zlib
w = h = 512
def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
raw = bytearray()
for y in range(h):
    raw.append(0)
    for x in range(w):
        raw += bytes((int(8 + 24 * x / w), int(130 + 70 * y / h), int(190 + 40 * (1 - x / w)), 255))
png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
png += chunk(b"IEND", b"")
with open(sys.argv[1], "wb") as fh:
    fh.write(png)
PYEOF
}

make_icons() {
  step "7/8 生成图标与桌面入口 ..."
  local src=""
  if [[ -n "$ICON_REF" ]]; then
    [[ -f "$ICON_REF" ]] || die "-i 指定的图标不存在: $ICON_REF"
    src="$ICON_REF"
  elif [[ -n "$BASE_ICON" ]]; then
    src="$BASE_ICON"
  elif [[ -f "$AI_DIR/squashfs-root/usr/share/icons/hicolor/1024x1024/apps/Open Design.png" ]]; then
    src="$AI_DIR/squashfs-root/usr/share/icons/hicolor/1024x1024/apps/Open Design.png"
  fi
  if [[ -z "$src" ]]; then
    src="$WORK_DIR/placeholder-icon.png"
    make_placeholder_icon "$src"
    degrade "未提供官方图标，使用渐变占位图标（可用 -i 或 -b 指定）"
  fi

  local sz dir
  for sz in 16 24 32 48 64 96 128 256 512 1024; do
    dir="$STAGE/usr/share/icons/hicolor/${sz}x${sz}/apps"
    mkdir -p "$dir"
    cp -f "$src" "$dir/${APP_NAME}.png"
  done
  mkdir -p "$STAGE/usr/share/pixmaps"
  cp -f "$src" "$STAGE/usr/share/pixmaps/${APP_NAME}.png"
  info "图标已安装（hicolor 多尺寸）"
}

write_desktop_entries() {
  mkdir -p "$STAGE/usr/bin" "$STAGE/usr/share/applications"
  cat > "$STAGE/usr/bin/$APP_NAME" <<SHEOF
#!/bin/sh
export LD_LIBRARY_PATH="${INSTALL_DIR}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "${INSTALL_DIR}/Open Design" "\$@"
SHEOF
  chmod 0755 "$STAGE/usr/bin/$APP_NAME"

  cat > "$STAGE/usr/share/applications/$APP_NAME.desktop" <<DESKEOF
[Desktop Entry]
Name=Open Design
Comment=Local-first design product: design skills + design systems driven by your code-agent CLI
Comment[zh_CN]=本地优先的设计工作台：由已安装的代码智能体 CLI 驱动
Exec=/usr/bin/$APP_NAME %U
Terminal=false
Type=Application
Icon=$APP_NAME
StartupWMClass=Open Design
Categories=Development;Graphics;
DESKEOF
  chmod 0644 "$STAGE/usr/share/applications/$APP_NAME.desktop"
}

write_maintainer_scripts() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/postinst" <<'SHEOF'
#!/bin/sh
set -e
SANDBOX=/opt/OpenDesign/chrome-sandbox
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
Upstream-Name: Open Design
Source: https://github.com/nexu-io/open-design

Files: *
Copyright: Nexu IO / Open Design contributors
License: Apache-2.0
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 .
     http://www.apache.org/licenses/LICENSE-2.0
 .
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.

Files: resources/app/node_modules/*
Copyright: respective upstream package authors
License: various
 Third-party npm packages retain their own licenses; see each package's
 LICENSE file. Electron runtime is distributed under the MIT license.
CPEOF
  chmod 0644 "$dir/copyright"
}

# ============================================================
# 步骤 8: 打包
# ============================================================
DEB_DEPENDS="libasound2t64 | libasound2, libatk-bridge2.0-0, libatk1.0-0, libatspi2.0-0, libcairo2, libcups2, libdbus-1-3, libdrm2, libexpat1, libgbm1, libglib2.0-0, libgtk-3-0, libnotify4, libnspr4, libnss3, libpango-1.0-0, libsecret-1-0, libuuid1, libx11-6, libxcb1, libxcomposite1, libxdamage1, libxext6, libxfixes3, libxkbcommon0, libxrandr2, libxss1, libxtst6, xdg-utils"

build_deb() {
  step "8/8 构建 deb ..."
  # 直接在 STAGE 上放置 DEBIAN，避免再复制一份 1G+ 应用目录
  local root="$STAGE"
  mkdir -p "$root/DEBIAN"
  local size
  size="$(du -sk "$root/opt" "$root/usr" 2>/dev/null | awk '{s+=$1} END {print s}')"
  cat > "$root/DEBIAN/control" <<CTLEOF
Package: $APP_NAME
Version: $APP_VERSION
Section: utils
Priority: optional
Architecture: amd64
Maintainer: port-linux <noreply@localhost>
Installed-Size: $size
Depends: $DEB_DEPENDS
Homepage: https://open-design.ai
Description: Open Design desktop client (unofficial Linux port)
 Local-first design product that detects your installed code-agent CLI,
 runs design skills + design systems and streams artifacts into a
 sandboxed preview. Ported from the upstream Windows x64 release.
CTLEOF
  write_maintainer_scripts "$root/DEBIAN"
  chmod 0644 "$root/DEBIAN/control"
  chmod 0755 "$STAGE/usr/bin/$APP_NAME"

  local out="$OUT_DIR/${APP_NAME}_${APP_VERSION}_amd64.deb"
  rm -f "$out"
  if command -v dpkg-deb >/dev/null 2>&1; then
    # md5sums 供 dpkg -V 校验
    ( cd "$root" && find . -type f ! -path './DEBIAN/*' -printf '%P\0' | sort -z | xargs -0 md5sum > DEBIAN/md5sums )
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
  step "8/8 构建 rpm ..."
  local top="$WORK_DIR/rpmbuild"
  rm -rf "$top"
  mkdir -p "$top"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
  local spec="$top/SPECS/$APP_NAME.spec"
  # spec 内路径一律用脚本变量展开，避免与 INSTALL_DIR / APP_NAME 常量失配。
  # %install 用 tar 显式排除 deb 专属的 DEBIAN/（-p all 时 build_deb 会写入该目录），
  # 比「整体复制后删除」更干净，也不会把 md5sums/维护脚本带进 rpm。
  cat > "$spec" <<SPECEOF
Name: $APP_NAME
Version: $APP_VERSION
Release: 1
Summary: Open Design desktop client (unofficial Linux port)
License: Apache-2.0
BuildArch: x86_64
# 跨发行版移植包：不自动扫描 ELF 依赖，运行库清单见 deb control 的 Depends
AutoReqProv: no

%description
Local-first design product, ported from the upstream Windows x64 release
to Linux using the official Electron linux-x64 runtime.

%install
rm -rf "%{buildroot}"
mkdir -p "%{buildroot}"
# tar 保留符号链接与权限位（含 chrome-sandbox 的 SUID），并排除 deb 控制文件
tar -C "$STAGE" --exclude=./DEBIAN -cf - . | tar -C "%{buildroot}" -xf -

%files
$INSTALL_DIR
/usr/bin/$APP_NAME
/usr/share/applications/$APP_NAME.desktop
/usr/share/icons/hicolor
/usr/share/pixmaps/$APP_NAME.png
/usr/share/doc/$APP_NAME

%post
SANDBOX=$INSTALL_DIR/chrome-sandbox
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
  if ! rpmbuild --define "_topdir $top" -bb "$spec" > "$WORK_DIR/rpmbuild.log" 2>&1; then
    warn "rpmbuild 失败，跳过 rpm（日志: $WORK_DIR/rpmbuild.log）"
    tail -5 "$WORK_DIR/rpmbuild.log" >&2 || true
    return 0
  fi
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
  step "0/8 初始化"
  info "构建目标: $BUILD_TARGET"
  info "工作目录: $BUILD_ROOT"
  [[ -n "$BASE_REF" ]] && info "AppImage 基底: $BASE_REF"

  probe_source
  verify_checksum
  extract_nsis
  detect_versions
  purge_windows_payload

  if [[ -n "$BASE_REF" ]]; then
    apply_appimage_base
  else
    linuxify_native_modules
    download_electron
  fi
  prepare_sidecar_bin
  assemble_app
  make_icons
  write_desktop_entries
  write_copyright "$STAGE/usr/share/doc/$APP_NAME"

  case "$BUILD_TARGET" in
    deb) build_deb ;;
    rpm) build_rpm ;;
    all) build_deb; build_rpm ;;
  esac

  print_summary
}

main "$@"
