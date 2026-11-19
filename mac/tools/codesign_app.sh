#!/usr/bin/env bash
# 给 .app 签名。配置了 SIGN_IDENTITY 时用固定的自签名证书：签名身份（指定要求）不随版本变化，
# 应用内更新后钥匙串授权、通知权限都保持有效；否则退回 ad-hoc 签名（每次构建身份都会变）。
# 用法：tools/codesign_app.sh <App 路径>
set -euo pipefail
APP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
cd "$(dirname "$0")/.."
[ -f build.local.env ] && eval "$(grep -E '^(SIGN_IDENTITY|SIGN_KEYCHAIN|SIGN_KEYCHAIN_PASSWORD_FILE)=' build.local.env)"
# 签名标识和 App 自己的 Bundle ID 保持一致（公开构建不会带上本地配置里的私人 ID）
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
if [ -n "${SIGN_IDENTITY:-}" ]; then
  KC_ARGS=()
  if [ -n "${SIGN_KEYCHAIN:-}" ]; then
    [ -n "${SIGN_KEYCHAIN_PASSWORD_FILE:-}" ] && security unlock-keychain -p "$(cat "$SIGN_KEYCHAIN_PASSWORD_FILE")" "$SIGN_KEYCHAIN"
    KC_ARGS=(--keychain "$SIGN_KEYCHAIN")
  fi
  codesign --force --deep --timestamp=none ${KC_ARGS[@]+"${KC_ARGS[@]}"} -s "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
  codesign --force --deep -s - --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --strict "$APP"
