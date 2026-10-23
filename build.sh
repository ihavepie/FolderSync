#!/bin/bash
# 编译 FolderSync.app —— 双向实时同步的文件夹窗口
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/Sources"

# 产物目录：默认放仓库内的 build/（已在 .gitignore 里），可以用 OUT_DIR 环境变量覆盖。
OUT_DIR="${OUT_DIR:-$ROOT/build}"
APP="$OUT_DIR/FolderSync.app"

# 沙盒环境下 clang 模块缓存必须落在可写位置
export CLANG_MODULE_CACHE_PATH="$ROOT/.modulecache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

echo "==> 清理"
rm -rf "$APP"
mkdir -p "$OUT_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 Swift"
swiftc \
  -O \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -framework CoreServices \
  -framework Quartz \
  -framework QuickLookThumbnailing \
  -o "$APP/Contents/MacOS/FolderSync" \
  "$SRC"/*.swift

echo "==> 组装 bundle"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
# 写一个构建时间戳：出问题时一眼就能看出"跑的是不是最新版"
/usr/libexec/PlistBuddy -c "Add :FolderSyncBuildTime string $(date '+%m-%d %H:%M')" \
  "$APP/Contents/Info.plist" >/dev/null 2>&1 || \
  /usr/libexec/PlistBuddy -c "Set :FolderSyncBuildTime $(date '+%m-%d %H:%M')" \
  "$APP/Contents/Info.plist" >/dev/null 2>&1
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 签名"
# 为什么不用 ad-hoc：
#   ad-hoc 签名**没有稳定身份**，系统按 cdhash 认这个 app。
#   每次重新编译 cdhash 都变 → macOS 会把之前授予的权限（「桌面」文件夹、
#   「辅助功能」）全部收回。表现就是"刚授权过，重新编译一下又失效了"。
#   而点空白处要触发系统原生的"显示桌面"（合成 Fn+F11），就必须有辅助功能权限。
# 所以这里用一张**项目自带的自签名证书**（放在 .signing/ 里，不动系统钥匙串）：
#   证书固定 → 指定要求（Designated Requirement）固定 → 授权不会因为重编译而掉。
SIGN_DIR="$ROOT/.signing"
KEYCHAIN="$SIGN_DIR/FolderSync.keychain-db"
CERT_NAME="FolderSync Local Signing"

setup_signing_identity() {
  mkdir -p "$SIGN_DIR"
  chmod 700 "$SIGN_DIR"
  local cfg="$SIGN_DIR/openssl.cnf"
  cat > "$cfg" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = FolderSync Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  ( cd "$SIGN_DIR" &&
    openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
      -days 3650 -nodes -config openssl.cnf >/dev/null 2>&1 &&
    # **必须 -legacy -macalg sha1**：LibreSSL 的 pkcs12 默认用 AES-256 + SHA256，
    # macOS 的 security 读不了，会报 "MAC verification failed (wrong password?)"。
    # 用 legacy 格式（3DES 密钥 / RC2 证书 / SHA1 MAC）才能导入成可用的身份。
    openssl pkcs12 -export -legacy -macalg sha1 \
      -inkey key.pem -in cert.pem -out identity.p12 \
      -passout pass:foldersync -name "FolderSync Local Signing" >/dev/null 2>&1 ) || return 1

  security create-keychain -p foldersync "$KEYCHAIN" >/dev/null 2>&1 || return 1
  security set-keychain-settings -lut 21600 "$KEYCHAIN" >/dev/null 2>&1
  security unlock-keychain -p foldersync "$KEYCHAIN" >/dev/null 2>&1 || return 1
  security import "$SIGN_DIR/identity.p12" -k "$KEYCHAIN" -P foldersync \
    -A -T /usr/bin/codesign >/dev/null 2>&1 || return 1
  security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k foldersync "$KEYCHAIN" >/dev/null 2>&1
  rm -f "$SIGN_DIR/key.pem" "$SIGN_DIR/identity.p12"
  return 0
}

SIGNED=0
if [ ! -f "$KEYCHAIN" ]; then
  echo "    首次运行：生成本地自签名证书（放在 .signing/，不进系统钥匙串）"
  setup_signing_identity || echo "    生成失败，退回 ad-hoc"
fi
if [ -f "$KEYCHAIN" ]; then
  security unlock-keychain -p foldersync "$KEYCHAIN" >/dev/null 2>&1
  # codesign 只在**钥匙串搜索列表**里找身份，所以临时把我们的加进去，签完还原。
  LOGIN_CHAIN="$HOME/Library/Keychains/login.keychain-db"
  security list-keychains -d user -s "$LOGIN_CHAIN" "$KEYCHAIN" >/dev/null 2>&1
  if codesign --force --sign "$CERT_NAME" --timestamp=none "$APP" >/dev/null 2>&1 \
     || codesign --force --sign "$CERT_NAME" --keychain "$KEYCHAIN" \
          --timestamp=none "$APP" >/dev/null 2>&1; then
    SIGNED=1
    echo "    用本地证书签名（身份固定，重编译不会掉授权）"
  fi
  security list-keychains -d user -s "$LOGIN_CHAIN" >/dev/null 2>&1
fi
if [ "$SIGNED" -eq 0 ]; then
  echo "    退回 ad-hoc 签名（注意：重编译后系统授权会失效）"
  codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/    /'
fi

echo "==> 完成: $APP"
ls -la "$APP/Contents/MacOS/"
