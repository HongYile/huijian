#!/usr/bin/env bash
# 把 iPhone 版发布到自己的回笺服务器：构建 IPA → huijian release -platform ios 上传。
# 发布后已安装的回笺会提示更新，在「设置 → 关于」里「下载并用 GBox 安装」；GBox 软件源 <服务器>/ios/gbox.appsrc 也会列出新版本。
#
# 用的是 Mac 端同一套发布配置（mac/build.local.env，已被 .gitignore 忽略）：
#   UPDATE_KEY（发布签名私钥）、HUIJIAN_ADMIN_URL、HUIJIAN_ADMIN_TOKEN 或 HUIJIAN_ADMIN_TOKEN_CMD
# 登录页预填的服务器地址在 ios/build.local.env 的 DEFAULT_SERVER。
# 用法：./release.sh "更新说明"      工作区必须干净（构建号取 git 提交数）
set -euo pipefail
cd "$(dirname "$0")"
eval "$(grep -E '^(UPDATE_KEY|HUIJIAN_ADMIN_URL|HUIJIAN_ADMIN_TOKEN|HUIJIAN_ADMIN_TOKEN_CMD)=' ../mac/build.local.env 2>/dev/null || true)"
: "${UPDATE_KEY:?mac/build.local.env 缺少 UPDATE_KEY}"
: "${HUIJIAN_ADMIN_URL:?mac/build.local.env 缺少 HUIJIAN_ADMIN_URL}"
if [ -n "$(git status --porcelain -- ..)" ] && [ "${ALLOW_DIRTY:-}" != 1 ]; then
  echo "工作区有未提交的改动，请先提交（构建号取 git 提交数）：" >&2
  git status --short -- .. >&2
  exit 1
fi
(cd ../server && GOTOOLCHAIN=local go build -o bin/huijian .)
HY=../server/bin/huijian
./build.sh > /dev/null
IPA=$(ls -t build/Huijian-*.ipa | head -1)
PL=$(mktemp -d); unzip -q -o "$IPA" 'Payload/Huijian.app/Info.plist' -d "$PL"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PL/Payload/Huijian.app/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PL/Payload/Huijian.app/Info.plist")
# App 里内置的更新公钥必须和发布私钥配对，否则装上这个版本以后，下一次应用内下载会校验失败
EMBED=$(/usr/libexec/PlistBuddy -c 'Print :HuijianUpdatePublicKey' "$PL/Payload/Huijian.app/Info.plist" 2>/dev/null || true)
rm -rf "$PL"
if [ "$EMBED" != "$($HY release-pubkey "$UPDATE_KEY")" ]; then
  echo "IPA 里内置的更新公钥（UPDATE_PUBKEY）和发布私钥 UPDATE_KEY 不配对，停止发布。检查 mac/build.local.env" >&2
  exit 1
fi
NOTES="${1:-$(git log -1 --format=%s)}"
if [ -z "${HUIJIAN_ADMIN_TOKEN:-}" ]; then
  : "${HUIJIAN_ADMIN_TOKEN_CMD:?需要 HUIJIAN_ADMIN_TOKEN 或 HUIJIAN_ADMIN_TOKEN_CMD}"
  HUIJIAN_ADMIN_TOKEN=$(eval "$HUIJIAN_ADMIN_TOKEN_CMD")
fi
export HUIJIAN_ADMIN_URL HUIJIAN_ADMIN_TOKEN
$HY release -key "$UPDATE_KEY" -platform ios -version "$VERSION" -build "$BUILD" -notes "$NOTES" "$IPA"
echo "已发布 iOS $VERSION (build $BUILD)：$IPA"
