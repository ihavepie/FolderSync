#!/bin/bash
# 打包 FolderSync，产出可以直接分发/安装的三种形式
#
# 用法:
#   ./package.sh            # 先编译，再打包
#   ./package.sh --no-build # 不重新编译，直接用现成的那份 app 打包
#
# 产物（默认都在仓库内的 build/ 下，可用 OUT_DIR 覆盖）:
#   FolderSync-<版本>.zip   解压即用，最省事（推荐）
#   FolderSync-<版本>.pkg   双击安装，自动装到 /Applications
#   FolderSync-<版本>.dmg   挂载后把 app 拖进「应用程序」
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

# 和 build.sh 保持一致：产物默认放在仓库内的 build/
DIST="${OUT_DIR:-$ROOT/build}"
APP="$DIST/FolderSync.app"

if [ "${1:-}" != "--no-build" ]; then
  "$ROOT/build.sh"
fi

if [ ! -d "$APP" ]; then
  echo "找不到 $APP，先跑一次 ./build.sh" >&2
  exit 1
fi

# 版本号从 Info.plist 读，避免两处对不上
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
NAME="FolderSync-$VERSION"
ZIP="$DIST/$NAME.zip"
PKG="$DIST/$NAME.pkg"
DMG="$DIST/$NAME.dmg"

mkdir -p "$DIST"

# 打包前确认签名还在（bundle 内容改动过签名就会失效）
echo "==> 校验签名"
codesign --verify --deep --strict "$APP"

# --- 1) zip ---
# 用 ditto 而不是 zip：它会完整保留 bundle 里的权限位、扩展属性和符号链接
echo "==> 生成 zip"
ditto -c -k --keepParent "$APP" "$ZIP"

# --- 2) pkg（安装到 /Applications）---
# 注意**不能用 `pkgbuild --component`**：那样打出来的包会带一段
#   <relocate><bundle id="local.foldersync.app"/></relocate>
# 安装器看到系统里已经有同 bundle id 的 app（比如开发目录里的 build/FolderSync.app）
# 就把安装"重定位"到那个副本上，/Applications 里**什么都不出现**。
# 实测踩过：装完以为成功了，其实只是把 build/ 下的那个盖了一遍。
# 用 --root + --install-location / 仍然会带（实测），所以下面手动删掉这一段。
PKG=""
if command -v pkgbuild >/dev/null 2>&1; then
  echo "==> 生成 pkg"
  PKG="$DIST/$NAME.pkg"
  PKGROOT="$(mktemp -d)"
  mkdir -p "$PKGROOT/Applications"
  cp -R "$APP" "$PKGROOT/Applications/"
  pkgbuild --root "$PKGROOT" \
    --install-location / \
    --identifier "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" \
    --version "$VERSION" \
    "$PKG" >/dev/null
  rm -rf "$PKGROOT"

  # 即使 --root，pkgbuild 还是会因为 payload 里认出了 .app 而塞进一段
  #   <relocate><bundle id="local.foldersync.app"/></relocate>
  # 只删掉这一段（其余元数据保留），安装器才会老老实实装到 install-location。
  # 注意：pkgutil --expand 的目标目录**必须不存在**（给个已存在的空目录会报
  # "Error 17: File exists"），所以这里取的是临时目录下面的一个子路径。
  EXPAND="$(mktemp -d)/expanded"
  pkgutil --expand "$PKG" "$EXPAND"
  python3 - "$EXPAND" <<'PY'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
for info in root.rglob("PackageInfo"):
    text = info.read_text()
    new = re.sub(r"\n\s*<relocate>.*?</relocate>", "", text, flags=re.S)
    if new != text:
        info.write_text(new)
PY
  # flatten 的目标文件必须不存在，所以先写到临时文件再盖回去
  pkgutil --flatten "$EXPAND" "$PKG.new"
  mv "$PKG.new" "$PKG"
  rm -rf "$EXPAND"
else
  echo "==> 跳过 pkg（没有 pkgbuild）"
fi

# --- 3) dmg（最好看，但有些环境造不出来，失败了不影响其它产物）---
echo "==> 生成 dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/应用程序"
DMG=""
if hdiutil create -volname "FolderSync $VERSION" -srcfolder "$STAGE" \
      -ov -format UDZO "$DIST/$NAME.dmg" >/dev/null 2>&1; then
  DMG="$DIST/$NAME.dmg"
else
  echo "    这台机器上 hdiutil 造不出 dmg，跳过（zip / pkg 不受影响）"
fi

# --- 4) 汇总 ---
echo
echo "==> 完成，产物在 $DIST"
for f in "$ZIP" "$PKG" "$DMG"; do
  [ -n "$f" ] || continue
  printf '  %-28s %8s  SHA256=%s\n' \
    "$(basename "$f")" \
    "$(du -h "$f" | cut -f1)" \
    "$(shasum -a 256 "$f" | cut -c1-16)…"
done
cat <<'TIP'

安装：
  .zip  解压 → 把 FolderSync.app 拖进「应用程序」
  .pkg  双击 → 按提示装到「应用程序」
  .dmg  双击挂载 → 把 FolderSync 拖进「应用程序」
TIP

# 安装提示按**实际签名**给：build.sh 有证书时用本地自签证书，没有才退回 ad-hoc。
# （之前这里写死成 ad-hoc，用证书构建的时候提示是错的。）
#
# 别写成 `codesign … | grep -q …`：grep 一命中就退出，codesign 收到 SIGPIPE
# 返回 141，配合 `set -o pipefail` 整个管道算失败 —— 判定会永远走 ad-hoc 分支。
SIG_INFO="$(codesign -dv --verbose=2 "$APP" 2>&1 || true)"
case "$SIG_INFO" in
  *"FolderSync Local Signing"*)
    cat <<'TIP'

注意：这是**本地自签证书**（FolderSync Local Signing），不是 Apple 开发者证书。
      本机已信任过这张证书，所以重编译后「桌面」等权限不会被收回；
      换一台 Mac 首次打开仍会被 Gatekeeper 拦下，右键 → 打开，
      或到「系统设置 → 隐私与安全性」点「仍要打开」。
TIP
    ;;
  *)
    cat <<'TIP'

注意：这是 **ad-hoc 签名**（没有证书）。换一台 Mac 首次打开会被 Gatekeeper
      拦下，右键 → 打开，或到「系统设置 → 隐私与安全性」点「仍要打开」。
      另外：每次重新编译签名都会变，macOS 会把之前授予的「桌面」等权限收回，
      重新点一次弹窗的「允许」即可。
TIP
    ;;
esac

