#!/usr/bin/env bash
# port.sh — 将华为 CodeArts 桌面智能体移植到 Linux（deb / rpm）
#
# 上游仅提供 macOS(arm64 zip) / Windows(x64 NSIS exe)，无 Linux 版。
# 应用为 Electron 39.3.0 架构：平台无关的 app.asar + 平台绑定的 sidecar
# (agent-kernel / officecli)。移植方式对齐 workbuddy：
#   1. 从 mac zip 提取 app.asar（平台无关 JS）并解压
#   2. 替换平台原生 node 模块为 Linux 构建（如有）
#   3. Electron linux-x64 runtime 启动，重打包 deb / rpm
# 注意：agent-kernel / officecli 无 linux-x64 上游产物，智能体功能受限（详见 README）。
#
# 用法:
#   ./port.sh                        # 自动探测当前目录源包，按当前 OS 打包
#   ./port.sh -p all                 # 同时打 deb 和 rpm
#   ./port.sh -p deb CodeArts-0.1.26-arm64.zip
#
# 依赖: unzip, tar, node, npx, curl/wget, python3; 打 deb 需 dpkg-deb（缺失时降级用 binutils ar + xz）; 打 rpm 需 rpmbuild

usage() {
  cat <<'EOF'
port.sh — 将华为 CodeArts 桌面智能体移植到 Linux（deb / rpm）

上游仅提供 macOS(arm64 zip) / Windows(x64 exe)，无 Linux 版。
从 mac zip 提取平台无关的 app.asar 并解压，替换平台原生 node 模块为
Linux 构建，用 Electron linux-x64 runtime 启动，重打包为 deb / rpm。

用法:
  ./port.sh                        # 自动探测当前目录源包，按当前 OS 打包
  ./port.sh -p all                 # 同时打 deb 和 rpm
  ./port.sh -p deb CodeArts-0.1.26-arm64.zip

选项:
  -p, --platform rpm|deb|all   构建目标；省略时按当前 OS 自动检测
  -s, --source PATH|URL        mac zip：本地路径或下载地址；省略时自动探测
                               当前目录 CodeArts-*.zip
  -e, --electron VERSION       Electron runtime 版本（默认 39.3.0）
  -k, --kernel PATH|URL        Linux 版 agent-kernel 来源：官方
                               codearts-agent-*-linux-x64.deb（本地路径或下载
                               地址），或直接给内核 ELF 路径；省略时自动探测
                               当前目录。缺失则聊天功能不可用
  -h, --help                   显示本帮助

环境变量:
  DEBUG=1                      调试模式（set -eux，打印每条命令）
  IS_CHINA=1                   中国网络环境，GitHub 系域名下载走 CDN 加速
  CDN=<url>                    CDN 前缀地址（默认 https://fastfile.asfd.cn/）
  NPM_CONFIG_USERCONFIG        npm 配置文件路径（默认 ~/.npmrc），
                               其中的 registry 用于 npx asar 与 npm 依赖
                               （atomgit-cli）下载
  NPM_CONFIG_REGISTRY          npm 镜像地址（~/.npmrc 未配置 registry 时使用）

依赖: unzip, tar, node, npx, curl/wget, python3; 打 deb 需 dpkg-deb（缺失时
      降级用 binutils 的 ar + xz 手工拼装）; 打 rpm 需 rpmbuild
EOF
}

if [[ -n "$DEBUG" ]]; then
  set -eux
else
  set -euo pipefail
fi

# ---------- 颜色输出 ----------
C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'; C_NC='\033[0m'
info() { echo -e "${C_GREEN}[信息]${C_NC} $*"; }
warn() { echo -e "${C_YELLOW}[警告]${C_NC} $*"; }
step() { echo -e "${C_BLUE}[步骤]${C_NC} $*"; }
die()  { echo -e "${C_RED}[失败]${C_NC} $*" >&2; exit 1; }

# ---------- 依赖检查 ----------
for cmd in unzip tar node npx python3; do
  command -v "$cmd" >/dev/null 2>&1 || die "缺少依赖命令: $cmd"
done
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  die "缺少下载器: curl 或 wget"
fi

# Electron runtime 版本（与 CodeArts 内置 Electron Framework 对齐，可用 -e 覆盖）
ELECTRON_VERSION="${ELECTRON_VERSION:-39.3.0}"

BUILD_PLATFORM=""   # 空=自动检测
SOURCE_REF=""       # 源 zip：本地路径或 URL
KERNEL_REF=""       # Linux agent-kernel：本地 tar.gz/deb 路径或 URL

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

# ---------- npm 镜像（优先取 ~/.npmrc 的 registry；供 npx asar 与 npm 依赖补齐共用） ----------
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
if [[ -z "$NPM_REGISTRY" ]]; then
  NPM_REGISTRY="${NPM_CONFIG_REGISTRY:-}"
  NPM_REGISTRY="${NPM_REGISTRY%/}"
  if [[ -n "$NPM_REGISTRY" ]]; then
    NPM_MIRROR_SRC="环境变量 NPM_CONFIG_REGISTRY"
  fi
fi
if [[ -n "$NPM_REGISTRY" ]]; then
  # 仅在用户配置了镜像时导出，避免覆盖 npm 自身的全局/项目级 registry 解析
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
    case "${ID:-}" in
      fedora|rhel|centos|rocky|alma|opensuse*|tumbleweed|leap|amzn|sles|suse)
        echo "rpm" ;;
      debian|ubuntu|linuxmint|kali|elementary|pop|raspbian|deepin)
        echo "deb" ;;
      *)
        if command -v rpm >/dev/null 2>&1 && ! command -v dpkg >/dev/null 2>&1; then
          echo "rpm"
        else
          echo "deb"
        fi ;;
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
    -p|--platform) BUILD_PLATFORM="$2"; shift 2 ;;
    -p=*|--platform=*) BUILD_PLATFORM="${1#*=}"; shift ;;
    -s|--source) SOURCE_REF="$2"; shift 2 ;;
    -s=*|--source=*) SOURCE_REF="${1#*=}"; shift ;;
    -e|--electron) ELECTRON_VERSION="$2"; shift 2 ;;
    -e=*|--electron=*) ELECTRON_VERSION="${1#*=}"; shift ;;
    -k|--kernel) KERNEL_REF="$2"; shift 2 ;;
    -k=*|--kernel=*) KERNEL_REF="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *.zip) SOURCE_REF="$(readlink -f "$1")"; shift ;;
    -*) usage >&2; die "未知选项: $1" ;;
    *) die "未知参数: $1" ;;
  esac
done

if [[ -z "$BUILD_PLATFORM" ]]; then
  BUILD_PLATFORM="$(detect_platform)"
fi
case "$BUILD_PLATFORM" in
  rpm) BUILD_RPM=1; BUILD_DEB=0 ;;
  deb) BUILD_RPM=0; BUILD_DEB=1 ;;
  all) BUILD_RPM=1; BUILD_DEB=1 ;;
  *)   usage >&2; die "无效平台: $BUILD_PLATFORM (可选: rpm, deb, all)" ;;
esac

# 自动探测源 zip
CWD="$(pwd -P)"
if [[ -z "$SOURCE_REF" ]]; then
  for f in "$CWD"/CodeArts-*.zip; do
    [[ -f "$f" ]] || continue
    case "$(basename "$f")" in
      *win32*|*exe*) continue ;;
    esac
    SOURCE_REF="$(readlink -f "$f")"
    info "自动探测源: $SOURCE_REF"
    break
  done
fi
[[ -n "$SOURCE_REF" ]] || { usage >&2; die "未找到源 zip。请传入 CodeArts-<ver>.zip"; }

is_url() { [[ "$1" == http://* || "$1" == https://* ]]; }

# ---------- 目录布局 ----------
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ROOT="$SCRIPT_DIR/build"
CACHE_DIR="$ROOT/cache"
WORK_DIR="$ROOT/work"
OUT_DIR="$ROOT/out"
mkdir -p "$CACHE_DIR" "$WORK_DIR" "$OUT_DIR"

# ---------- 下载器（缓存复用 + CDN） ----------
download() {
  local url="$1" output="$2"
  if [[ -f "$output" ]]; then
    info "复用已缓存: $(basename "$output")"
    return 0
  fi
  if is_china && cdn_applicable "$url"; then
    local cdn_url="${CDN_URL}${url}"
    info "下载 (CDN) $url ..."
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

# ---------- npm tarball 下载（跟随 NPM_REGISTRY 镜像；失败回退官方源，非致命） ----------
http_get_file() {
  local url="$1" output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsL --retry 3 --max-time 120 --output "$output" "$url"
  else
    wget -q -O "$output" "$url"
  fi
}

# fetch_npm_tgz <包名> <版本> <输出 tgz>；缓存复用，镜像失败回退 registry.npmjs.org
fetch_npm_tgz() {
  local pkg="$1" ver="$2" output="$3"
  local file="${pkg##*/}-${ver}.tgz" url
  if [[ -f "$output" ]]; then
    info "复用已缓存: $(basename "$output")"
    return 0
  fi
  url="${NPM_REGISTRY}/${pkg}/-/${file}"
  info "下载 (npm 镜像) $url ..."
  if http_get_file "$url" "$output"; then
    return 0
  fi
  rm -f "$output"
  if [[ "$NPM_REGISTRY" != "https://registry.npmjs.org" ]]; then
    url="https://registry.npmjs.org/${pkg}/-/${file}"
    warn "npm 镜像下载失败，回退官方源: $url"
    if http_get_file "$url" "$output"; then
      return 0
    fi
    rm -f "$output"
  fi
  return 1
}

echo
echo -e "${C_BLUE}════════════════════════════════════════════════════${C_NC}"
echo -e "${C_BLUE}  CodeArts 桌面智能体跨平台移植${C_NC}"
echo -e "${C_BLUE}════════════════════════════════════════════════════${C_NC}"
echo "  源:          $SOURCE_REF"
echo "  Electron:    $ELECTRON_VERSION"
echo "  目标平台:    $BUILD_PLATFORM (deb=$BUILD_DEB rpm=$BUILD_RPM)"
echo

# ============================================================
# 步骤 1: 获取源 zip → 提取 app.asar / app.asar.unpacked / 图标 / sidecar
# ============================================================
step "1/7 获取并解压源 zip ..."
if is_url "$SOURCE_REF"; then
  SOURCE_ZIP="$CACHE_DIR/$(basename "$SOURCE_REF")"
  download "$SOURCE_REF" "$SOURCE_ZIP"
else
  SOURCE_ZIP="$SOURCE_REF"
  [[ -f "$SOURCE_ZIP" ]] || die "源 zip 不存在: $SOURCE_ZIP"
fi

# 版本从文件名提取（CodeArts-0.1.26-arm64.zip → 0.1.26）
APP_VER="$(basename "$SOURCE_ZIP" .zip)"
APP_VER="${APP_VER#CodeArts-}"
APP_VER="${APP_VER%%-*}"
[[ -n "$APP_VER" ]] || die "无法从文件名提取版本号: $(basename "$SOURCE_ZIP")"
info "版本: $APP_VER"

RES_STAGE="$WORK_DIR/resources"
if [[ -f "$RES_STAGE/app.asar" ]]; then
  info "复用已提取的资源"
else
  rm -rf "$RES_STAGE"
  mkdir -p "$RES_STAGE"
  unzip -tq "$SOURCE_ZIP" || die "zip 完整性校验失败"
  # 只解出需要的条目（跳过 __MACOSX 与 200MB 的 darwin Electron Framework）
  unzip -q "$SOURCE_ZIP" \
    "CodeArts.app/Contents/Resources/app.asar" \
    "CodeArts.app/Contents/Resources/app.asar.unpacked/*" \
    "CodeArts.app/Contents/Resources/icon.icns" \
    "CodeArts.app/Contents/Resources/cloud-sidecars.yaml" \
    "CodeArts.app/Contents/Resources/product.json" \
    -d "$WORK_DIR/mac_zip" || die "解压资源失败"
  SRC_RES="$WORK_DIR/mac_zip/CodeArts.app/Contents/Resources"
  mv "$SRC_RES/app.asar" "$RES_STAGE/"
  mv "$SRC_RES/app.asar.unpacked" "$RES_STAGE/"
  mv "$SRC_RES/icon.icns" "$RES_STAGE/" 2>/dev/null || true
  mv "$SRC_RES/cloud-sidecars.yaml" "$RES_STAGE/" 2>/dev/null || true
  # product.json 是应用必需的运行时配置（Electron 启动时 ProductService 读取），
  # 位于 Resources 根而非 asar 内，必须一并带到 app/ 旁边
  mv "$SRC_RES/product.json" "$RES_STAGE/" 2>/dev/null || true
  rm -rf "$WORK_DIR/mac_zip"
fi

# ============================================================
# 步骤 2: 解压 app.asar
# ============================================================
step "2/7 解压 app.asar ..."
APP_DIR="$WORK_DIR/codearts"
ASAR_UNPACKED="$APP_DIR/app"
if [[ -f "$ASAR_UNPACKED/package.json" ]]; then
  info "复用已解压的 app.asar"
else
  rm -rf "$APP_DIR"
  mkdir -p "$APP_DIR"
  npx --yes asar@3.2.0 extract "$RES_STAGE/app.asar" "$ASAR_UNPACKED" || die "ASAR 解压失败"
fi

[[ -f "$ASAR_UNPACKED/package.json" ]] || die "ASAR 解压不完整: 缺少 package.json"
ASAR_VER="$(node -p "require('$ASAR_UNPACKED/package.json').version || '$APP_VER'")"
info "app.asar 版本: $ASAR_VER"

# ============================================================
# 步骤 3: 替换平台原生 node 模块为 Linux 构建
# ============================================================
step "3/7 替换平台原生模块 ..."
# CodeArts 的 node_modules 随包在 app.asar.unpacked 与 asar 内；
# 已知平台绑定模块清单（darwin 版对 linux 无效，直接移除并在日志标注）
while IFS= read -r -d '' mod; do
  warn "移除 darwin 原生模块: ${mod#"$RES_STAGE"/}（无 linux 上游替代，功能降级见 README）"
  rm -f "$mod"
done < <(find "$RES_STAGE/app.asar.unpacked" -name '*.node' -type f -print0 2>/dev/null)
# asar 解压目录内同样清理
while IFS= read -r -d '' mod; do
  warn "移除 darwin 原生模块: ${mod#"$ASAR_UNPACKED"/}（无 linux 上游替代）"
  rm -f "$mod"
done < <(find "$ASAR_UNPACKED" -name '*.node' -type f -print0 2>/dev/null)
info "平台原生模块清理完成"
# 注：atomgit-cli 已确认有 linux-x64 变体（@hust-open-atom-club/atomgit-cli-linux-x64），
# 若 asar 内引用它，经 NPM_REGISTRY（~/.npmrc 镜像）下载补齐，失败不致命
if grep -rq 'atomgit-cli' "$ASAR_UNPACKED/out" 2>/dev/null; then
  npm_tgz="$CACHE_DIR/atomgit-cli-linux-x64.tgz"
  npm_dst="$ASAR_UNPACKED/node_modules/@hust-open-atom-club/atomgit-cli-linux-x64"
  if fetch_npm_tgz "@hust-open-atom-club/atomgit-cli-linux-x64" "0.7.3" "$npm_tgz"; then
    mkdir -p "$npm_dst"
    if tar -xzf "$npm_tgz" --strip-components=1 -C "$npm_dst"; then
      info "已补齐 atomgit-cli linux-x64"
    else
      rm -f "$npm_tgz"
      warn "atomgit-cli 解包失败（不影响主体功能）"
    fi
  else
    warn "atomgit-cli-linux-x64 补齐失败（不影响主体功能）"
  fi
fi

# ============================================================
# 步骤 4: sidecar 处理（agent-kernel / officecli）
# ============================================================
step "4/7 sidecar 处理 ..."
# officecli 上游只有 darwin/win32 版，无 linux-x64 产物，跳过（部分功能受限）。
# agent-kernel：从 mac zip 提取纯 JS 插件与配置，并用 Linux 版内核 + wrapper 转接
# （新内核为 opencode 架构 serve 子命令，配置经 POST /v1/init 注入）。

# 4.1 从 mac zip 提取内核插件（纯 JS）与 agent-config.yaml
PLUG_STAGE="$WORK_DIR/kernel-plugins"
if [[ -d "$PLUG_STAGE/.agent-kernel" || -f "$PLUG_STAGE/agent-config.yaml" ]]; then
  info "复用已提取的内核插件与配置"
else
  rm -rf "$PLUG_STAGE"; mkdir -p "$PLUG_STAGE"
  # 插件目录（bin/.agent-kernel/）在部分版本中不存在（0.2.x 起内核自包含），
  # 缺失时跳过；agent-config.yaml 与 cloud-sidecars.yaml 始终提取
  unzip -qo "$SOURCE_ZIP" \
    "CodeArts.app/Contents/Resources/bin/.agent-kernel/*" \
    "CodeArts.app/Contents/Resources/agent-config.yaml" \
    "CodeArts.app/Contents/Resources/cloud-sidecars.yaml" \
    -x "*.zip" -d "$PLUG_STAGE" 2>/dev/null || true
  # 插件目录可能不存在，移动时失败不报错
  mv "$PLUG_STAGE/CodeArts.app/Contents/Resources/bin/.agent-kernel" "$PLUG_STAGE/" \
    2>/dev/null || warn "内核插件目录 bin/.agent-kernel 不存在（新版内核可能自包含插件），跳过"
  mv "$PLUG_STAGE/CodeArts.app/Contents/Resources/agent-config.yaml" "$PLUG_STAGE/" 2>/dev/null || true
  mv "$PLUG_STAGE/CodeArts.app/Contents/Resources/cloud-sidecars.yaml" "$PLUG_STAGE/" 2>/dev/null || true
  rm -rf "$PLUG_STAGE/CodeArts.app"
fi
info "内核插件与配置就绪: $PLUG_STAGE"

# 4.2 获取 Linux 版 agent-kernel：官方 codearts-agent deb 内
#     extensions/huaweicloud.codearts-snap/agentkernelServer-linux-x64
if [[ -z "$KERNEL_REF" ]]; then
  for f in "$CWD"/codearts-agent-linux-x64-*.deb; do
    [[ -f "$f" ]] || continue
    KERNEL_REF="$(readlink -f "$f")"
    info "自动探测 Linux 内核来源: $KERNEL_REF"
    break
  done
fi
KERNEL_ELF="$WORK_DIR/agent-kernel-linux"
if [[ -f "$KERNEL_ELF" ]] && "$KERNEL_ELF" -v >/dev/null 2>&1; then
  info "复用已提取的 Linux agent-kernel"
else
  [[ -n "$KERNEL_REF" ]] || warn "未提供 Linux 版 agent-kernel（-k 或当前目录 codearts-agent-*-linux-x64.deb），聊天功能将不可用"
  if [[ -n "$KERNEL_REF" ]]; then
    if is_url "$KERNEL_REF"; then
      KSRC="$CACHE_DIR/$(basename "$KERNEL_REF")"
      download "$KERNEL_REF" "$KSRC"
    else
      KSRC="$KERNEL_REF"
      [[ -f "$KSRC" ]] || die "内核来源不存在: $KSRC"
    fi
    rm -f "$KERNEL_ELF"
    case "$KSRC" in
      *.deb)
        KTMP="$WORK_DIR/deb-extract"; rm -rf "$KTMP"; mkdir -p "$KTMP"
        command -v ar >/dev/null 2>&1 || die "解 deb 需要 binutils(ar)"
        ( cd "$KTMP" && ar x "$KSRC" && tar -xf data.tar.* 2>/dev/null ) || die "deb 解包失败"
        KELF="$(find "$KTMP" -name 'agentkernelServer-linux-x64' -type f -print -quit)"
        [[ -n "$KELF" ]] || die "deb 中未找到 agentkernelServer-linux-x64"
        cp -f "$KELF" "$KERNEL_ELF"
        rm -rf "$KTMP" ;;
      *) # 直接是内核 ELF
        file "$KSRC" 2>/dev/null | grep -q ELF || die "不支持的内核来源: $KSRC（支持官方 deb 或 ELF）"
        cp -f "$KSRC" "$KERNEL_ELF" ;;
    esac
  fi
fi
if [[ -f "$KERNEL_ELF" ]]; then
  chmod 755 "$KERNEL_ELF"
  "$KERNEL_ELF" -v >/dev/null 2>&1 || warn "Linux agent-kernel 自检失败（-v），可能版本不兼容"
  info "Linux agent-kernel 就绪: $KERNEL_ELF"
fi

# 4.3 生成内核启动 wrapper：
#     应用（0.1.26）以 <appPath>/bin/agent-kernel.exe --port=N ... --host-init-stdin 拉起内核，
#     并把 hostInit 配置（模型网关/凭证）写到 stdin；而 Linux 版内核为 opencode 架构，
#     需要 `serve` 子命令并通过 POST /v1/init 接收配置。wrapper 做转接：
#     过滤不兼容参数 → serve 启动 → 等健康检查 → 转发 hostInit 到 /v1/init
AK_WRAPPER="$WORK_DIR/ak-wrapper.sh"
cat > "$AK_WRAPPER" <<'WRAPEOF'
#!/usr/bin/env bash
# CodeArts Linux 移植 wrapper：桌面端 0.1.26 内核调用协议 → opencode 架构内核 serve 协议
REAL="$(dirname "$(readlink -f "$0")")/agent-kernel.real"
if [[ "$1" == "-v" || "$1" == "--version" ]]; then exec "$REAL" "$@"; fi

out=(serve --print-logs)
port=""
skip=false
for a in "$@"; do
  if $skip; then out+=("$a"); skip=false; continue; fi
  case "$a" in
    --log-level) out+=(--log-level DEBUG);;
    --port) out+=("$a"); skip=true;;
    --port=*) out+=("$a"); port="${a#--port=}";;
  esac
done

# 捕获 stdin 的 hostInit JSON
HIFILE="$(mktemp /tmp/ak-hostinit.XXXXXX.json)"
if [[ ! -t 0 ]]; then cat > "$HIFILE" 2>/dev/null || true; fi

"$REAL" "${out[@]}" 2>&1 | sed -u 's/^/[kernel] /' &
PID=$!
trap 'kill $PID 2>/dev/null' TERM INT

# 等待健康检查通过后，把 hostInit 注入内核（/v1/init）
if [[ -n "$port" && -s "$HIFILE" ]]; then
  for i in $(seq 1 100); do
    curl -sf "http://localhost:${port}/global/health" >/dev/null 2>&1 && break
    sleep 0.3
  done
  curl -s -X POST "http://localhost:${port}/v1/init" \
    -H "Content-Type: application/json" \
    --data-binary @"$HIFILE" >/dev/null 2>&1 || true
fi
rm -f "$HIFILE"
wait $PID
WRAPEOF
chmod 755 "$AK_WRAPPER"
if [[ -f "$KERNEL_ELF" ]]; then
  info "内核启动 wrapper 就绪: $AK_WRAPPER"
else
  warn "无 Linux 内核，wrapper 将不随包安装"
fi

# ============================================================
# 步骤 5: 下载 Electron Linux runtime
# ============================================================
step "5/7 下载 Electron $ELECTRON_VERSION (linux-x64) ..."
electron_zip="$CACHE_DIR/electron-v${ELECTRON_VERSION}-linux-x64.zip"
download "https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-linux-x64.zip" "$electron_zip"
if [[ -d "$APP_DIR/electron/electron" ]]; then
  info "复用已解压的 Electron"
else
  rm -rf "$APP_DIR/electron"
  mkdir -p "$APP_DIR/electron"
  unzip -q "$electron_zip" -d "$APP_DIR/electron" || die "Electron 解压失败"
fi
chmod 4755 "$APP_DIR/electron/chrome-sandbox" 2>/dev/null || true

# ============================================================
# 步骤 6: 组装应用目录（/opt/codearts 布局）
# ============================================================
step "6/7 组装应用目录 ..."
# 图标（icns → hicolor 各尺寸，含 apps/ 子目录层级）
ICON_BASE="$WORK_DIR/icon"
mkdir -p "$ICON_BASE"
unzip -p "$SOURCE_ZIP" "CodeArts.app/Contents/Resources/icon.icns" > "$ICON_BASE/icon.icns" 2>/dev/null || true
python3 - "$ICON_BASE/icon.icns" "$ICON_BASE" <<'PYEOF' || warn "icns 图标解析失败"
import struct, sys, os
icns_path, out_dir = sys.argv[1], sys.argv[2]
data = open(icns_path, 'rb').read()
assert data[:4] == b'icns', 'not an icns file'
types = {'icp4':16,'icp5':32,'ic11':32,'ic12':64,'ic13':128,'ic14':256,
         'ic07':128,'ic08':256,'ic09':512,'ic10':1024,'ic04':16,'ic05':32}
types = {t.encode(): s for t, s in types.items()}
off = 8
found = 0
while off + 8 <= len(data):
    otype, olen = struct.unpack('>4sI', data[off:off+8])
    body = data[off+8:off+olen]
    if otype in types and body[:4] == b'\x89PNG':
        size = types[otype]
        d = os.path.join(out_dir, f'{size}x{size}', 'apps')
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, 'codearts.png'), 'wb').write(body)
        found += 1
    off += olen
print(f'提取 {found} 个图标尺寸')
PYEOF

# /usr/bin 启动脚本 + .desktop
LAUNCHER="$WORK_DIR/usr-bin-codearts"
cat > "$LAUNCHER" <<'EOF'
#!/bin/sh
exec /opt/codearts/electron/electron /opt/codearts/app "$@"
EOF
chmod 0755 "$LAUNCHER"

DESKTOP="$WORK_DIR/codearts.desktop"
cat > "$DESKTOP" <<'EOF'
[Desktop Entry]
Name=CodeArts
Comment=华为云 CodeArts 智能开发助手
Comment[en]=Huawei Cloud CodeArts AI Dev Assistant
Exec=/usr/bin/codearts %U
Terminal=false
Type=Application
Icon=codearts
StartupWMClass=codearts
Categories=Development;IDE;
EOF

# 应用最终布局：/opt/codearts/{app, electron}
# app.asar.unpacked 与 app 同层放置（Electron 按 asar 约定自动识别同名目录）
if [[ -d "$APP_DIR/final" ]]; then
  info "复用已组装的应用目录"
else
  cp -a "$RES_STAGE/app.asar.unpacked" "$APP_DIR/app.asar.unpacked" 2>/dev/null || true
  mkdir -p "$APP_DIR/final"
fi
# 重建 final（幂等）
rm -rf "$APP_DIR/final"
mkdir -p "$APP_DIR/final"
cp -a "$ASAR_UNPACKED" "$APP_DIR/final/app"
cp -a "$RES_STAGE/app.asar.unpacked" "$APP_DIR/final/app.asar.unpacked" 2>/dev/null || true
cp -a "$APP_DIR/electron" "$APP_DIR/final/electron"
# cloud-sidecars.yaml 与 agent-config.yaml 必须与 app 入口同级：
# 应用按 path.join(getAppPath(), <name>) 读取（getAppPath() = /opt/codearts/app）
cp -a "$RES_STAGE/cloud-sidecars.yaml" "$APP_DIR/final/app/" 2>/dev/null || true
cp -a "$PLUG_STAGE/cloud-sidecars.yaml" "$APP_DIR/final/app/" 2>/dev/null || \
  cp -a "$RES_STAGE/cloud-sidecars.yaml" "$APP_DIR/final/app/" 2>/dev/null || true
cp -a "$PLUG_STAGE/agent-config.yaml" "$APP_DIR/final/app/" 2>/dev/null || true
# product.json 必须与 app 入口同级：ProductService 按
# path.join(app.getAppPath(), 'product.json') 查找，getAppPath() = /opt/codearts/app
cp -a "$RES_STAGE/product.json" "$APP_DIR/final/app/" 2>/dev/null || true
# agent-kernel：真实 ELF 改名 agent-kernel.real，wrapper 顶替应用期望的
# bin/agent-kernel.exe 名字做协议转接；插件为纯 JS，随 bin/.agent-kernel 安装
if [[ -f "$KERNEL_ELF" ]]; then
  install -Dm755 "$KERNEL_ELF" "$APP_DIR/final/app/bin/agent-kernel.real"
  install -Dm755 "$AK_WRAPPER" "$APP_DIR/final/app/bin/agent-kernel.exe"
  rm -rf "$APP_DIR/final/app/bin/.agent-kernel"
  cp -a "$PLUG_STAGE/.agent-kernel" "$APP_DIR/final/app/bin/.agent-kernel" 2>/dev/null \
    || warn "内核插件目录不存在，跳过（新版内核自包含插件）"
  info "agent-kernel 与 wrapper 已装入应用目录"
fi
info "应用目录就绪: $APP_DIR/final"

# ============================================================
# 步骤 7: 打包 deb / rpm
# ============================================================
OUT_BASE="$OUT_DIR"

# ---------- 打 deb ----------
# 打包工具：优先 dpkg-deb；缺失时降级为 ar 手工拼装（参考 mimo-desktop 做法）
DEB_TOOL=""
if [[ "$BUILD_DEB" -eq 1 ]]; then
  if command -v dpkg-deb >/dev/null 2>&1; then
    DEB_TOOL="dpkg-deb"
  elif command -v ar >/dev/null 2>&1 && command -v xz >/dev/null 2>&1; then
    DEB_TOOL="ar"
    warn "dpkg-deb 不可用，降级用 ar 手工拼装 deb"
  else
    warn "dpkg-deb 与 ar 均不可用，跳过 deb"
    BUILD_DEB=0
  fi
fi
if [[ "$BUILD_DEB" -eq 1 ]]; then
  step "7/7 打包 deb ..."
  DEB_BUILD="$WORK_DIR/deb_build"
  rm -rf "$DEB_BUILD"
  mkdir -p "$DEB_BUILD/opt" "$DEB_BUILD/usr/bin" \
           "$DEB_BUILD/usr/share/applications" \
           "$DEB_BUILD/usr/share/icons/hicolor" \
           "$DEB_BUILD/usr/share/doc/codearts" "$DEB_BUILD/DEBIAN"

  cp -a "$APP_DIR/final" "$DEB_BUILD/opt/codearts"
  install -Dm755 "$LAUNCHER" "$DEB_BUILD/usr/bin/codearts"
  install -Dm644 "$DESKTOP" "$DEB_BUILD/usr/share/applications/codearts.desktop"
  cp -a "$ICON_BASE"/*/ "$DEB_BUILD/usr/share/icons/hicolor/" 2>/dev/null || true
  # 兜底 pixmaps 图标
  if [[ -f "$ICON_BASE/512x512/apps/codearts.png" ]]; then
    install -Dm644 "$ICON_BASE/512x512/apps/codearts.png" "$DEB_BUILD/usr/share/pixmaps/codearts.png"
  elif [[ -f "$ICON_BASE/256x256/apps/codearts.png" ]]; then
    install -Dm644 "$ICON_BASE/256x256/apps/codearts.png" "$DEB_BUILD/usr/share/pixmaps/codearts.png"
  fi

  installed_size=$(du -sk "$DEB_BUILD/opt" "$DEB_BUILD/usr" 2>/dev/null | awk '{s+=$1} END {print s}')
  cat > "$DEB_BUILD/DEBIAN/control" <<EOF
Package: codearts
Version: ${ASAR_VER}
Architecture: amd64
Maintainer: port-linux
Installed-Size: ${installed_size}
Depends: libasound2t64 | libasound2, libatk-bridge2.0-0, libatk1.0-0, libc6, libcairo2, libcups2, libdbus-1-3, libdrm2, libexpat1, libgbm1, libglib2.0-0, libgtk-3-0, libnspr4, libnss3, libpango-1.0-0, libx11-6, libxcb1, libxcomposite1, libxdamage1, libxext6, libxfixes3, libxkbcommon0, libxrandr2
Recommends: libappindicator3-1 | libayatana-appindicator3-1
Section: devel
Priority: optional
Homepage: https://www.huaweicloud.com/product/codearts.html
Description: Unofficial Linux package of Huawei CodeArts desktop agent
 CodeArts is an AI-powered development assistant from Huawei Cloud.
 This package ports the upstream macOS application resources to Linux.
 Not affiliated with or endorsed by Huawei.
EOF

  cat > "$DEB_BUILD/usr/share/doc/codearts/copyright" <<EOF
This is an unofficial redistribution/compatibility package.
CodeArts and its application resources are proprietary software owned by Huawei
or their respective rights holders. No additional license is granted by this package.
Upstream: https://www.huaweicloud.com/product/codearts.html
Packaged upstream version: ${ASAR_VER}
Electron license: https://github.com/electron/electron/blob/main/LICENSE
EOF

  find "$DEB_BUILD" -type d -exec chmod 0755 {} +
  OUT_DEB="$OUT_BASE/codearts_${ASAR_VER}_amd64.deb"
  if [[ "$DEB_TOOL" == "dpkg-deb" ]]; then
    dpkg-deb --root-owner-group --build "$DEB_BUILD" "$OUT_DEB" || die "deb 打包失败"
  else
    # Debian 包格式：ar 归档依次含 debian-binary / control.tar.xz / data.tar.xz
    echo "2.0" > "$WORK_DIR/debian-binary"
    ( cd "$DEB_BUILD" && tar --xz -cf "$WORK_DIR/deb-data.tar.xz" opt usr ) || die "deb data.tar 打包失败"
    ( cd "$DEB_BUILD" && tar --xz -cf "$WORK_DIR/deb-control.tar.xz" DEBIAN ) || die "deb control.tar 打包失败"
    ( cd "$WORK_DIR" && rm -f "$OUT_DEB" && ar rcs "$OUT_DEB" debian-binary deb-control.tar.xz deb-data.tar.xz ) \
      || die "deb 打包失败"
    rm -f "$WORK_DIR/debian-binary" "$WORK_DIR/deb-data.tar.xz" "$WORK_DIR/deb-control.tar.xz"
  fi
  info "deb 已生成: $OUT_DEB ($(du -h "$OUT_DEB" | cut -f1))"
fi

# ---------- 打 rpm ----------
if [[ "$BUILD_RPM" -eq 1 ]]; then
  command -v rpmbuild >/dev/null 2>&1 || { warn "rpmbuild 不可用，跳过 rpm"; BUILD_RPM=0; }
fi
if [[ "$BUILD_RPM" -eq 1 ]]; then
  step "7/7 打包 rpm ..."
  RPMROOT="$WORK_DIR/rpmroot"
  rm -rf "$RPMROOT"
  mkdir -p "$RPMROOT"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS,payload}

  # payload
  mkdir -p "$RPMROOT/payload/opt" "$RPMROOT/payload/usr"/{bin,share/{applications,icons/hicolor,pixmaps}}
  cp -a "$APP_DIR/final" "$RPMROOT/payload/opt/codearts"
  install -Dm755 "$LAUNCHER" "$RPMROOT/payload/usr/bin/codearts"
  install -Dm644 "$DESKTOP" "$RPMROOT/payload/usr/share/applications/codearts.desktop"
  cp -a "$ICON_BASE"/*/ "$RPMROOT/payload/usr/share/icons/hicolor/" 2>/dev/null || true
  if [[ -f "$ICON_BASE/512x512/apps/codearts.png" ]]; then
    install -Dm644 "$ICON_BASE/512x512/apps/codearts.png" "$RPMROOT/payload/usr/share/pixmaps/codearts.png"
  elif [[ -f "$ICON_BASE/256x256/apps/codearts.png" ]]; then
    install -Dm644 "$ICON_BASE/256x256/apps/codearts.png" "$RPMROOT/payload/usr/share/pixmaps/codearts.png"
  fi

  # 只删除相对路径且目标不存在的损坏符号链接（rpm cpio 打包会失败）
  while IFS= read -r -d '' lnk; do
    target="$(readlink "$lnk")"
    [[ "$target" == /* ]] || rm -f "$lnk"
  done < <(find "$RPMROOT/payload" -type l -print0) 2>/dev/null || true

  cat > "$RPMROOT/SPECS/codearts.spec" <<SPEC
Name:           codearts
Version:        ${ASAR_VER}
Release:        1%{?dist}
Summary:        Unofficial Linux package of Huawei CodeArts desktop agent
License:        Proprietary
URL:            https://www.huaweicloud.com/product/codearts.html
Vendor:         port-linux
BuildArch:      x86_64
AutoReq:        no
AutoProv:       no

Requires:       alsa-lib, at-spi2-atk, atk, cairo, cups-libs, dbus-libs, expat, glib2, gtk3, nspr, nss, pango, libX11, libxcb, libXcomposite, libXdamage, libXext, libXfixes, libxkbcommon, libXrandr
Recommends:     libappindicator-gtk3

%description
Unofficial Linux package of Huawei CodeArts desktop agent.
CodeArts is an AI-powered development assistant from Huawei Cloud.
This package ports the upstream macOS application resources to Linux.
Not affiliated with or endorsed by Huawei.

%prep

%build

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
cp -a $RPMROOT/payload/* %{buildroot}/

%post
if ! { [[ -L /proc/self/ns/user ]] && unshare --user true; } 2>/dev/null; then
    chmod 4755 '/opt/codearts/electron/chrome-sandbox' 2>/dev/null || true
else
    chmod 0755 '/opt/codearts/electron/chrome-sandbox' 2>/dev/null || true
fi
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications 2>/dev/null || true
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -qf /usr/share/icons/hicolor 2>/dev/null || true
fi

%postun
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications 2>/dev/null || true
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -qf /usr/share/icons/hicolor 2>/dev/null || true
fi

%files
%defattr(-,root,root,-)
"/opt/codearts"
"/usr/bin/codearts"
"/usr/share/applications/codearts.desktop"
"/usr/share/pixmaps/codearts.png"
"/usr/share/icons/hicolor"

%changelog
* $(LC_TIME=C date '+%a %b %d %Y') ported <codearts@port-linux> ${ASAR_VER}-1
- 从 macOS ${ASAR_VER} 移植到 Linux
- 内置 Electron ${ELECTRON_VERSION} runtime
SPEC

  QA_RPATHS=0 rpmbuild -bb \
    --define "_topdir $RPMROOT" \
    --define "__brp_check_rpaths %{nil}" \
    --define "__brp_mangle_shebangs %{nil}" \
    --define "__os_install_post %{nil}" \
    --define "_unpackaged_files_terminate_build 0" \
    "$RPMROOT/SPECS/codearts.spec" 2>&1 | grep -vE '^\+' || true

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
info "中间产物保留在 $WORK_DIR（删除: rm -rf $ROOT）"
