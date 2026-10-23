#!/bin/bash
# 一次性操作：把 .signing/ 里那张自签名证书标记为受信任。
#
# 为什么需要：ad-hoc 签名没有稳定身份，系统按 cdhash 认这个 app，
# 每次重新编译 cdhash 都变 → macOS 会把授予的权限（「桌面」文件夹、
# 「辅助功能」）全部收回。而"点空白处触发系统原生显示桌面"必须有辅助功能权限。
#
# codesign 只肯用**受信任**的身份来签名，所以要让这张证书被信任一次。
# 之后每次 ./build.sh 都用同一个身份签名，授权就不会再掉。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CERT="$ROOT/.signing/cert.pem"

[ -f "$CERT" ] || { echo "找不到 $CERT，先跑一次 ./build.sh 生成证书"; exit 1; }

echo "即将把下面这张证书加入**受信任的根证书**："
openssl x509 -in "$CERT" -noout -subject -dates
echo
echo "需要输入你的登录密码（由系统弹窗或终端询问）。"
echo

if security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$CERT"; then
  echo "==> 已信任（系统级）"
else
  echo "系统级失败，改用用户级……"
  security add-trusted-cert -r trustRoot -k "$HOME/Library/Keychains/login.keychain-db" "$CERT"
  echo "==> 已信任（用户级）"
fi

echo
echo "验证（应该能看到 1 valid identities）："
security find-identity -v -p codesigning "$ROOT/.signing/FolderSync.keychain-db"
echo
echo "之后跑 ./build.sh 就会用这个身份签名，重新编译不会再掉权限。"
