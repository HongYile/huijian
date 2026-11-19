#!/usr/bin/env bash
# 生成固定的自签名代码签名身份，放在一个独立的钥匙串文件里（不碰登录钥匙串）。
# 用法：tools/make_signing_identity.sh <目录>   例如 ~/secrets/huijian-signing
# 完成后把输出的几行写进 mac/build.local.env。证书不需要被系统信任，codesign 用 SHA-1 指纹即可签名。
set -euo pipefail
DIR="${1:?用法: $0 <目录>}"
mkdir -p "$DIR"; chmod 700 "$DIR"; DIR="$(cd "$DIR" && pwd)"
KC="$DIR/huijian-signing.keychain-db"; PWF="$DIR/keychain.password"
[ -e "$KC" ] && { echo "已存在 $KC，不会覆盖" >&2; exit 1; }
umask 077
openssl rand -hex 24 > "$PWF"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Huijian Self-Signed Code Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
# 用系统自带的 LibreSSL：它导出的 p12 能被 security import 直接识别
/usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 7300 -config "$TMP/cert.cnf" 2>/dev/null
P12PW=$(openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout "pass:$P12PW" -name "Huijian Self-Signed Code Signing"
security create-keychain -p "$(cat "$PWF")" "$KC"
security set-keychain-settings "$KC"            # 不自动上锁
security unlock-keychain -p "$(cat "$PWF")" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$P12PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$(cat "$PWF")" "$KC" >/dev/null
SHA1=$(security find-identity -p codesigning "$KC" | awk '/Huijian Self-Signed/{print $2; exit}')
echo "已生成签名身份 $SHA1"
echo "请把下面三行写进 mac/build.local.env："
echo "SIGN_IDENTITY=$SHA1"
echo "SIGN_KEYCHAIN=$KC"
echo "SIGN_KEYCHAIN_PASSWORD_FILE=$PWF"
