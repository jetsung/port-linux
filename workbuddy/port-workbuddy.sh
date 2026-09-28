#!/usr/bin/env bash
# port-workbuddy.sh — 将腾讯 WorkBuddy macOS 版移植到 Linux（deb / rpm）
#
# 基底合并模式：以官方 Linux rpm (5.5.6) 为基底，将 macOS 新版 zip (5.6.2) 的
# app.asar / app.asar.unpacked 合并入基底，复用基底的 Electron 37 运行时与
# 完整的 Linux 原生模块，再按需用 npm 的 linux-x64 包覆盖 sandbox 等新增版本。
#
# 用法:
#   ./port-workbuddy.sh                              # 自动探测当前目录 rpm + zip
#   ./port-workbuddy.sh -p all                       # 同时打 deb 和 rpm
#   ./port-workbuddy.sh -p deb WorkBuddy-darwin-x64-*.zip
#   ./port-workbuddy.sh -s "https://.../WorkBuddy-darwin-x64-*.zip"  # 从 URL 下载新版
#
# 依赖: unzip, tar, rpm2cpio, cpio, node, npx, curl/wget; 打 deb 需 dpkg-deb; 打 rpm 需 rpmbuild

usage() {
  cat <<'EOF'
port-workbuddy.sh — 将腾讯 WorkBuddy macOS 版移植到 Linux（deb / rpm）

基底合并模式：以官方 Linux rpm 为基底，将 macOS 新版 zip 的 app.asar
合并入基底，复用基底的 Electron 运行时与 Linux 原生模块。

用法:
  ./port-workbuddy.sh                              # 自动探测当前目录 rpm + zip
  ./port-workbuddy.sh -p all                       # 同时打 deb 和 rpm
  ./port-workbuddy.sh -p deb WorkBuddy-darwin-x64-*.zip
  ./port-workbuddy.sh -s "https://.../WorkBuddy-darwin-x64-*.zip"  # 从 URL 下载新版

选项:
  -p, --platform rpm|deb|all   构建目标；省略时按当前 OS 自动检测
  -s, --source PATH|URL        源 zip：本地路径或下载地址；省略时自动探测当前目录
  -b, --base PATH              基底 rpm 路径；省略时自动探测 WorkBuddy-linux-x64-rpm-*.rpm
  -e, --electron VERSION       Electron runtime 版本（未使用，基底已含运行时，仅作信息）
  -v, --pkgver VERSION         上游版本号；省略时从源文件名提取
  -h, --help                   显示本帮助

环境变量:
  DEBUG=1                      调试模式（set -eux，打印每条命令）
  IS_CHINA=1                   中国网络环境，下载走 CDN 加速
  CDN=<url>                    CDN 前缀地址（默认 https://fastfile.asfd.cn/），
                               形式: <CDN>/<完整原始 URL>
  NPM_CONFIG_USERCONFIG        npm 配置文件路径（默认 ~/.npmrc），
                               其中的 registry 用于下载 node 依赖

依赖: unzip, tar, rpm2cpio, cpio, node, npx, curl/wget; 打 deb 需 dpkg-deb; 打 rpm 需 rpmbuild
EOF
}

if [[ -n "$DEBUG" ]]; then
  set -eux
else
  set -euo pipefail
fi

# ---------- 颜色输出 ----------
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_NC='\033[0m'
info() { echo -e "${C_GREEN}[信息]${C_NC} $*"; }
warn() { echo -e "${C_YELLOW}[警告]${C_NC} $*"; }
step() { echo -e "${C_BLUE}[步骤]${C_NC} $*"; }
die() {
  echo -e "${C_RED}[失败]${C_NC} $*" >&2
  exit 1
}

# ---------- 依赖检查 ----------
for cmd in unzip tar node npx; do
  command -v "$cmd" >/dev/null 2>&1 || die "缺少依赖命令: $cmd"
done
command -v rpm2cpio >/dev/null 2>&1 || die "缺少依赖命令: rpm2cpio (Fedora: sudo dnf install rpm)"
command -v cpio >/dev/null 2>&1 || die "缺少依赖命令: cpio"
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  die "缺少下载器: curl 或 wget"
fi

# 与 Darwin 5.6.2 的 cli/package.json optionalDependencies 一致，sandbox 需 linux-x64 覆盖
SANDBOX_VER="5.6.10"
NODE_PTY_VER="1.2.0-beta.14"
INSTALL_PREFIX="/opt/WorkBuddy"

# ---------- npm 镜像（从 ~/.npmrc 读取 registry） ----------
NPM_REGISTRY="https://registry.npmjs.org"
NPMRC_FILE="${NPM_CONFIG_USERCONFIG:-$HOME/.npmrc}"
if [[ -f "$NPMRC_FILE" ]]; then
  configured_registry=$(sed -n 's/^[[:space:]]*registry[[:space:]]*=[[:space:]]*//p' "$NPMRC_FILE" | head -1)
  if [[ "$configured_registry" == http://* || "$configured_registry" == https://* ]]; then
    NPM_REGISTRY="${configured_registry%/}"
    info "使用 npm 镜像: $NPM_REGISTRY (来自 $NPMRC_FILE)"
  fi
fi

BUILD_PLATFORM=""
SOURCE_REF=""
BASE_REF=""
PKG_VER=""
PKG_HASH=""

# ---------- 平台自动检测 ----------
detect_platform() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
    fedora | rhel | centos | rocky | alma | opensuse* | tumbleweed | leap | amzn | sles | suse)
      echo "rpm"
      ;;
    debian | ubuntu | linuxmint | kali | elementary | pop | raspbian | deepin)
      echo "deb"
      ;;
    *)
      if command -v rpm >/dev/null 2>&1 && ! command -v dpkg >/dev/null 2>&1; then
        echo "rpm"
      else
        echo "deb"
      fi
      ;;
    esac
  else
    if command -v rpmbuild >/dev/null 2>&1; then
      echo "rpm"
    else
      echo "deb"
    fi
  fi
}

# ---------- 参数解析 ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
  -p | --platform)
    BUILD_PLATFORM="$2"
    shift 2
    ;;
  -p=* | --platform=*)
    BUILD_PLATFORM="${1#*=}"
    shift
    ;;
  -b | --base)
    BASE_REF="$(readlink -f "$2")"
    shift 2
    ;;
  -b=* | --base=*)
    BASE_REF="$(readlink -f "${1#*=}")"
    shift
    ;;
  -e | --electron)
    shift 2
    ;;
  -e=* | --electron=*)
    shift
    ;;
  -s | --source)
    SOURCE_REF="$2"
    shift 2
    ;;
  -s=* | --source=*)
    SOURCE_REF="${1#*=}"
    shift
    ;;
  -v | --pkgver)
    PKG_VER="$2"
    shift 2
    ;;
  -v=* | --pkgver=*)
    PKG_VER="${1#*=}"
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *.zip)
    SOURCE_REF="$(readlink -f "$1")"
    shift
    ;;
  *.rpm)
    BASE_REF="$(readlink -f "$1")"
    shift
    ;;
  -*) usage >&2; die "未知选项: $1" ;;
  *) die "未知参数: $1" ;;
  esac
done

if [[ -z "$BUILD_PLATFORM" ]]; then
  BUILD_PLATFORM="$(detect_platform)"
fi
case "$BUILD_PLATFORM" in
rpm)
  BUILD_RPM=1
  BUILD_DEB=0
  ;;
deb)
  BUILD_RPM=0
  BUILD_DEB=1
  ;;
all)
  BUILD_RPM=1
  BUILD_DEB=1
  ;;
*) die "无效平台: $BUILD_PLATFORM (可选: rpm, deb, all)" ;;
esac

CWD="$(pwd -P)"
if [[ -z "$SOURCE_REF" ]]; then
  for f in "$CWD"/WorkBuddy-darwin-x64-*.zip; do
    [[ -f "$f" ]] && SOURCE_REF="$(readlink -f "$f")" && {
      info "自动探测源 zip: $SOURCE_REF"
      break
    }
  done
fi
[[ -n "$SOURCE_REF" ]] || die "未找到源 zip。用法: $0 [-p rpm|deb|all] <WorkBuddy-darwin-x64-*.zip>"
if [[ -z "$BASE_REF" ]]; then
  for f in "$CWD"/WorkBuddy-linux-x64-rpm-*.rpm; do
    [[ -f "$f" ]] && BASE_REF="$(readlink -f "$f")" && {
      info "自动探测基底 rpm: $BASE_REF"
      break
    }
  done
fi
[[ -n "$BASE_REF" ]] || die "未找到基底 rpm。用法: $0 <WorkBuddy-darwin-x64-*.zip> <WorkBuddy-linux-x64-rpm-*.rpm>"
[[ -f "$SOURCE_REF" ]] || die "源 zip 不存在: $SOURCE_REF"
[[ -f "$BASE_REF" ]] || die "基底 rpm 不存在: $BASE_REF"

extract_version() {
  local f="$1" base ver_str
  base="$(basename "$f")"
  base="${base%.zip}"
  ver_str="${base#WorkBuddy-darwin-x64-}"
  echo "$ver_str"
}

is_url() { [[ "$1" == http://* || "$1" == https://* ]]; }

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ROOT="$SCRIPT_DIR/build"
CACHE_DIR="$ROOT/cache"
OUT_DIR="$ROOT/out"
mkdir -p "$CACHE_DIR" "$OUT_DIR"

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

download() {
  local url="$1" output="$2"
  if [[ -f "$output" ]]; then
    info "复用已缓存: $(basename "$output")"
    return 0
  fi
  if is_china && cdn_applicable "$url"; then
    local cdn_url="${CDN_URL}${url}"
    info "下载 (CDN: $CDN_URL) $url ..."
    if command -v curl >/dev/null 2>&1; then
      curl --fail --location --retry 3 --output "$output" "$cdn_url" && return 0
    else
      wget -O "$output" "$cdn_url" && return 0
    fi
    rm -f "$output"
    warn "CDN 下载失败，回退直连: $url"
  fi
  info "下载 $url ..."
  if command -v curl >/dev/null 2>&1; then
    curl --fail --location --retry 3 --output "$output" "$url" || die "下载失败: $url"
  else
    wget -O "$output" "$url" || die "下载失败: $url"
  fi
}

echo
echo -e "${C_BLUE}════════════════════════════════════════════════════${C_NC}"
echo -e "${C_BLUE}  WorkBuddy 跨平台移植（基底合并）${C_NC}"
echo -e "${C_BLUE}════════════════════════════════════════════════════${C_NC}"
echo "  基底 rpm:    $BASE_REF"
echo "  新版 zip:    $SOURCE_REF"
echo "  目标平台:    $BUILD_PLATFORM (deb=$BUILD_DEB rpm=$BUILD_RPM)"
echo

# 提取版本号
if [[ -z "$PKG_VER" ]]; then
  VER_STR="$(extract_version "$SOURCE_REF")"
  PKG_VER="${VER_STR%-*}"
  PKG_HASH="${VER_STR##*-}"
  [[ -n "$PKG_VER" ]] || die "无法从文件名提取版本号: $(basename "$SOURCE_REF")"
  info "版本: $PKG_VER (hash: ${PKG_HASH:-未知})"
fi
DEB_VER="${PKG_VER}${PKG_HASH:+-$PKG_HASH}"
RPM_REL="1${PKG_HASH:+.${PKG_HASH}}"

WORK="$ROOT/tmp.$(date +%s).$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
info "工作目录: $WORK"


# ============================================================
# 步骤 1: 解基底 rpm → Linux 完整运行时
# ============================================================
step "1/6 解基底 rpm (Linux 5.5.6 完整运行时) ..."
mkdir -p base_extract
rpm2cpio "$BASE_REF" 2>/dev/null | (cd base_extract && cpio -idm --quiet 2>/dev/null) || die "基底 rpm 解包失败"
BASE_APP="base_extract/opt/WorkBuddy"
[[ -d "$BASE_APP" ]] || die "基底内未找到 /opt/WorkBuddy"
# 基底包含 Electron 运行时、resources/runtime、app.asar 等完整 Linux 环境
info "基底已解包: $BASE_APP"

# 保存基底的 Linux 原生模块供后续回退（better-sqlite3 ELF 等）
BASE_BETTER_SQLITE_CACHE="$WORK/base-better-sqlite3.node"
if [[ -f "$BASE_APP/resources/app.asar.unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node" ]]; then
  cp -f "$BASE_APP/resources/app.asar.unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node" "$BASE_BETTER_SQLITE_CACHE"
fi

# ============================================================
# 步骤 2: 解新版 Darwin zip → 取 app.asar + 展开
# ============================================================
step "2/6 解新版 Darwin zip ..."
mkdir -p darwin_extract
unzip -q "$SOURCE_REF" -d darwin_extract || die "Darwin zip 解压失败"
DARWIN_RESOURCES="darwin_extract/WorkBuddy.app/Contents/Resources"
[[ -f "$DARWIN_RESOURCES/app.asar" ]] || die "Darwin 压缩包内未找到 app.asar"

# 解压新版 app.asar（与原有逻辑一致，含 sidecar 占位修复）
DARWIN_UNPACKED="$WORK/darwin_app.asar.unpacked"
mkdir -p "$(dirname "$DARWIN_UNPACKED")"
if [[ -d "$DARWIN_RESOURCES/app.asar.unpacked" ]]; then
  cp -a "$DARWIN_RESOURCES/app.asar.unpacked" "$DARWIN_UNPACKED"
else
  mkdir -p "$DARWIN_UNPACKED"
fi
asar_log="$WORK/asar-extract.log"
extracted=false
for _ in $(seq 1 50); do
  if npx --yes asar@3.2.0 extract "$DARWIN_RESOURCES/app.asar" "$DARWIN_UNPACKED" >"$asar_log" 2>&1; then
    extracted=true
    break
  fi
  missing=$(sed -n "s/.*path: '\([^']*\)'.*/\1/p" "$asar_log" | head -1)
  case "$missing" in
  "$DARWIN_RESOURCES/app.asar.unpacked/"*)
    warn "补占位: ${missing#"$DARWIN_RESOURCES/app.asar.unpacked/"}"
    mkdir -p "$(dirname "$missing")"
    touch "$missing"
    ;;
  *)
    cat "$asar_log" >&2
    die "ASAR 解压失败且无法恢复"
    ;;
  esac
done
[[ "$extracted" == true ]] || die "ASAR 解压 50 次后仍未完成"
# shellcheck disable=SC2043
for required_file in main/index.js; do
  [[ -f "$DARWIN_UNPACKED/$required_file" ]] || die "ASAR 解压不完整: 缺少 $required_file"
done
info "新版 app.asar 已解压: $DARWIN_UNPACKED"

# ============================================================
# 步骤 3: 合并新版 app.asar 到基底（复用 Linux 运行时）
# ============================================================
step "3/6 合并新版 app.asar 到基底 ..."

# 备份基底的 Linux vendor（将被 Darwin 覆盖）
BASE_VENDOR_CACHE="$WORK/base-vendor"
mkdir -p "$BASE_VENDOR_CACHE"
cp -a "$BASE_APP/resources/app.asar.unpacked/cli/vendor/genie-trash" "$BASE_VENDOR_CACHE/" 2>/dev/null || true
cp -a "$BASE_APP/resources/app.asar.unpacked/cli/vendor/ripgrep" "$BASE_VENDOR_CACHE/" 2>/dev/null || true

# 替换基底的 app.asar 与 app.asar.unpacked 为 Darwin 新版
cp -f "$DARWIN_RESOURCES/app.asar" "$BASE_APP/resources/app.asar"
rm -rf "$BASE_APP/resources/app.asar.unpacked"
cp -a "$DARWIN_UNPACKED" "$BASE_APP/resources/app.asar.unpacked"
info "已用 Darwin $PKG_VER 替换基底的 app.asar / app.asar.unpacked"

# ============================================================
# 步骤 4: Linux 化新版 unpacked（关键修复）
# ============================================================
step "4/6 Linux 化新版 unpacked ..."

ASAR_UNPACKED="$BASE_APP/resources/app.asar.unpacked"

# ---- better-sqlite3: 用基底的 ELF 回填（最可靠，Electron 37 版本一致） ----
if [[ -f "$BASE_BETTER_SQLITE_CACHE" ]]; then
  mkdir -p "$ASAR_UNPACKED/node_modules/better-sqlite3/build/Release"
  cp -f "$BASE_BETTER_SQLITE_CACHE" "$ASAR_UNPACKED/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
  info "better-sqlite3: 已从基底注入 ELF"
else
  warn "基底 better-sqlite3 ELF 缓存缺失"
fi
# 清理 darwin/win32 残留
[[ -d "$ASAR_UNPACKED/node_modules/better-sqlite3/prebuilds" ]] && find "$ASAR_UNPACKED/node_modules/better-sqlite3/prebuilds" -type f \( -name 'darwin-*' -o -name 'win32-*' \) -delete 2>/dev/null || true

# ---- node-pty: 保留 linux-x64，移除 darwin/win32 ----
for pty_root in "$ASAR_UNPACKED/node_modules/@lydell" "$ASAR_UNPACKED/cli/node_modules/@lydell"; do
  [[ -d "$pty_root" ]] || continue
  rm -rf "$pty_root/node-pty-darwin-x64" "$pty_root/node-pty-darwin-arm64" \
    "$pty_root/node-pty-win32-x64" "$pty_root/node-pty-win32-arm64" \
    "$pty_root/node-pty-linux-arm64" 2>/dev/null || true
done
if [[ -d "$ASAR_UNPACKED/node_modules/node-pty/prebuilds" ]]; then
  find "$ASAR_UNPACKED/node_modules/node-pty/prebuilds" -mindepth 1 -maxdepth 1 ! -name 'linux-x64' -exec rm -rf {} + 2>/dev/null || true
fi

# ---- vendor: 用基底的 Linux ELF 回填 ----
# genie-trash / ripgrep 从基底覆盖（若无则从 npm 兜底）
if [[ -f "$BASE_VENDOR_CACHE/genie-trash/linux-x64" ]]; then
  rm -f "$ASAR_UNPACKED/cli/vendor/genie-trash/darwin-x64"
  mkdir -p "$ASAR_UNPACKED/cli/vendor/genie-trash"
  cp -f "$BASE_VENDOR_CACHE/genie-trash/linux-x64" \
    "$ASAR_UNPACKED/cli/vendor/genie-trash/linux-x64"
  chmod 0755 "$ASAR_UNPACKED/cli/vendor/genie-trash/linux-x64"
  info "vendor/genie-trash 已从基底回填 linux-x64 ELF"
fi
if [[ -d "$BASE_VENDOR_CACHE/ripgrep/x64-linux" ]]; then
  rm -rf "$ASAR_UNPACKED/cli/vendor/ripgrep/x64-darwin"
  mkdir -p "$ASAR_UNPACKED/cli/vendor/ripgrep/x64-linux"
  cp -f "$BASE_VENDOR_CACHE/ripgrep/x64-linux/rg" \
    "$ASAR_UNPACKED/cli/vendor/ripgrep/x64-linux/rg" 2>/dev/null || true
  cp -f "$BASE_VENDOR_CACHE/ripgrep/x64-linux/ripgrep.node" \
    "$ASAR_UNPACKED/cli/vendor/ripgrep/x64-linux/ripgrep.node" 2>/dev/null || true
  chmod 0755 "$ASAR_UNPACKED/cli/vendor/ripgrep/x64-linux/rg" 2>/dev/null || true
  info "vendor/ripgrep 已从基底回填 x64-linux ELF"
fi
# 若基底无上述文件（极少），再从 npm 的 linux-x64 包兜底
if [[ ! -f "$ASAR_UNPACKED/cli/vendor/genie-trash/linux-x64" ]] || [[ ! -f "$ASAR_UNPACKED/cli/vendor/ripgrep/x64-linux/rg" ]]; then
  warn "基底 vendor 回填不完整，将在 sandbox 段尝试从 npm 补齐"
fi

# ---- sandbox: 5.6.10 需 linux-x64 ELF，基底为 5.5.5，需从 npm 下载 5.6.10 linux-x64 ----
sandbox_tgz="$CACHE_DIR/sandbox-cli-linux-x64-${SANDBOX_VER}.tgz"
download "$NPM_REGISTRY/@tencent-ai/sandbox-cli-linux-x64/-/sandbox-cli-linux-x64-${SANDBOX_VER}.tgz" "$sandbox_tgz"
tmp_sb="$(mktemp -d)"
tar -xzf "$sandbox_tgz" --strip-components=1 -C "$tmp_sb" 2>/dev/null || true
if [[ -f "$tmp_sb/bin/sandbox-center" ]]; then
  target_sandbox="$ASAR_UNPACKED/cli/vendor/sandbox/${SANDBOX_VER}"
  rm -rf "$target_sandbox"
  mkdir -p "$target_sandbox"
  cp -f "$tmp_sb/bin/sandbox-center" "$tmp_sb/bin/sandbox-cli" "$tmp_sb/bin/sandbox-cli-gc" "$tmp_sb/bin/betterleaks" "$target_sandbox/" 2>/dev/null || true
  [[ -f "$tmp_sb/bin/wb-bridge" ]] && cp -f "$tmp_sb/bin/wb-bridge" "$target_sandbox/" 2>/dev/null || true
  chmod 0755 "$target_sandbox"/sandbox-center "$target_sandbox"/sandbox-cli "$target_sandbox"/sandbox-cli-gc 2>/dev/null || true
  info "vendor/sandbox 已替换为 linux-x64 ${SANDBOX_VER} ELF"
  # 保留 tsbx_rules.json
  if [[ -f "$BASE_APP/resources/app.asar.unpacked/cli/vendor/sandbox/5.5.5/tsbx_rules.json" ]]; then
    # Darwin 5.6.10 已含规则，但为保险从基底复制
    cp -f "$BASE_APP/resources/app.asar.unpacked/cli/vendor/sandbox/5.5.5/tsbx_rules.json" "$target_sandbox/" 2>/dev/null || true
  fi
  # 清理旧 Darwin 的 5.6.10 Mach-O 残留（若新旧版本同名则已被覆盖）
else
  warn "sandbox linux-x64 ${SANDBOX_VER} 提取失败"
fi
rm -rf "$tmp_sb"

# ---- node-pty linux-x64 从 npm 确保 ----
node_pty_tgz="$CACHE_DIR/node-pty-linux-x64-${NODE_PTY_VER}.tgz"
download "$NPM_REGISTRY/@lydell/node-pty-linux-x64/-/node-pty-linux-x64-${NODE_PTY_VER}.tgz" "$node_pty_tgz"
if [[ ! -d "$ASAR_UNPACKED/node_modules/@lydell/node-pty-linux-x64" ]] || [[ ! -f "$ASAR_UNPACKED/node_modules/@lydell/node-pty-linux-x64/prebuilds/linux-x64/pty.node" ]]; then
  mkdir -p "$ASAR_UNPACKED/node_modules/@lydell/node-pty-linux-x64"
  tar -xzf "$node_pty_tgz" --strip-components=1 -C "$ASAR_UNPACKED/node_modules/@lydell/node-pty-linux-x64" 2>/dev/null || true
  info "node-pty linux-x64 已补齐"
fi

# 清理所有残余 Mach-O .node（不影响 weixinpay 等插件的非 .node 资源）
find "$ASAR_UNPACKED" -type f -name "*.node" -exec sh -c 'file "$1" 2>/dev/null | grep -q "Mach-O" && rm -f "$1"' _ {} \; 2>/dev/null || true

# ---- 可移植性补丁 ----
main_js="$ASAR_UNPACKED/main/index.js"
sed -i 's/tray\.on("right-click", () => this\.tray?\.popUpContextMenu(contextMenu))/tray.setContextMenu(contextMenu)/g' "$main_js" 2>/dev/null || true
while IFS= read -r -d '' file; do
  sed -i "s#process\.resourcesPath#'$INSTALL_PREFIX'#g" "$file"
done < <(grep -IlZR --null 'process\.resourcesPath' "$ASAR_UNPACKED" 2>/dev/null || true)
info "可移植性补丁已应用（tray + resourcesPath → $INSTALL_PREFIX）"

# ============================================================
# 步骤 5: 组装最终应用目录（复用基底的完整目录树）
# ============================================================
step "5/6 组装最终应用目录 ..."
FINAL_DIR="$WORK/final/opt/WorkBuddy"
mkdir -p "$WORK/final/opt"
cp -a base_extract/opt/WorkBuddy "$WORK/final/opt/"
# SQL：确保 resources/app.asar 已为新版
info "最终应用目录: $FINAL_DIR (基底 + Darwin $PKG_VER 合并)"

# usr/.desktop + icons 保留基底的，同时更新为新版版本信息
mkdir -p "$WORK/final/usr/bin"
cat >"$WORK/final/usr/bin/workbuddy" <<'WRAPPER'
#!/bin/sh
exec /opt/WorkBuddy/workbuddy "$@"
WRAPPER
chmod 0755 "$WORK/final/usr/bin/workbuddy"
mkdir -p "$WORK/final/usr/share/applications"
# 复用基底的 desktop 为模板并更新 Exec/Comment 与版本关联
if [[ -f base_extract/usr/share/applications/workbuddy.desktop ]]; then
  cp -f base_extract/usr/share/applications/workbuddy.desktop "$WORK/final/usr/share/applications/"
fi
# 确保 desktop 对齐原版字段（基底已为正确，此处幂等覆盖）
cat >"$WORK/final/usr/share/applications/workbuddy.desktop" <<EOF
[Desktop Entry]
Name=WorkBuddy
Exec=$INSTALL_PREFIX/workbuddy %U
Terminal=false
Type=Application
Icon=workbuddy
StartupWMClass=WorkBuddy
Comment=WorkBuddy Desktop - AI Agent Desktop Application
MimeType=x-scheme-handler/workbuddy;
Categories=Development;
EOF

# 图标：复用基底图标；若需多尺寸，从基底或新版 icon 统一生成
if [[ -d base_extract/usr/share/icons ]]; then
  mkdir -p "$WORK/final/usr/share"
  cp -a base_extract/usr/share/icons "$WORK/final/usr/share/" 2>/dev/null || true
fi
# 若缺失，则从 app.asar.unpacked/resources/icon.png 生成
if [[ ! -f "$WORK/final/usr/share/icons/hicolor/1024x1024/apps/workbuddy.png" ]]; then
  ICON_SRC="$ASAR_UNPACKED/resources/icon.png"
  for sz in 16 24 32 48 64 128 256 512 1024; do
    mkdir -p "$WORK/final/usr/share/icons/hicolor/${sz}x${sz}/apps"
    install -Dm644 "$ICON_SRC" "$WORK/final/usr/share/icons/hicolor/${sz}x${sz}/apps/workbuddy.png"
  done
fi

# 清理损坏符号链接（保留绝对路径的）
while IFS= read -r -d '' lnk; do
  target="$(readlink "$lnk")"
  [[ "$target" == /* ]] || rm -f "$lnk"
done < <(find "$WORK/final" -type l -print0) 2>/dev/null || true
# chrome-sandbox SUID 预设（deb 阶段直接设，rpm 在 %post 处理）
chmod 4755 "$WORK/final/opt/WorkBuddy/chrome-sandbox" 2>/dev/null || true
info "应用目录就绪"

# ============================================================
# 步骤 6: 打包 deb / rpm（复用基底的 control/scripts）
# ============================================================
OUT_BASE="$OUT_DIR"

# ---------- 打 deb ----------
if [[ "$BUILD_DEB" -eq 1 ]]; then
  command -v dpkg-deb >/dev/null 2>&1 || {
    warn "dpkg-deb 不可用，跳过 deb"
    BUILD_DEB=0
  }
fi
if [[ "$BUILD_DEB" -eq 1 ]]; then
  step "6/6 打包 deb ..."
  DEB_BUILD="$WORK/deb_build"
  rm -rf "$DEB_BUILD"
  mkdir -p "$DEB_BUILD/opt" "$DEB_BUILD/usr/bin" \
    "$DEB_BUILD/usr/share/applications" \
    "$DEB_BUILD/usr/share/doc/workbuddy" "$DEB_BUILD/DEBIAN"

  cp -a "$WORK/final/opt/WorkBuddy" "$DEB_BUILD/opt/WorkBuddy"
  cp -a "$WORK/final/usr/bin/workbuddy" "$DEB_BUILD/usr/bin/workbuddy"
  cp -a "$WORK/final/usr/share/applications/workbuddy.desktop" "$DEB_BUILD/usr/share/applications/"
  mkdir -p "$DEB_BUILD/usr/share/icons"
  cp -a "$WORK/final/usr/share/icons/." "$DEB_BUILD/usr/share/icons/"

  installed_size=$(du -sk "$DEB_BUILD/opt" "$DEB_BUILD/usr" 2>/dev/null | awk '{s+=$1} END {print s}')
  cat >"$DEB_BUILD/DEBIAN/control" <<EOF
Package: workbuddy
Version: ${DEB_VER}
Architecture: amd64
Maintainer: port-linux
Installed-Size: ${installed_size}
Depends: libasound2t64 | libasound2, libatk-bridge2.0-0, libatk1.0-0, libc6, libcairo2, libcups2, libdbus-1-3, libdrm2, libexpat1, libgbm1, libglib2.0-0, libgtk-3-0, libnspr4, libnss3, libpango-1.0-0, libx11-6, libxcb1, libxcomposite1, libxdamage1, libxext6, libxfixes3, libxkbcommon0, libxrandr2
Recommends: libappindicator3-1 | libayatana-appindicator3-1
Section: utils
Priority: optional
Homepage: https://www.workbuddy.cn/app
Description: Unofficial Linux package of Tencent WorkBuddy
 WorkBuddy is an AI Agent office tool from Tencent Cloud Code Assistant.
 This package ports the upstream macOS application resources to Linux (base 5.5.6 + Darwin 5.6.2).
EOF

  # 复用基底的 control 脚本（若基底为 rpm，需模拟 deb 的 postinst）
  if [[ -f base_extract/../control.tar.xz ]]; then
    mkdir -p "$DEB_BUILD/../deb_control"
    tar -xJf base_extract/../control.tar.xz -C "$DEB_BUILD/../deb_control" 2>/dev/null || true
    [[ -f "$DEB_BUILD/../deb_control/postinst" ]] && cp "$DEB_BUILD/../deb_control/postinst" "$DEB_BUILD/DEBIAN/" 2>/dev/null || true
    [[ -f "$DEB_BUILD/../deb_control/postrm" ]] && cp "$DEB_BUILD/../deb_control/postrm" "$DEB_BUILD/DEBIAN/" 2>/dev/null || true
  fi

  cat >"$DEB_BUILD/usr/share/doc/workbuddy/copyright" <<EOF
This is an unofficial redistribution/compatibility package.
WorkBuddy and its application resources are proprietary software owned by Tencent
or their respective rights holders. No additional license is granted by this package.
Upstream: https://www.workbuddy.cn/app
Packaged: Darwin $PKG_VER merged into Linux base (Electron 37)
Electron license: https://github.com/electron/electron/blob/main/LICENSE
EOF

  find "$DEB_BUILD" -type d -exec chmod 0755 {} +
  OUT_DEB="$OUT_BASE/workbuddy_${DEB_VER}_amd64.deb"
  dpkg-deb --root-owner-group --build "$DEB_BUILD" "$OUT_DEB" || die "deb 打包失败"
  info "deb 已生成: $OUT_DEB ($(du -h "$OUT_DEB" | cut -f1))"
fi

# ---------- 打 rpm ----------
if [[ "$BUILD_RPM" -eq 1 ]]; then
  command -v rpmbuild >/dev/null 2>&1 || {
    warn "rpmbuild 不可用，跳过 rpm"
    BUILD_RPM=0
  }
fi
if [[ "$BUILD_RPM" -eq 1 ]]; then
  step "6/6 打包 rpm ..."
  RPMROOT="$WORK/rpmroot"
  rm -rf "$RPMROOT"
  mkdir -p "$RPMROOT"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS,payload}

  mkdir -p "$RPMROOT/payload"
  cp -a "$WORK/final/." "$RPMROOT/payload/"

  # 只删除相对路径且目标不存在的损坏符号链接；保留指向绝对路径的符号链接
  while IFS= read -r -d '' lnk; do
    target="$(readlink "$lnk")"
    [[ "$target" == /* ]] || rm -f "$lnk"
  done < <(find "$RPMROOT/payload" -type l -print0) 2>/dev/null || true

  cat >"$RPMROOT/SPECS/workbuddy.spec" <<SPEC
Name:           workbuddy
Version:        ${PKG_VER}
Release:        ${RPM_REL}%{?dist}
Summary:        Unofficial Linux package of Tencent WorkBuddy
License:        Proprietary
URL:            https://www.workbuddy.cn/app
Vendor:         port-linux
BuildArch:      x86_64
AutoReq:        no
AutoProv:       no

Requires:       alsa-lib
Requires:       at-spi2-atk
Requires:       at-spi2-core
Requires:       atk
Requires:       cairo
Requires:       cups-libs
Requires:       dbus-libs
Requires:       expat
Requires:       glib2
Requires:       gtk3
Requires:       nspr
Requires:       nss
Requires:       pango
Requires:       libX11
Requires:       libxcb
Requires:       libXcomposite
Requires:       libXdamage
Requires:       libXext
Requires:       libXfixes
Requires:       libxkbcommon
Requires:       libXrandr
Recommends:     libappindicator-gtk3

%description
Unofficial Linux package of Tencent WorkBuddy (merged base 5.5.6 + Darwin $PKG_VER).

%prep

%build

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
cp -a $RPMROOT/payload/* %{buildroot}/

%pre
if pgrep -f '/opt/WorkBuddy/workbuddy' >/dev/null 2>&1; then
  pkill -TERM -f '/opt/WorkBuddy/workbuddy' 2>/dev/null || true
  for _ in 1 2 3 4 5; do sleep 1; pgrep -f '/opt/WorkBuddy/workbuddy' >/dev/null 2>&1 || break; done
  pkill -KILL -f '/opt/WorkBuddy/workbuddy' 2>/dev/null || true
fi

%post
if command -v update-alternatives >/dev/null 2>&1; then
  if [ -L '/usr/bin/workbuddy' ] && [ -e '/usr/bin/workbuddy' ] && [ "\$(readlink '/usr/bin/workbuddy')" != '/etc/alternatives/workbuddy' ]; then
    rm -f '/usr/bin/workbuddy'
  fi
  update-alternatives --install '/usr/bin/workbuddy' 'workbuddy' '/opt/WorkBuddy/workbuddy' 100 2>/dev/null || ln -sf '/opt/WorkBuddy/workbuddy' '/usr/bin/workbuddy' || true
else
  ln -sf '/opt/WorkBuddy/workbuddy' '/usr/bin/workbuddy' 2>/dev/null || true
fi
if ! { [[ -L /proc/self/ns/user ]] && unshare --user true; } 2>/dev/null; then
    chmod 4755 '/opt/WorkBuddy/chrome-sandbox' 2>/dev/null || true
else
    chmod 0755 '/opt/WorkBuddy/chrome-sandbox' 2>/dev/null || true
fi
command -v update-mime-database >/dev/null 2>&1 && update-mime-database /usr/share/mime 2>/dev/null || true
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications 2>/dev/null || true
if command -v apparmor_parser >/dev/null 2>&1 && [ -f '/opt/WorkBuddy/resources/apparmor-profile' ]; then
  if apparmor_parser --skip-kernel-load --debug '/opt/WorkBuddy/resources/apparmor-profile' >/dev/null 2>&1; then
    cp -f '/opt/WorkBuddy/resources/apparmor-profile' '/etc/apparmor.d/workbuddy' 2>/dev/null || true
    if ! { [ -x '/usr/bin/ischroot' ] && /usr/bin/ischroot; } 2>/dev/null; then
      apparmor_parser --replace --write-cache --skip-read-cache '/etc/apparmor.d/workbuddy' 2>/dev/null || true
    fi
  fi
fi

%preun
if [ "\$1" = "0" ]; then
  if pgrep -f '/opt/WorkBuddy/workbuddy' >/dev/null 2>&1; then
    pkill -TERM -f '/opt/WorkBuddy/workbuddy' 2>/dev/null || true
    for _ in 1 2 3 4 5; do sleep 1; pgrep -f '/opt/WorkBuddy/workbuddy' >/dev/null 2>&1 || break; done
    pkill -KILL -f '/opt/WorkBuddy/workbuddy' 2>/dev/null || true
  fi
fi

%postun
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications 2>/dev/null || true
if [ "\$1" = "0" ]; then
  if command -v update-alternatives >/dev/null 2>&1; then
    update-alternatives --remove 'workbuddy' '/opt/WorkBuddy/workbuddy' 2>/dev/null || true
  fi
fi

%files
%defattr(-,root,root,-)
"/opt/WorkBuddy"
"/usr/bin/workbuddy"
"/usr/share/applications/workbuddy.desktop"
"/usr/share/icons/hicolor/16x16/apps/workbuddy.png"
"/usr/share/icons/hicolor/24x24/apps/workbuddy.png"
"/usr/share/icons/hicolor/32x32/apps/workbuddy.png"
"/usr/share/icons/hicolor/48x48/apps/workbuddy.png"
"/usr/share/icons/hicolor/64x64/apps/workbuddy.png"
"/usr/share/icons/hicolor/128x128/apps/workbuddy.png"
"/usr/share/icons/hicolor/256x256/apps/workbuddy.png"
"/usr/share/icons/hicolor/512x512/apps/workbuddy.png"
"/usr/share/icons/hicolor/1024x1024/apps/workbuddy.png"

%changelog
* $(LC_TIME=C date '+%a %b %d %Y') ported <workbuddy@port-linux> ${PKG_VER}-${RPM_REL}
- 合并基底 Linux 5.5.6 + Darwin ${PKG_VER} 的 app.asar
- 复用基底 Electron 37 运行时与 Linux 原生模块
- 覆盖 sandbox 5.6.10 为 linux-x64 ELF
SPEC

  QA_RPATHS=0 rpmbuild -bb --define '_binary_payload w9.gzdio' \
    --define "_topdir $RPMROOT" \
    --define "__brp_check_rpaths %{nil}" \
    --define "__brp_mangle_shebangs %{nil}" \
    --define "__os_install_post %{nil}" \
    --define "_unpackaged_files_terminate_build 0" \
    "$RPMROOT/SPECS/workbuddy.spec" 2>&1 | grep -vE '^\+' || true

  RPM_FILE="$(find "$RPMROOT/RPMS" -name '*.rpm' -print -quit)"
  if [[ -n "$RPM_FILE" ]]; then
    OUT_RPM="$OUT_BASE/$(basename "$RPM_FILE")"
    cp -f "$RPM_FILE" "$OUT_RPM"
    info "rpm 已生成: $OUT_RPM ($(du -h "$OUT_RPM" | cut -f1))"
  else
    warn "rpm 构建未产出文件"
  fi
fi

echo
info "产物目录: $OUT_DIR"
info "中间产物保留在 $WORK（删除: rm -rf $ROOT）"
