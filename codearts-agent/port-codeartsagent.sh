#!/usr/bin/env bash
# port-codeartsagent.sh — 将华为 CodeArts Agent（VSCode fork）移植到 Linux x64（deb / rpm）
#
# CodeArts Agent 上游是 VSCode（product.json: vscodeVersion），官方仅提供
# macOS(x64 zip) / Windows(x64 exe) / Linux(arm64 deb)，无 Linux x64 包。
# 本脚本采用「官方 VSCode x64 运行时 + mac 包平台无关 app 层」的分层移植：
#   1. 从 mac zip 提取平台无关的 Resources/app/（out/、extensions/、node_modules JS）
#   2. 下载 VSCode 官方 linux-deb-x64（版本自动读自 product.json 的 vscodeVersion）
#      作为运行时基底：x64 Electron + 全套 x64 原生 .node + desktop/图标
#   3. 用 CodeArts 的 app/ 替换 VSCode 的 app/，再把 VSCode 原 app 中的
#      x64 原生模块（node-pty/sqlite3/spdlog 等）按相对路径拷回覆盖 darwin 版
#   4. 重命名 desktop/bin 为 codearts-agent，重打包为 deb / rpm
#
# 用法:
#   ./port-codeartsagent.sh                          # 自动探测当前目录 mac zip，按当前 OS 打包
#   ./port-codeartsagent.sh -p all                   # 同时打 deb 和 rpm
#   ./port-codeartsagent.sh -p deb codearts-agent-*.zip
#   ./port-codeartsagent.sh -v /path/to/code_*.deb   # 指定本地 VSCode deb
#
# 依赖: unzip, tar, node, npx, curl/wget; 打 deb 需 dpkg-deb (或 bsdtar+ar); 打 rpm 需 rpmbuild

usage() {
  cat <<'EOF'
port-codeartsagent.sh — 将华为 CodeArts Agent（VSCode fork）移植到 Linux x64（deb / rpm）

CodeArts Agent 官方仅提供 macOS(x64 zip) / Windows(x64 exe) / Linux(arm64 deb)。
本脚本从 mac zip 提取平台无关的 app 层（VSCode fork 的 out/、extensions/ 等），
以 VSCode 官方 linux-deb-x64 为运行时基底（x64 Electron + x64 原生模块），
替换 app 层并覆盖原生模块，重打包为 Linux x64 的 deb / rpm。

用法:
  ./port-codeartsagent.sh                          # 自动探测当前目录 mac zip，按当前 OS 打包
  ./port-codeartsagent.sh -p all                   # 同时打 deb 和 rpm
  ./port-codeartsagent.sh -p deb codearts-agent-26.9.500.zip
  ./port-codeartsagent.sh -v /path/to/code_1.109.5.deb   # 指定本地 VSCode deb

选项:
  -p, --platform rpm|deb|all   构建目标；省略时按当前 OS 自动检测
  -m, --source PATH|URL        mac zip：本地路径或下载地址；省略时自动探测当前目录
                               codearts-agent-*.zip（排除 linux/exe）
  -v, --vscode PATH|URL        VSCode 官方 linux-deb-x64 包；省略时按 vscodeVersion 自动下载
  -c, --codename NAME          deb 基底包名清理（默认自动）
  -h, --help                   显示本帮助

环境变量:
  DEBUG=1                      调试模式（set -eux，打印每条命令）
  IS_CHINA=1                   中国网络环境，GitHub 系域名下载走 CDN 加速
  CDN=<url>                    CDN 前缀地址（默认 https://fastfile.asfd.cn/）
  NPM_CONFIG_USERCONFIG        npm 配置文件路径（默认 ~/.npmrc）

依赖: unzip, tar, node, npx, curl/wget; 打 deb 需 dpkg-deb; 打 rpm 需 rpmbuild
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
for cmd in unzip tar node; do
  command -v "$cmd" >/dev/null 2>&1 || die "缺少依赖命令: $cmd"
done
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  die "缺少下载器: curl 或 wget"
fi

BUILD_PLATFORM=""   # 空=自动检测
SOURCE_REF=""       # mac zip：本地路径或 URL
VSCODE_REF=""       # VSCode deb：本地路径或 URL

# ---------- CDN 加速（IS_CHINA=1 时启用，仅对 GitHub 系域名生效） ----------
CDN_URL="${CDN:-https://fastfile.asfd.cn}"
CDN_URL="${CDN_URL%% }"
CDN_URL="${CDN_URL%*/}/"

is_china() { [[ "${IS_CHINA:-}" == "1" ]]; }

# 仅这些域名的下载走 CDN（update.code.visualstudio.com 等 Microsoft 域名也走 CDN）
cdn_applicable() {
  case "$1" in
    https://github.com/* | https://raw.githubusercontent.com/* | https://objects.githubusercontent.com/* | https://update.code.visualstudio.com/* | https://vscode.download.prss.microsoft.com/*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------- npm 镜像（从 ~/.npmrc 读取 registry，供 npx asar 使用） ----------
NPMRC_FILE="${NPM_CONFIG_USERCONFIG:-$HOME/.npmrc}"
if [[ -f "$NPMRC_FILE" ]]; then
  configured_registry=$(sed -n 's/^[[:space:]]*registry[[:space:]]*=[[:space:]]*//p' "$NPMRC_FILE" | head -1)
  if [[ "$configured_registry" == http://* || "$configured_registry" == https://* ]]; then
    export NPM_CONFIG_REGISTRY="${configured_registry%/}"
    info "npm 镜像: $NPM_CONFIG_REGISTRY (来自 $NPMRC_FILE)"
  fi
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
    -m|--source) SOURCE_REF="$2"; shift 2 ;;
    -m=*|--source=*) SOURCE_REF="${1#*=}"; shift ;;
    -v|--vscode) VSCODE_REF="$2"; shift 2 ;;
    -v=*|--vscode=*) VSCODE_REF="${1#*=}"; shift ;;
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

# 自动探测 mac zip（排除 linux/exe 命名）
CWD="$(pwd -P)"
if [[ -z "$SOURCE_REF" ]]; then
  for f in "$CWD"/codearts-agent-*.zip "$CWD"/CodeArts*.zip; do
    [[ -f "$f" ]] || continue
    case "$(basename "$f")" in
      *linux*|*exe*) continue ;;
    esac
    SOURCE_REF="$(readlink -f "$f")"
    info "自动探测源: $SOURCE_REF"
    break
  done
fi
[[ -n "$SOURCE_REF" ]] || { usage >&2; die "未找到 mac 源 zip。请传入 codearts-agent-<ver>.zip"; }

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

# ---------- deb 提取器（dpkg-deb 不可用时用 ar+tar 回退） ----------
deb_extract() {
  local deb="$1" dest="$2"
  mkdir -p "$dest"
  if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb -x "$deb" "$dest"
  elif command -v ar >/dev/null 2>&1; then
    local tmp="$WORK_DIR/deb-tmp"
    rm -rf "$tmp"; mkdir -p "$tmp"
    ar x "$deb" --output="$tmp" data.tar.xz 2>/dev/null || ar x "$deb" data.tar.xz
    tar -xJf "$tmp/data.tar.xz" -C "$dest"
    rm -rf "$tmp"
  else
    die "需要 dpkg-deb 或 binutils(ar) 来解包 deb"
  fi
}

echo
echo -e "${C_BLUE}════════════════════════════════════════════════════${C_NC}"
echo -e "${C_BLUE}  CodeArts Agent 跨平台移植（VSCode fork → Linux x64）${C_NC}"
echo -e "${C_BLUE}════════════════════════════════════════════════════${C_NC}"
echo "  mac 源:      $SOURCE_REF"
echo "  目标平台:    $BUILD_PLATFORM (deb=$BUILD_DEB rpm=$BUILD_RPM)"
echo

# ============================================================
# 步骤 1: 解压 mac zip → 提取平台无关 app 层 + 读版本
# ============================================================
step "1/6 解压 mac zip 并提取 app 层 ..."
APP_STAGE="$WORK_DIR/mac_app"
if [[ -f "$APP_STAGE/package.json" ]]; then
  info "复用已提取的 app 层"
else
  rm -rf "$APP_STAGE"
  mkdir -p "$APP_STAGE"
  unzip -tq "$SOURCE_REF" || die "zip 完整性校验失败"
  # 只解出 Resources/app/（平台无关），跳过 200MB 的 darwin Electron
  unzip -q "$SOURCE_REF" "CodeArts Agent.app/Contents/Resources/app/*" -d "$WORK_DIR/mac_zip" \
    || die "解压 app 层失败"
  mv "$WORK_DIR/mac_zip/CodeArts Agent.app/Contents/Resources/app/"* "$APP_STAGE/"
  rm -rf "$WORK_DIR/mac_zip"
fi

CA_VER="$(node -p "require('$APP_STAGE/package.json').version")"
VSCODE_VER="$(node -p "require('$APP_STAGE/product.json').vscodeVersion")"
CA_COMMIT="$(node -p "require('$APP_STAGE/product.json').commit")"
info "CodeArts Agent: $CA_VER (commit $CA_COMMIT)"
info "上游 VSCode:    $VSCODE_VER"

# ============================================================
# 步骤 2: 获取 VSCode 官方 linux-deb-x64 运行时基底
# ============================================================
step "2/6 获取 VSCode $VSCODE_VER 官方 linux-deb-x64 基底 ..."
if [[ -z "$VSCODE_REF" ]]; then
  VSCODE_REF="https://update.code.visualstudio.com/${VSCODE_VER}/linux-deb-x64/stable"
fi
VSCODE_DEB="$CACHE_DIR/vscode-${VSCODE_VER}-linux-deb-x64.deb"
if is_url "$VSCODE_REF"; then
  download "$VSCODE_REF" "$VSCODE_DEB"
else
  VSCODE_DEB="$VSCODE_REF"
  [[ -f "$VSCODE_DEB" ]] || die "VSCode deb 不存在: $VSCODE_DEB"
fi

# ============================================================
# 步骤 3: 组装合成树（VSCode 基底 + CodeArts app 层）
# ============================================================
step "3/6 组装合成树 ..."
PAYLOAD="$WORK_DIR/payload"
if [[ -d "$PAYLOAD/usr/share/codearts-agent" && -f "$PAYLOAD/.assembled" ]]; then
  info "复用已组装的合成树"
else
  rm -rf "$PAYLOAD"
  mkdir -p "$PAYLOAD"

  # 3.1 解 VSCode deb 到 payload（/usr/share/code 布局 + desktop + icons）
  deb_extract "$VSCODE_DEB" "$PAYLOAD"
  [[ -d "$PAYLOAD/usr/share/code" ]] || die "VSCode deb 中未找到 /usr/share/code"

  # 3.2 重命名 code → codearts-agent（目录、desktop、bin、hicolor 图标）
  mv "$PAYLOAD/usr/share/code" "$PAYLOAD/usr/share/codearts-agent"
  if [[ -f "$PAYLOAD/usr/share/applications/code.desktop" ]]; then
    mv "$PAYLOAD/usr/share/applications/code.desktop" "$PAYLOAD/usr/share/applications/codearts-agent.desktop"
  fi
  if [[ -f "$PAYLOAD/usr/share/applications/code-url-handler.desktop" ]]; then
    mv "$PAYLOAD/usr/share/applications/code-url-handler.desktop" "$PAYLOAD/usr/share/applications/codearts-agent-url-handler.desktop"
  fi

  # 3.3 保存 VSCode 原 app 的 x64 原生模块清单（稍后按相对路径拷回）
  NATIVE_SRC="$WORK_DIR/vscode-app-native"
  rm -rf "$NATIVE_SRC"
  mkdir -p "$NATIVE_SRC"
  (cd "$PAYLOAD/usr/share/codearts-agent/resources/app" \
    && find . -name '*.node' -type f -exec cp --parents '{}' "$NATIVE_SRC/" \; )
  info "VSCode 基底 x64 原生模块: $(find "$NATIVE_SRC" -name '*.node' | wc -l) 个"

  # 3.4 用 CodeArts 的 app 层整体替换 VSCode 的 app
  rm -rf "$PAYLOAD/usr/share/codearts-agent/resources/app"
  cp -a "$APP_STAGE" "$PAYLOAD/usr/share/codearts-agent/resources/app"

  # 3.5 把 x64 原生模块按相对路径拷回（覆盖 darwin 版 .node）
  (cd "$NATIVE_SRC" && find . -name '*.node' -type f) | while read -r rel; do
    dest="$PAYLOAD/usr/share/codearts-agent/resources/app/${rel#./}"
    mkdir -p "$(dirname "$dest")"
    cp -f "$NATIVE_SRC/$rel" "$dest"
    info "覆盖原生模块: ${rel#./}"
  done

  # 3.6 删除 darwin 专属文件（node-pty 的 spawn-helper 等）
  find "$PAYLOAD/usr/share/codearts-agent/resources/app" -name 'spawn-helper' -delete 2>/dev/null || true

  # 3.7 /usr/bin 入口：VSCode deb 不带 /usr/bin/code（由 postinst 软链创建），
  #     这里直接创建指向 /usr/share/codearts-agent/bin/codearts-agent 的软链
  mkdir -p "$PAYLOAD/usr/bin"
  ln -sf ../share/codearts-agent/bin/codearts-agent "$PAYLOAD/usr/bin/codearts-agent"
  ln -sf ../share/codearts-agent/bin/code-tunnel "$PAYLOAD/usr/bin/codearts-tunnel" 2>/dev/null || true

  # 3.8 图标：VSCode deb 只有 usr/share/pixmaps/vscode.png，无 hicolor 结构。
  ICON_DIR="$PAYLOAD/usr/share/icons/hicolor"
  mkdir -p "$ICON_DIR"
  unzip -p "$SOURCE_REF" "CodeArts Agent.app/Contents/Resources/CodeArts Agent.icns" \
    > "$WORK_DIR/codearts-agent.icns" 2>/dev/null || warn "无法读取 icns 图标"
  python3 - "$WORK_DIR/codearts-agent.icns" "$ICON_DIR" <<'PYEOF' || warn "icns 图标解析失败，沿用 pixmaps/vscode.png"
import struct, sys, os
icns_path, icon_dir = sys.argv[1], sys.argv[2]
data = open(icns_path, 'rb').read()
assert data[:4] == b'icns', 'not an icns file'
# icns 类型 → hicolor 尺寸（PNG/RGBA 子图）
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
        d = os.path.join(icon_dir, f'{size}x{size}', 'apps')
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, 'codearts-agent.png'), 'wb').write(body)
        found += 1
    off += olen
print(f'提取 {found} 个图标尺寸')
PYEOF
  # pixmaps 图标也换名（desktop 的 Icon=codearts-agent 兜底解析）
  if [[ -f "$PAYLOAD/usr/share/pixmaps/vscode.png" ]]; then
    mv "$PAYLOAD/usr/share/pixmaps/vscode.png" "$PAYLOAD/usr/share/pixmaps/codearts-agent.png"
  fi

  # 3.9 bin 入口改名（VSCode bin/code → bin/codearts-agent，内容已按 $0 相对解析无需改）
  if [[ -f "$PAYLOAD/usr/share/codearts-agent/bin/code" ]]; then
    mv "$PAYLOAD/usr/share/codearts-agent/bin/code" "$PAYLOAD/usr/share/codearts-agent/bin/codearts-agent"
  fi
  # cli 入口（usr/bin/code → codearts-agent）
  if [[ -f "$PAYLOAD/usr/bin/code" ]]; then
    mv "$PAYLOAD/usr/bin/code" "$PAYLOAD/usr/bin/codearts-agent"
  fi

  # 3.10 修正 desktop 文件（Name/Exec/Icon）
  #      Exec 必须指向 bin/codearts-agent 包装脚本（含路径解析与环境准备），
  #      直接指向裸 Electron 二进制会因缺初始化而启动失败
  DESKTOP="$PAYLOAD/usr/share/applications/codearts-agent.desktop"
  if [[ -f "$DESKTOP" ]]; then
    sed -i 's|^Name=.*|Name=CodeArts Agent|; s|^Exec=.*|Exec=/usr/share/codearts-agent/bin/codearts-agent %F|; s|^Icon=.*|Icon=codearts-agent|; s|^Comment=.*|Comment=Write, compile, run, consider it done!|; s|^GenericName=.*|GenericName=CodeArts Agent|' "$DESKTOP"
    # StartupWMClass 保持与 applicationName 一致
    if grep -q '^StartupWMClass=' "$DESKTOP"; then
      sed -i 's|^StartupWMClass=.*|StartupWMClass=codearts-agent|' "$DESKTOP"
    else
      echo 'StartupWMClass=codearts-agent' >> "$DESKTOP"
    fi
    # Desktop Action 里的 Exec 同样指向包装脚本（sed 地址中的 $ 为 sed 语法，非 shell 展开）
    # shellcheck disable=SC2016
    sed -i '/^\[Desktop Action/,${s|^Exec=.*|Exec=/usr/share/codearts-agent/bin/codearts-agent %F|}' "$DESKTOP"
  fi

  # 3.9 chrome-sandbox 保持 SUID（deb 里的权限原样保留；rpm 在 %post 设置）
  touch "$PAYLOAD/.assembled"
fi

# ============================================================
# 步骤 4: 版本号与产物命名
# ============================================================
DEB_VER="${CA_VER}-${CA_COMMIT:0:8}"
RPM_VER="${CA_VER}"
RPM_REL="1.${CA_COMMIT:0:8}"

# ============================================================
# 步骤 5: 打包 deb
# ============================================================
if [[ "$BUILD_DEB" -eq 1 ]]; then
  if ! command -v dpkg-deb >/dev/null 2>&1; then
    warn "dpkg-deb 不可用，跳过 deb"
    BUILD_DEB=0
  fi
fi
if [[ "$BUILD_DEB" -eq 1 ]]; then
  step "5/6 打包 deb ..."
  DEB_BUILD="$WORK_DIR/deb_build"
  rm -rf "$DEB_BUILD"
  mkdir -p "$DEB_BUILD"

  # payload → deb 根（含 /usr/share/codearts-agent、desktop、icons、/usr/bin）
  cp -a "$PAYLOAD/." "$DEB_BUILD/"
  rm -f "$DEB_BUILD/.assembled"

  installed_size=$(du -sk "$DEB_BUILD" | cut -f1)
  mkdir -p "$DEB_BUILD/DEBIAN"
  cat > "$DEB_BUILD/DEBIAN/control" <<EOF
Package: codearts-agent
Version: ${DEB_VER}
Architecture: amd64
Maintainer: port-linux
Installed-Size: ${installed_size}
Depends: ca-certificates, libasound2t64 | libasound2, libatk-bridge2.0-0, libatk1.0-0, libatspi2.0-0, libc6, libcairo2, libcurl4 | libcurl3-gnutls | libcurl3-nss, libdbus-1-3, libexpat1, libgbm1, libglib2.0-0, libgtk-3-0, libnspr4, libnss3, libpango-1.0-0, libstdc++6, libudev1, libx11-6, libxcb1, libxcomposite1, libxdamage1, libxext6, libxfixes3, libxkbcommon0, libxkbfile1, libxrandr2, xdg-utils
Recommends: libvulkan1
Section: devel
Priority: optional
Homepage: https://www.huaweicloud.com/product/codearts/ai.html
Description: Unofficial Linux x64 package of Huawei CodeArts Agent
 CodeArts Agent (VSCode fork) ported from the macOS x64 application layer
 onto the official Visual Studio Code linux-x64 runtime.
 Not affiliated with or endorsed by Huawei.
EOF

  find "$DEB_BUILD" -type d -exec chmod 0755 {} +
  OUT_DEB="$OUT_DIR/codearts-agent_${DEB_VER}_amd64.deb"
  dpkg-deb --root-owner-group --build "$DEB_BUILD" "$OUT_DEB" || die "deb 打包失败"
  info "deb 已生成: $OUT_DEB ($(du -h "$OUT_DEB" | cut -f1))"
fi

# ============================================================
# 步骤 6: 打包 rpm
# ============================================================
if [[ "$BUILD_RPM" -eq 1 ]]; then
  if ! command -v rpmbuild >/dev/null 2>&1; then
    warn "rpmbuild 不可用，跳过 rpm"
    BUILD_RPM=0
  fi
fi
if [[ "$BUILD_RPM" -eq 1 ]]; then
  step "6/6 打包 rpm ..."
  RPMROOT="$WORK_DIR/rpmroot"
  rm -rf "$RPMROOT"
  mkdir -p "$RPMROOT"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

  cat > "$RPMROOT/SPECS/codearts-agent.spec" <<SPEC
Name:           codearts-agent
Version:        ${RPM_VER}
Release:        ${RPM_REL}%{?dist}
Summary:        Unofficial Linux x64 package of Huawei CodeArts Agent
License:        MIT
URL:            https://www.huaweicloud.com/product/codearts/ai.html
Vendor:         port-linux
BuildArch:      x86_64
AutoReq:        no
AutoProv:       no

Requires:       alsa-lib, at-spi2-atk, atk, cairo, cups-libs, dbus-libs, expat, glib2, gtk3, nspr, nss, pango, libX11, libxcb, libXcomposite, libXdamage, libXext, libXfixes, libxkbcommon, libxkbfile, libXrandr, curl, xdg-utils
Recommends:     libvulkan

%description
Unofficial Linux x64 package of Huawei CodeArts Agent (VSCode fork).
Ported from the macOS x64 application layer onto the official Visual
Studio Code linux-x64 runtime. Not affiliated with or endorsed by Huawei.

%prep

%build

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
cp -a $PAYLOAD/* %{buildroot}/
rm -f %{buildroot}/.assembled

%post
chmod 4755 '/usr/share/codearts-agent/chrome-sandbox' 2>/dev/null || true
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications 2>/dev/null || true
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -qf /usr/share/icons/hicolor 2>/dev/null || true
fi

%postun
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications 2>/dev/null || true

%files
%defattr(-,root,root,-)
"/usr/share/codearts-agent"
"/usr/bin/codearts-agent"
"/usr/bin/codearts-tunnel"
"/usr/share/applications/codearts-agent.desktop"
"/usr/share/applications/codearts-agent-url-handler.desktop"
"/usr/share/pixmaps/codearts-agent.png"
"/usr/share/icons/hicolor"

%changelog
* $(LC_TIME=C date '+%a %b %d %Y') ported <codearts-agent@port-linux> ${RPM_VER}-${RPM_REL}
- 从 macOS x64 应用层移植到 Linux x64
- 运行时基底: VSCode ${VSCODE_VER} 官方 linux-deb-x64
SPEC

  QA_RPATHS=0 rpmbuild -bb \
    --define "_topdir $RPMROOT" \
    --define "__brp_check_rpaths %{nil}" \
    --define "__brp_mangle_shebangs %{nil}" \
    --define "__os_install_post %{nil}" \
    --define "_unpackaged_files_terminate_build 0" \
    "$RPMROOT/SPECS/codearts-agent.spec" 2>&1 | grep -vE '^\+' || true

  RPM_FILE="$(find "$RPMROOT/RPMS" -name '*.rpm' -print -quit)"
  if [[ -n "$RPM_FILE" ]]; then
    OUT_RPM="$OUT_DIR/$(basename "$RPM_FILE")"
    cp -f "$RPM_FILE" "$OUT_RPM"
    info "rpm 已生成: $OUT_RPM ($(du -h "$OUT_RPM" | cut -f1))"
  else
    warn "rpm 构建未产出文件"
  fi
fi

echo
info "产物目录: $OUT_DIR"
info "中间产物保留在 $WORK_DIR（删除: rm -rf $ROOT）"
