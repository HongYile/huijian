#!/usr/bin/env bash
# 构建 回笺 Huijian.app（macOS 14+，arm64，不需要开发者账号）
# 可选配置（环境变量，或写在 build.local.env 里——该文件已被 .gitignore 忽略）：
#   BUNDLE_ID       默认 io.github.hongyile.huijian
#   DEFAULT_SERVER  配对窗口预填的服务器地址，例如 https://push.example.com
#   UPDATE_SOURCE   更新源：github:<owner>/<repo>（默认，官方 GitHub Releases）或 hub（从自己的回笺服务器更新）
#   UPDATE_PUBKEY   更新包签名公钥（huijian release-pubkey 输出）。默认是官方 GitHub 发布渠道的公钥；
#                   改用 hub 源时换成你自己的公钥
#   SIGN_IDENTITY / SIGN_KEYCHAIN / SIGN_KEYCHAIN_PASSWORD_FILE
#                   固定的代码签名身份（tools/make_signing_identity.sh 生成）；为空则 ad-hoc 签名
#   VERSION         默认读 VERSION 文件；BUILD 默认取 git 提交数（必须随发布递增）
set -euo pipefail
cd "$(dirname "$0")"
#   PUBLIC_BUILD=1  构建公开发布版：只从 build.local.env 读取签名身份，忽略其中的私人服务器 / 更新源配置
#   OUT_DIR         输出目录，默认 build
if [ -f build.local.env ]; then
  if [ "${PUBLIC_BUILD:-}" = 1 ]; then
    eval "$(grep -E '^(SIGN_IDENTITY|SIGN_KEYCHAIN|SIGN_KEYCHAIN_PASSWORD_FILE)=' build.local.env)"
  else
    . ./build.local.env
  fi
fi
BUNDLE_ID="${BUNDLE_ID:-io.github.hongyile.huijian}"
DEFAULT_SERVER="${DEFAULT_SERVER:-}"
UPDATE_SOURCE="${UPDATE_SOURCE:-github:HongYile/huijian}"
# 官方 GitHub 发布渠道的签名公钥（私钥只在维护者手里）
UPDATE_PUBKEY="${UPDATE_PUBKEY:-XySRu/CNn8ODqgnD5ZLZWGo3VbVryLv1RTjVETHekZw=}"
VERSION="${VERSION:-$(cat VERSION)}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
# 构建产物实际放在 build.noindex（以 .noindex 结尾的目录不会被 Spotlight 收录，
# 搜索「回笺 / Huijian」时只出现「应用程序」里那一个），build 是指向它的符号链接，其他脚本照常用 build/…
if [ ! -L build ]; then rm -rf build; mkdir -p build.noindex; ln -s build.noindex build; fi
OUT_DIR="${OUT_DIR:-build}"
APP=$OUT_DIR/Huijian.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# 图标：Resources/AppIcon.icns 由 design/icon/make.py 生成（改图标后重新运行它）
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
SDK=$(xcrun --sdk macosx --show-sdk-path)
# -wmo：全模块优化（跨文件内联、去虚化）
xcrun swiftc -sdk "$SDK" -target arm64-apple-macos14.0 -swift-version 5 -O -wmo \
  -module-name Huijian Sources/*.swift -o "$APP/Contents/MacOS/Huijian"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
 <key>CFBundleName</key><string>Huijian</string>
 <key>CFBundleDisplayName</key><string>回笺</string>
 <key>CFBundleExecutable</key><string>Huijian</string>
 <key>CFBundlePackageType</key><string>APPL</string>
 <key>CFBundleShortVersionString</key><string>${VERSION}</string>
 <key>CFBundleIconFile</key><string>AppIcon</string>
 <key>CFBundleVersion</key><string>${BUILD}</string>
 <key>HuijianDefaultServer</key><string>${DEFAULT_SERVER}</string>
 <key>HuijianUpdatePublicKey</key><string>${UPDATE_PUBKEY}</string>
 <key>HuijianUpdateSource</key><string>${UPDATE_SOURCE}</string>
 <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
 <key>LSMinimumSystemVersion</key><string>14.0</string>
 <key>LSUIElement</key><true/>
 <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
 <key>NSHighResolutionCapable</key><true/>
 <key>NSAppTransportSecurity</key><dict>
   <key>NSAllowsArbitraryLoads</key><true/>
   <key>NSAllowsLocalNetworking</key><true/>
 </dict>
 <key>CFBundleURLTypes</key><array><dict>
   <key>CFBundleURLName</key><string>${BUNDLE_ID}</string>
   <key>CFBundleURLSchemes</key><array><string>huijian</string><string>hongyan</string></array>
 </dict></array>
</dict></plist>
PLIST
tools/codesign_app.sh "$APP"
echo "构建完成：${APP}  ${VERSION} (build ${BUILD})  ${BUNDLE_ID}${DEFAULT_SERVER:+  默认服务器 ${DEFAULT_SERVER}}${UPDATE_PUBKEY:+  更新源 ${UPDATE_SOURCE}}"
