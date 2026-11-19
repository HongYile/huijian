#!/usr/bin/env bash
# 发布公开版到 GitHub Releases：构建（不含任何私人配置）→ dmg + zip → 签名清单 update-macos.json → gh release create。
# 公开版客户端从 GitHub Releases 检查更新，用 build.sh 里内置的公开渠道公钥校验签名。
#
# build.local.env 里需要：GITHUB_UPDATE_KEY（公开渠道签名私钥）、GITHUB_REPO（例如 HongYile/huijian），
# 以及 SIGN_IDENTITY 等签名身份（公开版和私人版用同一个证书即可）。需要已登录的 gh。
# 用法：./release_github.sh "更新说明"      工作区必须干净（构建号取 git 提交数）
set -euo pipefail
cd "$(dirname "$0")"
eval "$(grep -E '^(GITHUB_UPDATE_KEY|GITHUB_REPO|SIGN_IDENTITY|PRIVATE_SCAN)=' build.local.env 2>/dev/null || true)"
: "${GITHUB_UPDATE_KEY:?build.local.env 缺少 GITHUB_UPDATE_KEY}"
: "${GITHUB_REPO:?build.local.env 缺少 GITHUB_REPO}"
: "${SIGN_IDENTITY:?build.local.env 缺少 SIGN_IDENTITY，公开版也必须用固定证书签名}"
NOTES="${1:?用法：./release_github.sh \"更新说明\"}"
if [ -n "$(git status --porcelain -- ..)" ] && [ "${ALLOW_DIRTY:-}" != 1 ]; then
  echo "工作区有未提交的改动，请先提交" >&2; git status --short -- .. >&2; exit 1
fi
(cd ../server && GOTOOLCHAIN=local go build -o bin/huijian .)
HY=../server/bin/huijian
PUBKEY=$(sed -nE 's/^UPDATE_PUBKEY="\$\{UPDATE_PUBKEY:-([^}]+)\}"$/\1/p' build.sh)
[ "$($HY release-pubkey "$GITHUB_UPDATE_KEY")" = "$PUBKEY" ] || { echo "GITHUB_UPDATE_KEY 与 build.sh 内置的公开渠道公钥不匹配" >&2; exit 1; }

OUT=build/public; rm -rf "$OUT"; mkdir -p "$OUT"
PUBLIC_BUILD=1 OUT_DIR="$OUT" ./build.sh
APP="$OUT/Huijian.app"; PL="$APP/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PL")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PL")
# 公开版不能带任何私人配置
[ -z "$(/usr/libexec/PlistBuddy -c 'Print :HuijianDefaultServer' "$PL")" ] || { echo "公开版不应预填服务器地址" >&2; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :HuijianUpdateSource' "$PL")" = "github:$GITHUB_REPO" ] || { echo "公开版更新源不对" >&2; exit 1; }
codesign -d -r- "$APP" 2>&1 | grep -qi "certificate leaf = H\"$(echo "$SIGN_IDENTITY" | tr 'A-F' 'a-f')\"" || { echo "公开版没有用 SIGN_IDENTITY 签名" >&2; exit 1; }

# 可选：维护者自己的私人信息扫描（PRIVATE_SCAN --binary <路径>，发现命中返回非 0）
[ -n "${PRIVATE_SCAN:-}" ] && "$PRIVATE_SCAN" --binary "$APP"
ZIPN="Huijian-$VERSION-$BUILD.zip"; DMGN="Huijian-$VERSION.dmg"
ditto -c -k --keepParent "$APP" "$OUT/$ZIPN"
STAGE="$OUT/dmg"; mkdir -p "$STAGE"; ditto "$APP" "$STAGE/Huijian.app"; ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "回笺 $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$OUT/$DMGN"
python3 tools/make_manifest.py "$HY" "$GITHUB_UPDATE_KEY" "$VERSION" "$BUILD" "$NOTES" "$OUT/$ZIPN" > "$OUT/update-macos.json"
BODY="$NOTES

---
**安装**：下载 \`$DMGN\`，把回笺拖进「应用程序」。本应用没有苹果开发者签名，第一次打开会被系统拦截：打开「系统设置 → 隐私与安全性」，在下方点「仍要打开」。之后的版本可以在应用内一键更新。

\`$ZIPN\` 和 \`update-macos.json\` 供应用内更新使用，一般不需要手动下载。"
if [ "${DRY_RUN:-}" = 1 ]; then echo "DRY_RUN：产物在 ${OUT}，未上传"; ls -lh "$OUT" | awk 'NR>1{print $5, $9}'; exit 0; fi
gh release create "v$VERSION" --repo "$GITHUB_REPO" --title "回笺 $VERSION" --notes "$BODY" \
  "$OUT/$DMGN" "$OUT/$ZIPN" "$OUT/update-macos.json"
echo "已发布到 https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
