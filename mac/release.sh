#!/usr/bin/env bash
# 发布 Mac 客户端更新：构建 → 打包 zip → Ed25519 签名 → 上传到 hub。
# 已安装的客户端会在几秒内收到提示（长轮询响应头），点「更新并重启」即可，无需手动覆盖安装。
#
# build.local.env 里需要：
#   UPDATE_KEY        签名私钥文件（huijian release-key 生成，只放在开发机上）
#   UPDATE_PUBKEY     对应公钥（会被打进 App，用来验证更新包）
#   HUIJIAN_ADMIN_URL 管理后台地址（内网）
#   HUIJIAN_ADMIN_TOKEN 或 HUIJIAN_ADMIN_TOKEN_CMD（输出管理令牌的命令，例如从服务器读取；令牌不会被打印）
# 用法：./release.sh ["更新说明"]     默认用最近一次提交的标题作说明
# 构建号取 git 提交数，所以工作区必须干净（先提交再发布）；ALLOW_DIRTY=1 可跳过检查。
set -euo pipefail
cd "$(dirname "$0")"
[ -f build.local.env ] && . ./build.local.env
: "${UPDATE_KEY:?build.local.env 缺少 UPDATE_KEY}"
: "${UPDATE_PUBKEY:?build.local.env 缺少 UPDATE_PUBKEY}"
: "${HUIJIAN_ADMIN_URL:?build.local.env 缺少 HUIJIAN_ADMIN_URL}"
# 已安装的客户端只接受与自己同一证书签名的更新包；ad-hoc 包发出去所有人都装不上，而且会白白占掉一个构建号
: "${SIGN_IDENTITY:?build.local.env 缺少 SIGN_IDENTITY（用 tools/make_signing_identity.sh 生成）。发布包必须用固定证书签名}"
if [ -n "$(git status --porcelain -- ..)" ] && [ "${ALLOW_DIRTY:-}" != 1 ]; then
  echo "工作区有未提交的改动，请先提交（构建号取 git 提交数）：" >&2
  git status --short -- .. >&2
  exit 1
fi
(cd ../server && GOTOOLCHAIN=local go build -o bin/huijian .)
HY=../server/bin/huijian
[ "$($HY release-pubkey "$UPDATE_KEY")" = "$UPDATE_PUBKEY" ] || { echo "UPDATE_KEY 与 UPDATE_PUBKEY 不匹配" >&2; exit 1; }
./build.sh
DR=$(codesign -d -r- build/Huijian.app 2>&1 | grep '^designated')
SIGN_LC=$(echo "$SIGN_IDENTITY" | tr 'A-F' 'a-f')
case "$DR" in
  *"certificate leaf = H\"$SIGN_LC\""*) ;;
  *) echo "构建出的 App 不是用 SIGN_IDENTITY 签名的，拒绝发布：$DR" >&2; exit 1 ;;
esac
PL=build/Huijian.app/Contents/Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PL")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PL")
ZIP=build/Huijian-$VERSION-$BUILD.zip
rm -f "$ZIP"
ditto -c -k --keepParent build/Huijian.app "$ZIP"
NOTES="${1:-$(git log -1 --format=%s)}"
if [ -z "${HUIJIAN_ADMIN_TOKEN:-}" ]; then
  : "${HUIJIAN_ADMIN_TOKEN_CMD:?需要 HUIJIAN_ADMIN_TOKEN 或 HUIJIAN_ADMIN_TOKEN_CMD}"
  HUIJIAN_ADMIN_TOKEN=$(eval "$HUIJIAN_ADMIN_TOKEN_CMD")
fi
export HUIJIAN_ADMIN_URL HUIJIAN_ADMIN_TOKEN
$HY release -key "$UPDATE_KEY" -platform macos -version "$VERSION" -build "$BUILD" -notes "$NOTES" "$ZIP"
