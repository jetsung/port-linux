#!/usr/bin/env bash
# port-workbuddy.sh — 将腾讯 WorkBuddy macOS 版移植到 Linux（deb / rpm）
#
# 参考 AUR workbuddy 配方与 forkdo/workbuddy-linux 的 build-deb.sh：
# 下载 WorkBuddy 官方 macOS 应用资源（WorkBuddy-darwin-x64-<ver>.zip），
# 解压 app.asar，替换平台相关的 better-sqlite3 / node-pty 为 Linux 构建，
# 用 Electron linux runtime 启动，重新打包为 deb / rpm。
#
# 用法:
#   ./port-workbuddy.sh                              # 自动探测当前目录 zip，按当前 OS 打包
#   ./port-workbuddy.sh -p all                       # 同时打 deb 和 rpm
#   ./port-workbuddy.sh -p deb WorkBuddy-darwin-x64-*.zip
#   ./port-workbuddy.sh -s "https://.../WorkBuddy-darwin-x64-*.zip"  # 从 URL 下载
#
# 依赖: unzip, tar, node, npx, curl/wget; 打 deb 需 dpkg-deb; 打 rpm 需 rpmbuild

usage() {
  cat <<'EOF'
port-workbuddy.sh — 将腾讯 WorkBuddy macOS 版移植到 Linux（deb / rpm）

下载（或使用本地）WorkBuddy 官方 macOS 应用资源（WorkBuddy-darwin-x64-<ver>.zip），
解压 app.asar，替换平台相关的 better-sqlite3 / node-pty 为 Linux 构建，
用 Electron linux runtime 启动，重新打包为 deb / rpm。

用法:
  ./port-workbuddy.sh                              # 自动探测当前目录 zip，按当前 OS 打包
  ./port-workbuddy.sh -p all                       # 同时打 deb 和 rpm
  ./port-workbuddy.sh -p deb WorkBuddy-darwin-x64-*.zip
  ./port-workbuddy.sh -s "https://.../WorkBuddy-darwin-x64-*.zip"  # 从 URL 下载

选项:
  -p, --platform rpm|deb|all   构建目标；省略时按当前 OS 自动检测
  -s, --source PATH|URL        源 zip：本地路径或下载地址；省略时自动探测当前目录
  -e, --electron VERSION       Electron runtime 版本（默认 37.10.3）
  -v, --pkgver VERSION         上游版本号；省略时从源文件名提取
  -h, --help                   显示本帮助

环境变量:
  DEBUG=1                      调试模式（set -eux，打印每条命令）
  IS_CHINA=1                   中国网络环境，下载走 CDN 加速
  CDN=<url>                    CDN 前缀地址（默认 https://fastfile.asfd.cn/），
                               形式: <CDN>/<完整原始 URL>
  NPM_CONFIG_USERCONFIG        npm 配置文件路径（默认 ~/.npmrc），
                               其中的 registry 用于下载 node 依赖

依赖: unzip, tar, node, npx, curl/wget; 打 deb 需 dpkg-deb; 打 rpm 需 rpmbuild
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
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  die "缺少下载器: curl 或 wget"
fi

# Electron runtime 版本（与 WorkBuddy 内置 Electron Framework 对齐，可用 -e 覆盖）
ELECTRON_VERSION="${ELECTRON_VERSION:-37.10.3}"
# 平台无关原生模块版本（来自 AUR 配方）
BETTER_SQLITE3_VER="13.0.3"
NODE_PTY_VER="1.2.0-beta.14"

# ---------- npm 镜像（从 ~/.npmrc 读取 registry） ----------
# 若 ~/.npmrc 配置了 registry（如 npmmirror.com），用它下载 node 依赖 tgz；否则走官方源。
NPM_REGISTRY="https://registry.npmjs.org"
NPMRC_FILE="${NPM_CONFIG_USERCONFIG:-$HOME/.npmrc}"
if [[ -f "$NPMRC_FILE" ]]; then
  configured_registry=$(sed -n 's/^[[:space:]]*registry[[:space:]]*=[[:space:]]*//p' "$NPMRC_FILE" | head -1)
  if [[ "$configured_registry" == http://* || "$configured_registry" == https://* ]]; then
    NPM_REGISTRY="${configured_registry%/}"
    info "使用 npm 镜像: $NPM_REGISTRY (来自 $NPMRC_FILE)"
  fi
fi

BUILD_PLATFORM="" # 空=自动检测
SOURCE_REF=""     # 源 zip：本地路径或 URL
PKG_VER=""        # 上游版本号（如 5.6.2.39298511）
PKG_HASH=""       # git hash（如 37a65c0b）

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
  -e | --electron)
    ELECTRON_VERSION="$2"
    shift 2
    ;;
  -e=* | --electron=*)
    ELECTRON_VERSION="${1#*=}"
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
  -*) usage >&2; die "未知选项: $1" ;;
  *) die "未知参数: $1" ;;
  esac
done

# 确定构建目标
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

# 自动探测源 zip
CWD="$(pwd -P)"
if [[ -z "$SOURCE_REF" ]]; then
  for f in "$CWD"/WorkBuddy-darwin-x64-*.zip; do
    [[ -f "$f" ]] && SOURCE_REF="$(readlink -f "$f")" && {
      info "自动探测源: $SOURCE_REF"
      break
    }
  done
fi
[[ -n "$SOURCE_REF" ]] || die "未找到源 zip。用法: $0 [-p rpm|deb|all] <WorkBuddy-darwin-x64-*.zip>"

# ---------- 提取版本号 ----------
# 文件名形如 WorkBuddy-darwin-x64-5.6.2.39298511-37a65c0b.zip
#   版本段 = 5.6.2.39298511，hash = 37a65c0b
extract_version() {
  local f="$1" base ver_str
  base="$(basename "$f")"
  base="${base%.zip}"
  ver_str="${base#WorkBuddy-darwin-x64-}"
  echo "$ver_str"
}

is_url() { [[ "$1" == http://* || "$1" == https://* ]]; }

# ---------- 目录布局 ----------
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ROOT="$SCRIPT_DIR/build"
CACHE_DIR="$ROOT/cache"
WORK_DIR="$ROOT/work"
OUT_DIR="$ROOT/out"
mkdir -p "$CACHE_DIR" "$WORK_DIR" "$OUT_DIR"

# ---------- CDN 加速（IS_CHINA=1 时启用，仅对 GitHub 系域名生效） ----------
# 用法: CDN=<url> 环境变量可覆盖，默认 https://fastfile.asfd.cn/
# 形式: <CDN>/<完整原始 URL>，如 https://fastfile.asfd.cn/https://github.com/...
CDN_URL="${CDN:-https://fastfile.asfd.cn}"
# 归一化：确保末尾恰好一个 /
CDN_URL="${CDN_URL%% }"
CDN_URL="${CDN_URL%*/}/"

is_china() { [[ "${IS_CHINA:-}" == "1" ]]; }

# 仅这些域名的下载走 CDN（npm registry 等其他域名直连）
cdn_applicable() {
  case "$1" in
    https://github.com/* | https://raw.githubusercontent.com/* | https://objects.githubusercontent.com/*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------- 下载器（带缓存复用 + CDN 加速） ----------
# IS_CHINA=1 且命中 CDN 适用域名时经 CDN 下载；CDN 失败自动回退直连原始 URL。
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
echo -e "${C_BLUE}  WorkBuddy 跨平台移植${C_NC}"
echo -e "${C_BLUE}════════════════════════════════════════════════════${C_NC}"
echo "  源:          $SOURCE_REF"
echo "  Electron:    $ELECTRON_VERSION"
echo "  目标平台:    $BUILD_PLATFORM (deb=$BUILD_DEB rpm=$BUILD_RPM)"
echo

# ============================================================
# 步骤 1: 获取源 zip → 解压 → 取 app.asar
# ============================================================
step "1/7 获取并解压源 zip ..."
if is_url "$SOURCE_REF"; then
  SOURCE_ZIP="$CACHE_DIR/$(basename "$SOURCE_REF")"
  download "$SOURCE_REF" "$SOURCE_ZIP"
else
  SOURCE_ZIP="$SOURCE_REF"
  [[ -f "$SOURCE_ZIP" ]] || die "源 zip 不存在: $SOURCE_ZIP"
fi

# 提取版本号
if [[ -z "$PKG_VER" ]]; then
  VER_STR="$(extract_version "$SOURCE_ZIP")"
  PKG_VER="${VER_STR%-*}"
  PKG_HASH="${VER_STR##*-}"
  [[ -n "$PKG_VER" ]] || die "无法从文件名提取版本号: $(basename "$SOURCE_ZIP")"
  info "版本: $PKG_VER (hash: ${PKG_HASH:-未知})"
fi
# deb 版本号允许含 hash（用 - 分隔）；rpm Version 不允许 -，hash 放 Release
DEB_VER="${PKG_VER}${PKG_HASH:+-$PKG_HASH}"
RPM_REL="1${PKG_HASH:+.${PKG_HASH}}"

APP_STAGE="$WORK_DIR/app"
RESOURCES="$APP_STAGE/WorkBuddy.app/Contents/Resources"
if [[ -f "$RESOURCES/app.asar" ]]; then
  info "复用已解压的源 zip"
else
  rm -rf "$APP_STAGE"
  mkdir -p "$APP_STAGE"
  unzip -tq "$SOURCE_ZIP" || die "zip 完整性校验失败"
  unzip -q "$SOURCE_ZIP" -d "$APP_STAGE" || die "zip 解压失败"
fi
[[ -f "$RESOURCES/app.asar" ]] || die "zip 内未找到 WorkBuddy.app/Contents/Resources/app.asar"

# ============================================================
# 步骤 2: 组装应用目录 + 解压 app.asar
# ============================================================
step "2/7 解压 app.asar ..."
APP_DIR="$WORK_DIR/workbuddy"
ASAR_UNPACKED="$APP_DIR/app.asar.unpacked"
if [[ -f "$ASAR_UNPACKED/main/index.js" ]]; then
  info "复用已解压的 app.asar"
else
  rm -rf "$APP_DIR"
  mkdir -p "$APP_DIR"
  # ASAR 标记为 unpacked 的条目存在 app.asar.unpacked 旁，运行时需要，先合并
  if [[ -d "$RESOURCES/app.asar.unpacked" ]]; then
    cp -a "$RESOURCES/app.asar.unpacked" "$ASAR_UNPACKED"
  else
    mkdir -p "$ASAR_UNPACKED"
  fi
  # 上游 ASAR header 引用若干 unpacked 文件但 macOS ZIP 中缺失，
  # 逐个补空占位让 asar 能走完整个 archive 而非中途停在后续 JS 依赖前。
  asar_log="$WORK_DIR/asar-extract.log"
  extracted=false
  for _ in $(seq 1 50); do
    if npx --yes asar@3.2.0 extract "$RESOURCES/app.asar" "$ASAR_UNPACKED" >"$asar_log" 2>&1; then
      extracted=true
      break
    fi
    missing=$(sed -n "s/.*path: '\([^']*\)'.*/\1/p" "$asar_log" | head -1)
    case "$missing" in
    "$RESOURCES/app.asar.unpacked/"*)
      warn "补占位: ${missing#"$RESOURCES/app.asar.unpacked/"}"
      mkdir -p "$(dirname "$missing")"
      touch "$missing"
      ;;
    *)
      cat "$asar_log" >&2
      die "ASAR 解压失败且无法恢复（缺失 sidecar 路径不可识别）"
      ;;
    esac
  done
  [[ "$extracted" == true ]] || die "ASAR 解压 50 次后仍未完成"
fi

# 校验关键文件
for required_file in main/index.js node_modules/@larksuiteoapi/node-sdk/package.json; do
  [[ -f "$ASAR_UNPACKED/$required_file" ]] || die "ASAR 解压不完整: 缺少 $required_file"
done

# ============================================================
# 步骤 3: 替换 better-sqlite3 + node-pty 为 Linux 构建
# ============================================================
step "3/7 替换平台原生模块 (better-sqlite3 / node-pty) ..."
better_sqlite="$CACHE_DIR/better-sqlite3-${BETTER_SQLITE3_VER}.tgz"
node_pty="$CACHE_DIR/node-pty-linux-x64-${NODE_PTY_VER}.tgz"
download "$NPM_REGISTRY/better-sqlite3/-/better-sqlite3-${BETTER_SQLITE3_VER}.tgz" "$better_sqlite"
download "$NPM_REGISTRY/@lydell/node-pty-linux-x64/-/node-pty-linux-x64-${NODE_PTY_VER}.tgz" "$node_pty"

rm -rf "$ASAR_UNPACKED/node_modules/better-sqlite3" \
  "$ASAR_UNPACKED/node_modules/@lydell/node-pty-linux-x64" \
  "$ASAR_UNPACKED/node_modules/@lydell/node-pty-linux-arm64"
mkdir -p "$ASAR_UNPACKED/node_modules/better-sqlite3" \
  "$ASAR_UNPACKED/node_modules/@lydell/node-pty-linux-x64"
tar -xzf "$better_sqlite" --strip-components=1 -C "$ASAR_UNPACKED/node_modules/better-sqlite3"
tar -xzf "$node_pty" --strip-components=1 -C "$ASAR_UNPACKED/node_modules/@lydell/node-pty-linux-x64"
info "原生模块已替换为 Linux x64 版本"

# ============================================================
# 步骤 4: 可移植性补丁（对齐 AUR 配方）
# ============================================================
step "4/7 打可移植性补丁 ..."
# 1) tray right-click: macOS 用 popUpContextMenu，Linux 改用 setContextMenu
main_js="$ASAR_UNPACKED/main/index.js"
sed -i 's/tray\.on("right-click", () => this\.tray?\.popUpContextMenu(contextMenu))/tray.setContextMenu(contextMenu)/g' "$main_js"
# 2) process.resourcesPath → '/opt/workbuddy'（硬编码安装路径）
while IFS= read -r -d '' file; do
  sed -i "s#process\.resourcesPath#'/opt/workbuddy'#g" "$file"
done < <(grep -IlZR --null 'process\.resourcesPath' "$ASAR_UNPACKED")
info "补丁已应用（tray 右键菜单 + resourcesPath 重写）"

# ============================================================
# 步骤 5: 下载 Electron Linux runtime
# ============================================================
step "5/7 下载 Electron $ELECTRON_VERSION (linux-x64) ..."
electron_zip="$CACHE_DIR/electron-v${ELECTRON_VERSION}-linux-x64.zip"
download "https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-linux-x64.zip" "$electron_zip"
if [[ -d "$APP_DIR/electron/electron" || -f "$APP_DIR/electron/electron" ]]; then
  info "复用已解压的 Electron"
else
  rm -rf "$APP_DIR/electron"
  mkdir -p "$APP_DIR/electron"
  unzip -q "$electron_zip" -d "$APP_DIR/electron" || die "Electron 解压失败"
fi
# chrome-sandbox 需要 SUID（deb 构建时直接设；rpm 在 %post 里设）
chmod 4755 "$APP_DIR/electron/chrome-sandbox" 2>/dev/null || true

# ============================================================
# 步骤 6: 组装最终应用目录（/opt/workbuddy 布局）
# ============================================================
step "6/7 组装应用目录 ..."
# 图标
ICON_SRC="$ASAR_UNPACKED/resources/icon.png"
[[ -f "$ICON_SRC" ]] || die "缺少应用图标: $ICON_SRC"

# /usr/bin/workbuddy 启动脚本
mkdir -p "$APP_DIR/../usr/bin"
cat >"$APP_DIR/../usr/bin/workbuddy" <<'EOF'
#!/bin/sh
exec /opt/workbuddy/electron/electron /opt/workbuddy/app.asar.unpacked "$@"
EOF
chmod 0755 "$APP_DIR/../usr/bin/workbuddy"

# .desktop 文件
mkdir -p "$APP_DIR/../usr/share/applications"
cat >"$APP_DIR/../usr/share/applications/workbuddy.desktop" <<'EOF'
[Desktop Entry]
Name=WorkBuddy
Exec=/usr/bin/workbuddy %U
Terminal=false
Type=Application
Icon=/usr/share/icons/hicolor/1024x1024/apps/workbuddy.png
StartupWMClass=workbuddy
Comment=WorkBuddy AI agents
Comment[zh_CN]=腾讯云代码助手
Categories=Office;
EOF

# 图标
mkdir -p "$APP_DIR/../usr/share/icons/hicolor/1024x1024/apps"
install -Dm644 "$ICON_SRC" "$APP_DIR/../usr/share/icons/hicolor/1024x1024/apps/workbuddy.png"

# 清理损坏符号链接（rpm cpio 打包会失败）
find "$APP_DIR" -type l ! -exec test -e {} \; -delete 2>/dev/null || true
info "应用目录就绪: $APP_DIR"

# ============================================================
# 步骤 7: 打包 deb / rpm
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
  step "7/7 打包 deb ..."
  DEB_BUILD="$WORK_DIR/deb_build"
  rm -rf "$DEB_BUILD"
  mkdir -p "$DEB_BUILD/opt" "$DEB_BUILD/usr/bin" \
    "$DEB_BUILD/usr/share/applications" \
    "$DEB_BUILD/usr/share/icons/hicolor/1024x1024/apps" \
    "$DEB_BUILD/usr/share/doc/workbuddy" "$DEB_BUILD/DEBIAN"

  cp -a "$APP_DIR" "$DEB_BUILD/opt/workbuddy"
  cp -a "$APP_DIR/../usr/bin/workbuddy" "$DEB_BUILD/usr/bin/workbuddy"
  cp -a "$APP_DIR/../usr/share/applications/workbuddy.desktop" "$DEB_BUILD/usr/share/applications/"
  cp -a "$APP_DIR/../usr/share/icons/hicolor/1024x1024/apps/workbuddy.png" "$DEB_BUILD/usr/share/icons/hicolor/1024x1024/apps/"

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
 This package ports the upstream macOS application resources to Linux.
EOF

  cat >"$DEB_BUILD/usr/share/doc/workbuddy/copyright" <<EOF
This is an unofficial redistribution/compatibility package.
WorkBuddy and its application resources are proprietary software owned by Tencent
or their respective rights holders. No additional license is granted by this package.
Upstream: https://www.workbuddy.cn/app
AUR packaging reference: https://aur.archlinux.org/packages/workbuddy
Packaged upstream version: ${PKG_VER}
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
  step "7/7 打包 rpm ..."
  RPMROOT="$WORK_DIR/rpmroot"
  rm -rf "$RPMROOT"
  mkdir -p "$RPMROOT"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS,payload}

  # payload
  mkdir -p "$RPMROOT/payload/opt" "$RPMROOT/payload/usr"/{bin,share/{applications,icons/hicolor/1024x1024/apps}}
  cp -a "$APP_DIR" "$RPMROOT/payload/opt/workbuddy"
  cp -a "$APP_DIR/../usr/bin/workbuddy" "$RPMROOT/payload/usr/bin/workbuddy"
  cp -a "$APP_DIR/../usr/share/applications/workbuddy.desktop" "$RPMROOT/payload/usr/share/applications/"
  cp -a "$APP_DIR/../usr/share/icons/hicolor/1024x1024/apps/workbuddy.png" "$RPMROOT/payload/usr/share/icons/hicolor/1024x1024/apps/"

  # 只删除相对路径且目标不存在的损坏符号链接；保留指向绝对路径的符号链接
  while IFS= read -r -d '' lnk; do
    target="$(readlink "$lnk")"
    [[ "$target" == /* ]] || rm -f "$lnk"
  done < <(find "$RPMROOT/payload" -type l -print0) 2>/dev/null || true

  # spec 文件
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
Unofficial Linux package of Tencent WorkBuddy.
WorkBuddy is an AI Agent office tool from Tencent Cloud Code Assistant.
This package ports the upstream macOS application resources to Linux.

%prep

%build

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
cp -a $RPMROOT/payload/* %{buildroot}/

%post
if ! { [[ -L /proc/self/ns/user ]] && unshare --user true; } 2>/dev/null; then
    chmod 4755 '/opt/workbuddy/electron/chrome-sandbox' 2>/dev/null || true
else
    chmod 0755 '/opt/workbuddy/electron/chrome-sandbox' 2>/dev/null || true
fi
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications 2>/dev/null || true

%postun
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications 2>/dev/null || true

%files
%defattr(-,root,root,-)
"/opt/workbuddy"
"/usr/bin/workbuddy"
"/usr/share/applications/workbuddy.desktop"
"/usr/share/icons/hicolor/1024x1024/apps/workbuddy.png"

%changelog
* $(LC_TIME=C date '+%a %b %d %Y') ported <workbuddy@port-linux> ${PKG_VER}-${RPM_REL}
- 从 macOS ${PKG_VER} 移植到 Linux
- 替换 better-sqlite3 / node-pty 为 Linux x64 构建
- 内置 Electron ${ELECTRON_VERSION} runtime
SPEC

  # 构建：禁用 rpath 检查 / shebang mangling / install post（对预编译 payload 无意义）
  QA_RPATHS=0 rpmbuild -bb \
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

# ---------- 完成 ----------
echo
info "产物目录: $OUT_DIR"
info "中间产物保留在 $WORK_DIR（删除: rm -rf $ROOT）"
