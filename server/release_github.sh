#!/usr/bin/env bash
# 发布服务端到 GitHub Releases（tag server-v<版本>），各地部署的服务端在管理后台「设置 → 服务端更新」一键更新。
# 构建 linux-amd64 / linux-arm64 → 用公开渠道私钥签名生成 update-server.json → gh release create（不标为 latest，
# 免得 Mac 客户端的更新检查读到服务端的 release）。
#
# 用的是 Mac 端同一份发布配置 mac/build.local.env（已被 .gitignore 忽略）：GITHUB_UPDATE_KEY、GITHUB_REPO，可选 PRIVATE_SCAN。
# 可选：同一份配置里有 HUIJIAN_ADMIN_URL（加 HUIJIAN_ADMIN_TOKEN 或 HUIJIAN_ADMIN_TOKEN_CMD，写法同 mac/release.sh）时，
# 发布成功后顺便用 `huijian server-push` 推送到自己的服务器（不经过 GitHub 下载）。推送失败只警告，不影响发布结果；
# 令牌不会被打印。SERVER_PUSH=0 跳过推送。
# 用法：server/release_github.sh "更新说明"      server/ 目录不能有未提交的改动；DRY_RUN=1 只构建不上传
set -euo pipefail
cd "$(dirname "$0")"
eval "$(grep -E '^(GITHUB_UPDATE_KEY|GITHUB_REPO|PRIVATE_SCAN)=' ../mac/build.local.env 2>/dev/null || true)"
: "${GITHUB_UPDATE_KEY:?mac/build.local.env 缺少 GITHUB_UPDATE_KEY}"
: "${GITHUB_REPO:?mac/build.local.env 缺少 GITHUB_REPO}"
NOTES="${1:?用法：server/release_github.sh \"更新说明\"}"
# 服务端程序只依赖 server/，客户端目录的改动不影响
if [ -n "$(git status --porcelain -- .)" ] && [ "${ALLOW_DIRTY:-}" != 1 ]; then
  echo "server/ 有未提交的改动，请先提交" >&2; git status --short -- . >&2; exit 1
fi
# 本地 HEAD 必须已经推送：tag 打在这个提交上，和构建用的代码一致
git fetch -q origin
[ -n "$(git branch -r --contains HEAD 2>/dev/null)" ] || { echo "当前提交还没推送到远端，先 git push" >&2; exit 1; }
VERSION=$(sed -nE 's/^var version = "([^"]+)"$/\1/p' main.go)
BUILD=$(git rev-list --count HEAD)
[ -n "$VERSION" ] || { echo "main.go 里找不到版本号" >&2; exit 1; }
GOTOOLCHAIN=local go test ./... >/dev/null || { echo "测试没通过，不发布" >&2; exit 1; }
GOTOOLCHAIN=local go build -o bin/huijian .
HY=bin/huijian
# 签名私钥必须和程序里内置的公钥对应，否则发出去的版本谁都装不上
BUILTIN=$(sed -nE 's/^const officialUpdatePubKey = "([^"]+)"$/\1/p' selfupdate.go)
[ "$($HY release-pubkey "$GITHUB_UPDATE_KEY")" = "$BUILTIN" ] || { echo "GITHUB_UPDATE_KEY 与 selfupdate.go 内置公钥不匹配" >&2; exit 1; }
OUT=bin/release; rm -rf "$OUT"; mkdir -p "$OUT"
FILES=()
for arch in amd64 arm64; do
  f="$OUT/huijian-$VERSION-linux-$arch"
  CGO_ENABLED=0 GOOS=linux GOARCH=$arch GOTOOLCHAIN=local go build -trimpath -ldflags "-s -w" -o "$f" .
  FILES+=("$f")
done
# 可选：维护者自己的私人信息扫描（发现命中返回非 0）
if [ -n "${PRIVATE_SCAN:-}" ]; then for f in "${FILES[@]}"; do "$PRIVATE_SCAN" --binary "$f"; done; fi
python3 tools/server_manifest.py "$HY" "$GITHUB_UPDATE_KEY" "$VERSION" "$BUILD" "$NOTES" "${FILES[@]}" > "$OUT/update-server.json"
BODY="$NOTES
---
**更新方式**：管理后台「设置 → 服务端更新」点「一键更新」（0.6.0 起；会先备份数据库，签名校验通过才安装）。
服务器访问 GitHub 慢时可以在同一处设置下载代理（0.6.2 起）；下载不了时，把下面对应平台的程序和 \`update-server.json\` 下载到别的电脑，在同一处「手动上传」。
也可以 \`git pull\` 后 \`docker compose up -d --build\` 重新构建镜像。"
if [ "${DRY_RUN:-}" = 1 ]; then echo "DRY_RUN：产物在 ${OUT}，未上传"; ls -lh "$OUT" | awk 'NR>1{print $5, $9}'; exit 0; fi
gh release create "server-v$VERSION" --repo "$GITHUB_REPO" --target "$(git rev-parse HEAD)" --title "回笺服务端 $VERSION" --notes "$BODY" --latest=false \
  "${FILES[@]}" "$OUT/update-server.json"
echo "已发布到 https://github.com/$GITHUB_REPO/releases/tag/server-v$VERSION"

# 顺便推送到自己的服务器（可选）。到这里 GitHub 发布已经成功，下面任何失败都只警告、退出码仍为 0，所以整段关掉 -e -u。
# 地址和令牌的来源和 mac/release.sh 一致：mac/build.local.env 里写了就用它的，没写就沿用外部 export 的
# HUIJIAN_ADMIN_URL / HUIJIAN_ADMIN_TOKEN / HUIJIAN_ADMIN_TOKEN_CMD。配置文件在子 shell 里 source，只取值出来，
# 里面引用了别的变量、多行引号、未加引号的空格都不会影响这个脚本。令牌命令的输出只进变量，错误输出丢弃，令牌不会出现在终端。
if [ "${SERVER_PUSH:-1}" != 0 ]; then
  set +e +u +o pipefail
  local_env() { ( set +u; source ../mac/build.local.env >/dev/null 2>&1; printf %s "${!1:-}" ) 2>/dev/null; }
  PUSH_URL=$(local_env HUIJIAN_ADMIN_URL); PUSH_URL=${PUSH_URL:-${HUIJIAN_ADMIN_URL:-}}
  PUSH_TOKEN=$(local_env HUIJIAN_ADMIN_TOKEN); PUSH_TOKEN=${PUSH_TOKEN:-${HUIJIAN_ADMIN_TOKEN:-}}
  PUSH_TOKEN_CMD=$(local_env HUIJIAN_ADMIN_TOKEN_CMD); PUSH_TOKEN_CMD=${PUSH_TOKEN_CMD:-${HUIJIAN_ADMIN_TOKEN_CMD:-}}
  if [ -n "$PUSH_URL" ]; then
    if [ -z "$PUSH_TOKEN" ] && [ -n "$PUSH_TOKEN_CMD" ]; then
      PUSH_TOKEN=$(eval "$PUSH_TOKEN_CMD" 2>/dev/null </dev/null) || { echo "⚠️ 令牌命令 HUIJIAN_ADMIN_TOKEN_CMD 执行失败（退出码 $?）" >&2; PUSH_TOKEN=""; }
    fi
    if [ -z "$PUSH_TOKEN" ]; then
      echo "⚠️ 没拿到管理令牌（HUIJIAN_ADMIN_TOKEN 或 HUIJIAN_ADMIN_TOKEN_CMD），没有推送到自己的服务器" >&2
    elif ! HUIJIAN_ADMIN_URL="$PUSH_URL" HUIJIAN_ADMIN_TOKEN="$PUSH_TOKEN" "$HY" server-push -manifest "$OUT/update-server.json"; then
      echo "⚠️ 推送到自己的服务器失败（GitHub 发布不受影响）。可以稍后在管理后台一键更新或手动上传，或重新执行：" >&2
      echo "   HUIJIAN_ADMIN_URL=… HUIJIAN_ADMIN_TOKEN=… server/$HY server-push -manifest server/$OUT/update-server.json" >&2
    fi
  fi
  unset PUSH_TOKEN PUSH_TOKEN_CMD
  set -euo pipefail
fi
