#!/usr/bin/env bash
#
# 创建本地代码签名身份（只需执行一次）
# =====================================
#
# 为什么需要：ad-hoc 签名的应用，TCC（辅助功能 / 麦克风授权）是按 cdhash 记录的，
# 每次重新构建 cdhash 都会变，于是权限失效、要重新授权。
# 换成固定证书签名后，指定要求变成「identifier + 证书叶子哈希」，跨构建稳定，
# 授权一次即可长期有效。
#
# 生成的东西都在 ~/.voice-global/signing/，只用于本机，不上传任何地方。
set -euo pipefail

DIR="$HOME/.voice-global/signing"
NAME="DSH Voice Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

mkdir -p "$DIR"
cd "$DIR"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "✓ 签名证书已存在：$NAME"
  exit 0
fi

echo "==> 生成本地自签名证书（有效期 10 年）"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout sign-key.pem -out sign-cert.pem \
  -subj "/CN=$NAME" \
  -addext "extendedKeyUsage=codeSigning" \
  -addext "keyUsage=digitalSignature" 2>/dev/null

openssl pkcs12 -export -out sign.p12 -inkey sign-key.pem -in sign-cert.pem -passout pass:dshvoice 2>/dev/null

echo "==> 导入登录钥匙串（只授权 codesign 使用该私钥）"
security import sign.p12 -k "$KEYCHAIN" -P dshvoice -T /usr/bin/codesign

echo
echo "✅ 完成。重新执行 ./build.sh 即会用该身份签名。"
echo "   验证：codesign -d -r- \"build/DSH Voice.app\"  应显示 certificate leaf = H\"…\""
