#!/usr/bin/env bash
#
# port.sh — 将 Windows 版 Xiaomi MiMo 移植到 Linux
#
# 一键脚本：原版 Linux deb + Windows exe → rpm + deb（含登录修复）
#
# 用法:
#   ./port.sh                                   # 自动探测目录内的 .deb 和 .exe，按当前 OS 生成对应包
#   ./port.sh -p all                            # 同时生成 rpm 和 deb
#   ./port.sh -p rpm                            # 仅生成 rpm
#   ./port.sh -p deb                            # 仅生成 deb
#   ./port.sh <*.exe> [<*.deb>] [-p rpm|deb|all]
#
# 依赖: 7z, ar, tar, node (npx), rpmbuild (打 rpm 时)
#        无需任何外部脚本，登录修复已内置
set -euo pipefail

# ---------- 颜色输出 ----------
C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'; C_NC='\033[0m'
info()  { echo -e "${C_GREEN}[信息]${C_NC} $*"; }
warn()  { echo -e "${C_YELLOW}[警告]${C_NC} $*"; }
step()  { echo -e "${C_BLUE}[步骤]${C_NC} $*"; }
die()   { echo -e "${C_RED}[失败]${C_NC} $*" >&2; exit 1; }

# ---------- 依赖检查 ----------
for cmd in 7z ar tar node npx; do
  command -v "$cmd" >/dev/null 2>&1 || die "缺少依赖命令: $cmd (Fedora: sudo dnf install p7zip binutils tar nodejs)"
done

BUILD_PLATFORM=""   # 空=自动检测
EXE_FILE=""; DEB_FILE=""

# ---------- 平台自动检测 ----------
detect_platform() {
  # Fedora/RHEL/openSUSE/Amazon → rpm
  # Debian/Ubuntu/Mint/Kali → deb
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
      fedora|rhel|centos|rocky|alma|opensuse*|tumbleweed|leap|amzn|sles|suse)
        echo "rpm" ;;
      debian|ubuntu|linuxmint|kali|elementary|pop|raspbian|deepin)
        echo "deb" ;;
      *)
        # 有 rpm 命令优先 rpm，否则 deb
        if command -v rpm >/dev/null 2>&1 && ! command -v dpkg >/dev/null 2>&1; then
          echo "rpm"
        else
          echo "deb"
        fi ;;
    esac
  else
    # 回退: 有 rpmbuild → rpm，有 dpkg-deb → deb，否则默认 deb
    if command -v rpmbuild >/dev/null 2>&1; then
      echo "rpm"
    else
      echo "deb"
    fi
  fi
}

# ---------- 参数解析 ----------
ARGS=("$@")
for arg in "${ARGS[@]}"; do
  case "$arg" in
    -p|--platform) shift_next=1 ;;
    -p=*|--platform=*) BUILD_PLATFORM="${arg#*=}" ;;
    rpm|deb|all) [[ "${shift_next:-0}" == "1" ]] && { BUILD_PLATFORM="$arg"; shift_next=0; } ;;
    *.exe)  EXE_FILE="$(readlink -f "$arg")" ;;
    *.deb)  DEB_FILE="$(readlink -f "$arg")" ;;
    -*) die "未知选项: $arg。用法: $0 [-p rpm|deb|all] <*.exe> [<*.deb>]" ;;
    *) die "未知参数: $arg" ;;
  esac
done
unset shift_next

# 确定构建目标
if [[ -z "$BUILD_PLATFORM" ]]; then
  BUILD_PLATFORM="$(detect_platform)"
fi
case "$BUILD_PLATFORM" in
  rpm)  BUILD_RPM=1; BUILD_DEB=0 ;;
  deb)  BUILD_RPM=0; BUILD_DEB=1 ;;
  all)  BUILD_RPM=1; BUILD_DEB=1 ;;
  *)    die "无效平台: $BUILD_PLATFORM (可选: rpm, deb, all)" ;;
esac

# 自动探测
CWD="$(pwd -P)"
if [[ -z "$EXE_FILE" ]]; then
  for f in "$CWD"/*.exe; do [[ -f "$f" ]] && EXE_FILE="$(readlink -f "$f")" && break; done
fi
if [[ -z "$DEB_FILE" ]]; then
  for f in "$CWD"/XiaomiMiMo-*-x64.deb; do
    [[ -f "$f" ]] || continue
    # 跳过 fixed.deb
    [[ "$f" == *.fixed.deb ]] && continue
    DEB_FILE="$(readlink -f "$f")" && break
  done
fi
[[ -n "$EXE_FILE" ]]  || die "未找到 .exe 文件。用法: $0 [-p rpm|deb|all] <*.exe> [<*.deb>]"
[[ -n "$DEB_FILE" ]]  || die "未找到 .deb 文件（会跳过 .fixed.deb）。用法: $0 [-p rpm|deb|all] <*.exe> <*.deb>"
[[ -f "$EXE_FILE" ]] || die "exe 文件不存在: $EXE_FILE"
[[ -f "$DEB_FILE" ]] || die "deb 文件不存在: $DEB_FILE"

# ---------- 提取版本号 ----------
extract_version() {
  local f="$1"
  # 从文件名提取: XiaomiMiMo-26.914.142245-x64-... → 26.914.142245
  basename "$f" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}
EXE_VER="$(extract_version "$EXE_FILE")"
DEB_VER="$(extract_version "$DEB_FILE")"
[[ -n "$EXE_VER" ]] || die "无法从 exe 文件名提取版本号: $EXE_FILE"
[[ -n "$DEB_VER" ]] || die "无法从 deb 文件名提取版本号: $DEB_FILE"

echo
echo -e "${C_BLUE}════════════════════════════════════════════════════${C_NC}"
echo -e "${C_BLUE}  Xiaomi MiMo 跨平台移植${C_NC}"
echo -e "${C_BLUE}════════════════════════════════════════════════════${C_NC}"
echo "  Windows exe:  $EXE_FILE  (v$EXE_VER)"
echo "  Linux   deb:  $DEB_FILE  (v$DEB_VER)"
echo "  目标平台:     $BUILD_PLATFORM (deb=$BUILD_DEB rpm=$BUILD_RPM)"
echo

# ---------- 工作目录 ----------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
info "工作目录: $WORK"

# ============================================================
# 步骤 1: 解 Windows exe → 取新版 app.asar + evolve-seed
# ============================================================
step "1/6 解包 Windows exe ..."
mkdir -p exe_extract
7z x "$EXE_FILE" -oexe_extract -y >/dev/null 2>&1 || die "exe 解包失败"
NSIS_7Z="exe_extract/\$PLUGINSDIR/app-64.7z"
[[ -f "$NSIS_7Z" ]] || {
  # 尝试查找 app-64.7z
  NSIS_7Z="$(find exe_extract -name 'app-64.7z' -print -quit)"
  [[ -n "$NSIS_7Z" ]] || die "exe 内未找到 app-64.7z"
}
7z x "$NSIS_7Z" -oexe_extract/win_resources \
  "resources/app.asar" \
  "resources/evolve-seed" \
  -y >/dev/null 2>&1 || die "app-64.7z 解包失败"

WIN_ASAR="exe_extract/win_resources/resources/app.asar"
WIN_EVOLVE="exe_extract/win_resources/resources/evolve-seed"
[[ -f "$WIN_ASAR" ]] || die "exe 内未找到 resources/app.asar"
[[ -d "$WIN_EVOLVE" ]] || die "exe 内未找到 resources/evolve-seed"

# 验证 exe 版本
npx --yes @electron/asar extract-file "$WIN_ASAR" package.json >/dev/null 2>&1
WIN_VER="$(node -e "console.log(require('./package.json').version)" 2>/dev/null || true)"
rm -f package.json
info "Windows 版 app.asar 版本: ${WIN_VER:-未知} (文件名: $EXE_VER)"

# ============================================================
# 步骤 2: 解原版 deb → Linux 应用目录 + usr + control
# ============================================================
step "2/6 解包原版 deb ..."
mkdir -p deb_extract
( cd deb_extract && ar x "$DEB_FILE" debian-binary control.tar.xz data.tar.xz )
mkdir -p deb_extract/data deb_extract/control
tar -xJf deb_extract/data.tar.xz -C deb_extract/data || die "deb data 解包失败"
tar -xJf deb_extract/control.tar.xz -C deb_extract/control 2>/dev/null || true

APP_DIR="deb_extract/data/opt/Xiaomi MiMo"
RES_DIR="$APP_DIR/resources"
[[ -f "$RES_DIR/app.asar" ]] || die "deb 内未找到 app.asar"
info "Linux 原版 app.asar 版本: $DEB_VER"

# ============================================================
# 步骤 3: 替换 app.asar + evolve-seed 为 Windows 新版
# ============================================================
step "3/6 替换 app.asar 和 evolve-seed 为 Windows 新版 ..."
# 删除旧版 app.asar 备份(如有)
rm -f "$RES_DIR/app.asar.bak"
# 替换 app.asar
cp -f "$WIN_ASAR" "$RES_DIR/app.asar"
info "app.asar 已替换为 Windows v$EXE_VER"

# 替换 evolve-seed
rm -rf "$RES_DIR/evolve-seed"
cp -a "$WIN_EVOLVE" "$RES_DIR/evolve-seed"
info "evolve-seed 已替换为 Windows v$EXE_VER"

# ============================================================
# 步骤 4: 登录修复 — 注入 node-machine-id 垫片到 app.asar
# ============================================================
step "4/6 登录修复 (注入 node-machine-id 垫片) ..."
ASAR_WORK="$WORK/asar_fix"
npx --yes @electron/asar extract "$RES_DIR/app.asar" "$ASAR_WORK/asar" 2>/dev/null \
  || warn "extract 对个别跨平台 unpacked 文件报错（预期内，忽略）"
[[ -f "$ASAR_WORK/asar/out/main/index.mjs" ]] \
  || die "解包后未找到 out/main/index.mjs，asar 可能不完整"

# 幂等: 垫片已存在则跳过
if [[ ! -f "$ASAR_WORK/asar/node_modules/node-machine-id/index.js" ]]; then
  SHIM_DIR="$ASAR_WORK/asar/node_modules/node-machine-id"
  mkdir -p "$SHIM_DIR"
  cat > "$SHIM_DIR/package.json" << 'EOF'
{
  "name": "node-machine-id",
  "version": "1.1.12",
  "main": "index.js"
}
EOF
  cat > "$SHIM_DIR/index.js" << 'EOF'
'use strict';
// Minimal shim of node-machine-id (missing from the packaged asar).
// Linux: read /var/lib/dbus/machine-id or /etc/machine-id.
const fs = require('fs');
const crypto = require('crypto');

function machineIdSync(original) {
  for (const p of ['/var/lib/dbus/machine-id', '/etc/machine-id']) {
    try {
      const id = fs.readFileSync(p, 'utf8').trim();
      if (id) {
        return original ? id : crypto.createHash('sha256').update(id).digest('hex');
      }
    } catch {}
  }
  throw new Error('machine-id unavailable');
}

function machineId(original) {
  return Promise.resolve(machineIdSync(original));
}

module.exports = { machineIdSync, machineId };
EOF
  npx --yes @electron/asar pack "$ASAR_WORK/asar" "$RES_DIR/app.asar" || die "asar 打包失败"
  npx --yes @electron/asar list "$RES_DIR/app.asar" | grep -q 'node_modules/node-machine-id/index.js' \
    || die "校验失败：垫片未成功写入 asar"
  info "node-machine-id 垫片已注入"
else
  warn "node-machine-id 垫片已存在，跳过"
fi
info "登录修复完成"

# ============================================================
# 步骤 5: 组装最终应用目录
# ============================================================
step "5/6 组装应用目录 ..."
FINAL_DIR="$WORK/mimo-linux"
cp -a "$APP_DIR" "$FINAL_DIR"
# usr 部分(.desktop + 图标)
mkdir -p "$FINAL_DIR/../usr/bin"
ln -sf "/opt/Xiaomi MiMo/xiaomi-mimo-desktop" "$FINAL_DIR/../usr/bin/xiaomi-mimo-desktop"
cp -a deb_extract/data/usr/* "$WORK/usr/" 2>/dev/null || true
mkdir -p "$WORK/usr/bin"
ln -sf "/opt/Xiaomi MiMo/xiaomi-mimo-desktop" "$WORK/usr/bin/xiaomi-mimo-desktop" 2>/dev/null || true

# 清理损坏符号链接(rpm cpio 打包会失败)
find "$FINAL_DIR" -type l ! -exec test -e {} \; -delete 2>/dev/null || true
info "应用目录就绪: $FINAL_DIR"

# ============================================================
# 步骤 6: 打包 deb / rpm
# ============================================================
PKG_VER="$EXE_VER"
OUT_DIR="$CWD"

# ---------- 打 deb ----------
if [[ "$BUILD_DEB" -eq 1 ]]; then
  step "6/6 打包 deb ..."
  DEB_BUILD="$WORK/deb_build"
  mkdir -p "$DEB_BUILD/opt" "$DEB_BUILD/usr/bin"
  cp -a "$FINAL_DIR" "$DEB_BUILD/opt/Xiaomi MiMo"
  # usr (.desktop + 图标)
  cp -a deb_extract/data/usr/share "$DEB_BUILD/usr/" 2>/dev/null || \
    mkdir -p "$DEB_BUILD/usr/share"
  ln -sf "/opt/Xiaomi MiMo/xiaomi-mimo-desktop" "$DEB_BUILD/usr/bin/xiaomi-mimo-desktop"

  # DEBIAN/control
  mkdir -p "$DEB_BUILD/DEBIAN"
  # 计算安装大小(KB)
  INST_SIZE="$(du -sk "$DEB_BUILD/opt" | cut -f1)"
  cat > "$DEB_BUILD/DEBIAN/control" << EOF
Package: xiaomi-mimo-desktop
Version: $PKG_VER
Architecture: amd64
Maintainer: MiMo Desktop <mimo-desktop@xiaomi.com>
Installed-Size: $INST_SIZE
Depends: libgtk-3-0, libnotify4, libnss3, libxss1, libxtst6, xdg-utils, libatspi2.0-0, libuuid1, libsecret-1-0
Recommends: libappindicator3-1
Section: default
Priority: optional
Homepage: https://app.xiaomimimo.com/download
Description: Xiaomi MiMo 桌面客户端 — 集成 AI 编程助手的智能开发工具
 由 Windows x86-64 安装包 ($PKG_VER) 移植到 Linux。
EOF
  # 复用原版 deb 的 postinst/postrm
  if [[ -f deb_extract/control/postinst ]]; then
    cp deb_extract/control/postinst "$DEB_BUILD/DEBIAN/"
  fi
  if [[ -f deb_extract/control/postrm ]]; then
    cp deb_extract/control/postrm "$DEB_BUILD/DEBIAN/"
  fi
  chmod 755 "$DEB_BUILD/DEBIAN"/post* 2>/dev/null || true

  echo "2.0" > "$WORK/debian-binary"
  ( cd "$DEB_BUILD" && tar --xz -cf "$WORK/data.tar.xz" opt usr )
  ( cd "$DEB_BUILD" && tar --xz -cf "$WORK/control.tar.xz" DEBIAN )
  OUT_DEB="$OUT_DIR/XiaomiMiMo-$PKG_VER-x64.deb"
  ( cd "$WORK" && ar rcs "$OUT_DEB" debian-binary control.tar.xz data.tar.xz ) || die "deb 打包失败"
  info "deb 已生成: $OUT_DEB ($(du -h "$OUT_DEB" | cut -f1))"
fi

# ---------- 打 rpm ----------
if [[ "$BUILD_RPM" -eq 1 ]]; then
  command -v rpmbuild >/dev/null 2>&1 || { warn "rpmbuild 不可用，跳过 rpm"; BUILD_RPM=0; }
fi
if [[ "$BUILD_RPM" -eq 1 ]]; then
  step "6/6 打包 rpm ..."
  RPMROOT="$WORK/rpmroot"
  mkdir -p "$RPMROOT"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS,payload}

  # payload
  mkdir -p "$RPMROOT/payload/opt"
  cp -a "$FINAL_DIR/." "$RPMROOT/payload/opt/Xiaomi MiMo"
  mkdir -p "$RPMROOT/payload/usr"/{bin,share/{applications,icons/hicolor/1024x1024/apps}}
  cp -a deb_extract/data/usr/share/applications/xiaomi-mimo.desktop \
        "$RPMROOT/payload/usr/share/applications/" 2>/dev/null || true
  cp -a deb_extract/data/usr/share/icons/hicolor/1024x1024/apps/xiaomi-mimo-desktop.png \
        "$RPMROOT/payload/usr/share/icons/hicolor/1024x1024/apps/" 2>/dev/null || true
  ln -sf "/opt/Xiaomi MiMo/xiaomi-mimo-desktop" \
         "$RPMROOT/payload/usr/bin/xiaomi-mimo-desktop"
  # 只删除相对路径且目标不存在的损坏符号链接; 保留指向绝对路径(/opt/...)的符号链接
  while IFS= read -r -d '' lnk; do
    target="$(readlink "$lnk")"
    [[ "$target" == /* ]] || rm -f "$lnk"
  done < <(find "$RPMROOT/payload" -type l -print0) 2>/dev/null || true

  # spec 文件
  cat > "$RPMROOT/SPECS/xiaomi-mimo-desktop.spec" << SPEC
Name:           xiaomi-mimo-desktop
Version:        $PKG_VER
Release:        1%{?dist}
Summary:        Xiaomi MiMo 桌面客户端 — 集成 AI 编程助手的智能开发工具
License:        Proprietary
URL:            https://app.xiaomimimo.com/download
Vendor:         MiMo Desktop <mimo-desktop@xiaomi.com>
BuildArch:      x86_64
AutoReq:        no
AutoProv:       no

Requires:       gtk3
Requires:       libnotify
Requires:       nss
Requires:       libXScrnSaver
Requires:       libXtst
Requires:       xdg-utils
Requires:       at-spi2-atk
Requires:       libuuid
Requires:       libsecret
Recommends:     libappindicator-gtk3

%description
Xiaomi MiMo 桌面客户端 — 集成 AI 编程助手的智能开发工具。
由 Windows x86-64 安装包 ($PKG_VER) 移植到 Linux。

%prep

%build

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
cp -a $RPMROOT/payload/* %{buildroot}/

%post
ln -sf '/opt/Xiaomi MiMo/xiaomi-mimo-desktop' '/usr/bin/xiaomi-mimo-desktop' 2>/dev/null || true
if ! { [[ -L /proc/self/ns/user ]] && unshare --user true; } 2>/dev/null; then
    chmod 4755 '/opt/Xiaomi MiMo/chrome-sandbox' 2>/dev/null || true
else
    chmod 0755 '/opt/Xiaomi MiMo/chrome-sandbox' 2>/dev/null || true
fi
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications 2>/dev/null || true
command -v update-mime-database >/dev/null 2>&1 && update-mime-database /usr/share/mime 2>/dev/null || true

%postun
rm -f '/usr/bin/xiaomi-mimo-desktop' 2>/dev/null || true
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications 2>/dev/null || true

%files
%defattr(-,root,root,-)
"/opt/Xiaomi MiMo"
"/usr/bin/xiaomi-mimo-desktop"
"/usr/share/applications/xiaomi-mimo.desktop"
"/usr/share/icons/hicolor/1024x1024/apps/xiaomi-mimo-desktop.png"

%changelog
* $(LC_TIME=C date '+%a %b %d %Y') ported <mimo-desktop@xiaomi.com> $PKG_VER-1
- 从 Windows $PKG_VER x86-64 移植到 Linux
- 注入 node-machine-id 垫片修复登录
SPEC

  # 构建: 禁用 Fedora 的 rpath 检查/shebang mangling/install post (对预编译 payload 无意义)
  QA_RPATHS=0 rpmbuild -bb \
    --define "_topdir $RPMROOT" \
    --define "__brp_check_rpaths %{nil}" \
    --define "__brp_mangle_shebangs %{nil}" \
    --define "__os_install_post %{nil}" \
    --define "_unpackaged_files_terminate_build 0" \
    "$RPMROOT/SPECS/xiaomi-mimo-desktop.spec" 2>&1 | grep -vE '^\+' || true

  RPM_FILE="$(find "$RPMROOT/RPMS" -name '*.rpm' -print -quit)"
  if [[ -n "$RPM_FILE" ]]; then
    OUT_RPM="$OUT_DIR/xiaomi-mimo-desktop-$PKG_VER-1.fc44.x86_64.rpm"
    cp -f "$RPM_FILE" "$OUT_RPM"
    info "rpm 已生成: $OUT_RPM ($(du -h "$OUT_RPM" | cut -f1))"
  else
    warn "rpm 构建未产出文件"
  fi
fi

# ---------- 完成 ----------
echo
echo -e "${C_GREEN}════════════════════════════════════════════════════${C_NC}"
echo -e "${C_GREEN}  移植完成！${C_NC}"
echo -e "${C_GREEN}════════════════════════════════════════════════════${C_NC}"
echo "  版本: $PKG_VER (deb $DEB_VER → exe $EXE_VER)"
[[ "$BUILD_DEB" -eq 1 ]] && echo "  deb:  $OUT_DEB"
[[ "$BUILD_RPM" -eq 1 && -n "${OUT_RPM:-}" ]] && echo "  rpm:  $OUT_RPM"
echo
echo "安装命令:"
[[ "$BUILD_DEB" -eq 1 ]] && echo "  deb: sudo apt install -y \"$OUT_DEB\"   # 或 sudo dpkg -i \"$OUT_DEB\""
[[ "$BUILD_RPM" -eq 1 && -n "${OUT_RPM:-}" ]] && echo "  rpm: sudo dnf install -y \"$OUT_RPM\"   # 或 sudo rpm -i \"$OUT_RPM\""
echo
