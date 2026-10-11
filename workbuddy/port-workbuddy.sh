#!/usr/bin/env bash
# port-workbuddy.sh — 将腾讯 WorkBuddy macOS 版移植到 Linux（deb / rpm）
#
# 基底合并模式：以官方 Linux rpm 为基底，将 macOS 新版 zip 的
# app.asar / app.asar.unpacked 合并入基底，复用基底的 Electron 运行时与
# 完整的 Linux 原生模块，再按需用 npm 的 linux-x64 包覆盖 sandbox 等新增版本
# （sandbox / node-pty 版本从新版包自动探测）。
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
  SANDBOX_VER=<ver>            手动指定 sandbox linux-x64 版本；默认从新版包自动探测
  NODE_PTY_VER=<ver>           手动指定 node-pty linux-x64 版本；默认从新版包自动探测

依赖: unzip, tar, file, rpm2cpio, cpio, node, npx, curl/wget; 打 deb 需 dpkg-deb; 打 rpm 需 rpmbuild
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
for cmd in unzip tar node npx file; do
  command -v "$cmd" >/dev/null 2>&1 || die "缺少依赖命令: $cmd"
done
command -v rpm2cpio >/dev/null 2>&1 || die "缺少依赖命令: rpm2cpio (Fedora: sudo dnf install rpm)"
command -v cpio >/dev/null 2>&1 || die "缺少依赖命令: cpio"
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  die "缺少下载器: curl 或 wget"
fi

# 与新版 cli/package.json 的 optionalDependencies 保持一致；未设置时从新版包自动探测
SANDBOX_VER="${SANDBOX_VER:-}"
NODE_PTY_VER="${NODE_PTY_VER:-}"
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

base_name="$(basename "$BASE_REF")"
base_name="${base_name%.rpm}"
BASE_VER="${base_name##*-rpm-}"
BASE_VER="${BASE_VER%%-*}"
BASE_VER="${BASE_VER%.*}"

WORK="$ROOT/tmp.$(date +%s).$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
info "工作目录: $WORK"


# ============================================================
# 步骤 1: 解基底 rpm → Linux 完整运行时
# ============================================================
step "1/6 解基底 rpm (Linux ${BASE_VER} 完整运行时) ..."
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
DARWIN_RESOURCES="$WORK/darwin_extract/WorkBuddy.app/Contents/Resources"
[[ -f "$DARWIN_RESOURCES/app.asar" ]] || die "Darwin 压缩包内未找到 app.asar"

# 解压新版 app.asar（含 unpacked 缺失文件的占位修复）
DARWIN_UNPACKED="$WORK/darwin_app.asar.unpacked"
mkdir -p "$(dirname "$DARWIN_UNPACKED")"
if [[ -d "$DARWIN_RESOURCES/app.asar.unpacked" ]]; then
  cp -a "$DARWIN_RESOURCES/app.asar.unpacked" "$DARWIN_UNPACKED"
else
  mkdir -p "$DARWIN_UNPACKED"
fi
asar_log="$WORK/asar-extract.log"
# 预扫描: zip 可能丢失 unpacked 引用的点文件（如 .editor-sdk-version），一次性补占位，
# 避免每缺一个文件就整包重跑 extract
node -e '
const fs = require("fs"), path = require("path");
const [archive, unpackedDir] = process.argv.slice(1);
const fd = fs.openSync(archive, "r");
const sizeBuf = Buffer.alloc(8);
fs.readSync(fd, sizeBuf, 0, 8, 0);
// asar 布局: [sizePickle 8B][headerPickle: [4B payloadSize][4B stringLen][JSON+\0]]
const hb = Buffer.alloc(8);
fs.readSync(fd, hb, 0, 8, 8);
const strLen = hb.readUInt32LE(4);
const jb = Buffer.alloc(strLen);
fs.readSync(fd, jb, 0, strLen, 16);
fs.closeSync(fd);
const header = JSON.parse(jb.toString("utf8").replace(/\0+$/, ""));
let count = 0;
(function walk(node, prefix) {
  for (const [name, v] of Object.entries(node.files || {})) {
    const p = path.join(prefix, name);
    if (v && v.files) walk(v, p);
    else if (v && v.unpacked) {
      const f = path.join(unpackedDir, p);
      if (!fs.existsSync(f)) {
        fs.mkdirSync(path.dirname(f), { recursive: true });
        fs.writeFileSync(f, "");
        count++;
      }
    }
  }
})(header, "");
console.log(count);
' "$DARWIN_RESOURCES/app.asar" "$DARWIN_RESOURCES/app.asar.unpacked" >"$WORK/asar-placeholder.count" 2>"$WORK/asar-placeholder.err" ||
  warn "unpacked 占位预扫描失败（将依赖重试循环）: $(head -3 "$WORK/asar-placeholder.err" | tr '\n' ' ')"
if [[ -s "$WORK/asar-placeholder.count" ]] && [[ "$(cat "$WORK/asar-placeholder.count")" != "0" ]]; then
  info "已预补 unpacked 缺失占位: $(cat "$WORK/asar-placeholder.count") 个"
fi
extracted=false
for _ in $(seq 1 200); do
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
[[ "$extracted" == true ]] || die "ASAR 解压 200 次后仍未完成"
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

# 合并 Resources 顶层其余文件（新版必需资产如 workbuddy-editor-sdk-supervisor /
# workbuddy-wechat-notifier / 报告 html；基底缺失时 daemon 启动校验直接失败）
merged_top=0
while IFS= read -r -d '' f; do
  case "$(basename "$f")" in
  *.icns) continue ;;
  esac
  cp -f "$f" "$BASE_APP/resources/$(basename "$f")"
  merged_top=$((merged_top + 1))
done < <(find "$DARWIN_RESOURCES" -maxdepth 1 -type f ! -name 'app.asar*' -print0)
[[ -f "$BASE_APP/resources/workbuddy-editor-sdk-supervisor" ]] && chmod 0755 "$BASE_APP/resources/workbuddy-editor-sdk-supervisor"
[[ -f "$BASE_APP/resources/workbuddy-wechat-notifier" ]] && chmod 0755 "$BASE_APP/resources/workbuddy-wechat-notifier"
info "Resources 顶层文件已合并: $merged_top 个（含 IM 扩展必需资产）"

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

# ---- sandbox: 用与新版一致的 linux-x64 ELF 覆盖（基底不含该版本，需从 npm 下载） ----
# 版本探测优先级: 环境变量 SANDBOX_VER > cli/package.json optionalDependencies > vendor/sandbox 目录名
if [[ -z "$SANDBOX_VER" ]]; then
  cli_pkg_json="$ASAR_UNPACKED/cli/package.json"
  if [[ -f "$cli_pkg_json" ]]; then
    SANDBOX_VER=$(node -e 'try {
  const p = require(process.argv[1]);
  const v = p.optionalDependencies && p.optionalDependencies["@tencent-ai/sandbox-cli-linux-x64"];
  if (v) console.log(v);
} catch (e) {}' "$cli_pkg_json" 2>/dev/null || true)
  fi
fi
if [[ -z "$SANDBOX_VER" ]]; then
  SANDBOX_VER=$(find "$ASAR_UNPACKED/cli/vendor/sandbox" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -1)
fi

if [[ -z "$SANDBOX_VER" ]]; then
  warn "未能探测 sandbox 版本，跳过 sandbox linux 覆盖（可能残留 Mach-O）"
elif [[ ! -d "$ASAR_UNPACKED/cli/vendor/sandbox/$SANDBOX_VER" ]]; then
  warn "新版 unpacked 中无 sandbox $SANDBOX_VER 目录，跳过 linux 覆盖"
else
  target_sandbox="$ASAR_UNPACKED/cli/vendor/sandbox/${SANDBOX_VER}"
  # linux tarball 不含 tsbx_rules.json，先从 Darwin 目录备份再替换
  sandbox_rules_backup="$WORK/tsbx_rules-${SANDBOX_VER}.json"
  [[ -f "$target_sandbox/tsbx_rules.json" ]] && cp -f "$target_sandbox/tsbx_rules.json" "$sandbox_rules_backup"
  sandbox_tgz="$CACHE_DIR/sandbox-cli-linux-x64-${SANDBOX_VER}.tgz"
  download "$NPM_REGISTRY/@tencent-ai/sandbox-cli-linux-x64/-/sandbox-cli-linux-x64-${SANDBOX_VER}.tgz" "$sandbox_tgz"
  tmp_sb="$(mktemp -d)"
  tar -xzf "$sandbox_tgz" --strip-components=1 -C "$tmp_sb" 2>/dev/null || true
  if [[ -f "$tmp_sb/bin/sandbox-center" ]]; then
    # 清掉旧 sandbox 全部版本目录（基底版本与 Darwin Mach-O 均移除）
    find "$ASAR_UNPACKED/cli/vendor/sandbox" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} + 2>/dev/null || true
    mkdir -p "$target_sandbox"
    cp -f "$tmp_sb/bin/sandbox-center" "$tmp_sb/bin/sandbox-cli" "$tmp_sb/bin/sandbox-cli-gc" "$tmp_sb/bin/betterleaks" "$target_sandbox/" 2>/dev/null || true
    [[ -f "$tmp_sb/bin/wb-bridge" ]] && cp -f "$tmp_sb/bin/wb-bridge" "$target_sandbox/" 2>/dev/null || true
    chmod 0755 "$target_sandbox"/sandbox-center "$target_sandbox"/sandbox-cli "$target_sandbox"/sandbox-cli-gc 2>/dev/null || true
    [[ -f "$sandbox_rules_backup" ]] && cp -f "$sandbox_rules_backup" "$target_sandbox/tsbx_rules.json"
    info "vendor/sandbox 已替换为 linux-x64 ${SANDBOX_VER} ELF"
  else
    warn "sandbox linux-x64 ${SANDBOX_VER} 提取失败"
  fi
  rm -rf "$tmp_sb"
fi

# ---- node-pty: zip 通常已自带 linux-x64 包，缺失时从 npm 补齐 ----
if [[ ! -f "$ASAR_UNPACKED/node_modules/@lydell/node-pty-linux-x64/prebuilds/linux-x64/pty.node" ]]; then
  if [[ -z "$NODE_PTY_VER" ]]; then
    NODE_PTY_VER=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      "$ASAR_UNPACKED/node_modules/@lydell/node-pty/package.json" 2>/dev/null | head -1)
  fi
  if [[ -n "$NODE_PTY_VER" ]]; then
    node_pty_tgz="$CACHE_DIR/node-pty-linux-x64-${NODE_PTY_VER}.tgz"
    download "$NPM_REGISTRY/@lydell/node-pty-linux-x64/-/node-pty-linux-x64-${NODE_PTY_VER}.tgz" "$node_pty_tgz"
    mkdir -p "$ASAR_UNPACKED/node_modules/@lydell/node-pty-linux-x64"
    tar -xzf "$node_pty_tgz" --strip-components=1 -C "$ASAR_UNPACKED/node_modules/@lydell/node-pty-linux-x64" 2>/dev/null || true
    info "node-pty linux-x64 ${NODE_PTY_VER} 已补齐"
  else
    warn "未能探测 node-pty 版本且 zip 内缺 linux-x64 pty.node"
  fi
fi

# ---- koffi: darwin zip 仅打包 darwin 预编译，其余平台占位为空文件，从 npm 回填 linux_x64 ELF ----
koffi_node="$ASAR_UNPACKED/node_modules/koffi/build/koffi/linux_x64/koffi.node"
if [[ -e "$koffi_node" ]] && [[ ! -s "$koffi_node" ]]; then
  koffi_ver=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$ASAR_UNPACKED/node_modules/koffi/package.json" 2>/dev/null | head -1)
  if [[ -n "$koffi_ver" ]]; then
    koffi_tgz="$CACHE_DIR/koffi-${koffi_ver}.tgz"
    if (download "$NPM_REGISTRY/koffi/-/koffi-${koffi_ver}.tgz" "$koffi_tgz"); then
      tmp_koffi="$(mktemp -d)"
      tar -xzf "$koffi_tgz" --strip-components=1 -C "$tmp_koffi" 2>/dev/null || true
      if [[ -f "$tmp_koffi/build/koffi/linux_x64/koffi.node" ]]; then
        mkdir -p "$(dirname "$koffi_node")"
        cp -f "$tmp_koffi/build/koffi/linux_x64/koffi.node" "$koffi_node"
        info "koffi linux_x64 ${koffi_ver} 已从 npm 回填"
      else
        warn "koffi tarball 内无 build/koffi/linux_x64/koffi.node"
      fi
      rm -rf "$tmp_koffi"
    else
      warn "koffi ${koffi_ver} 下载失败，linux_x64 占位保持为空"
    fi
  else
    warn "未能探测 koffi 版本"
  fi
fi

# 清理所有残余 Mach-O .node（不影响 weixinpay 等插件的非 .node 资源）；
# 例外：resources/im-backend-cmd/im-napi.node 是 daemon 启动的硬性存在性校验资产，
# 官方未提供 Linux 构建，保留 Mach-O 占位以放行启动（IM 集成功能在 Linux 不可用）
find "$ASAR_UNPACKED" -type f -name '*.node' ! -path "$ASAR_UNPACKED/resources/im-backend-cmd/*" \
  -exec sh -c 'file "$1" 2>/dev/null | grep -q "Mach-O" && rm -f "$1"' _ {} \; 2>/dev/null || true

# ---- 可移植性补丁 ----
main_js="$ASAR_UNPACKED/main/index.js"
sed -i 's/tray\.on("right-click", () => this\.tray?\.popUpContextMenu(contextMenu))/tray.setContextMenu(contextMenu)/g' "$main_js" 2>/dev/null || true
# 注意：不要再把 process.resourcesPath 替换为安装路径字面量——Electron 原生
# process.resourcesPath 安装后即为 /opt/WorkBuddy/resources，替换反而丢失
# /resources 层，破坏 daemon 对 supervisor / im-napi 等资产的路径解析。
info "可移植性补丁已应用（tray）"

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
 This package ports the upstream macOS application resources to Linux (base ${BASE_VER} + Darwin ${PKG_VER}).
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
Unofficial Linux package of Tencent WorkBuddy (merged base ${BASE_VER} + Darwin $PKG_VER).

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
- 合并基底 Linux ${BASE_VER} + Darwin ${PKG_VER} 的 app.asar
- 复用基底 Electron 运行时与 Linux 原生模块
- 覆盖 sandbox ${SANDBOX_VER:-（未替换）} 为 linux-x64 ELF
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
