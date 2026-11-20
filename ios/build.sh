#!/usr/bin/env bash
# 构建 回笺 iPhone 客户端（不用 Xcode 工程：swiftc 直接编译，actool 编译图标）。
# 用法：
#   ./build.sh            真机：build/Huijian-<版本>-<构建号>.ipa（未签名，用 GBox 等工具重签安装）
#   ./build.sh sim        模拟器：build/sim/Huijian.app（ad-hoc 签名，tests/ 里的脚本用）
# 可选配置（环境变量，或写在 build.local.env 里——该文件已被 .gitignore 忽略）：
#   DEFAULT_SERVER  登录页预填的服务器地址，例如 https://push.example.com
#   BUNDLE_ID       默认 io.github.hongyile.huijian
#   VERSION         默认读 VERSION 文件；BUILD 默认取 git 提交数（必须随发布递增）
#   UPDATE_PUBKEY   更新包签名公钥（huijian release-pubkey 输出，base64）。App 内「下载并用 GBox 安装」用它校验签名；
#                   没设置时读 ../mac/build.local.env 里的 UPDATE_PUBKEY（和 release.sh 用同一套发布密钥）。
#                   为空时 App 不提供应用内下载，只能用 GBox 软件源
#   PUBLIC_BUILD=1  公开发布版：忽略 build.local.env 里的私人服务器地址（UPDATE_PUBKEY 只认环境变量）
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-device}"
if [ -f build.local.env ] && [ "${PUBLIC_BUILD:-}" != 1 ]; then . ./build.local.env; fi
BUNDLE_ID="${BUNDLE_ID:-io.github.hongyile.huijian}"
DEFAULT_SERVER="${DEFAULT_SERVER:-}"
UPDATE_PUBKEY="${UPDATE_PUBKEY:-}"
if [ -z "$UPDATE_PUBKEY" ] && [ "${PUBLIC_BUILD:-}" != 1 ] && [ -f ../mac/build.local.env ]; then
  UPDATE_PUBKEY=$(sed -n 's/^UPDATE_PUBKEY=//p' ../mac/build.local.env | tail -1 | tr -d "\"' ")
fi
VERSION="${VERSION:-$(cat VERSION)}"
# 构建号 = git 提交数 + 100：0.7.0 改名时仓库历史重新开始，旧仓库发到服务器的构建号到过 32，加偏移保证只增不减
BUILD="${BUILD:-$(( $(git rev-list --count HEAD 2>/dev/null || echo 1) + 100 ))}"
MIN_IOS=17.0
REFRESH_ID="io.github.hongyile.huijian.refresh"

case "$MODE" in
  device) SDK_NAME=iphoneos; TARGET=arm64-apple-ios${MIN_IOS}; PLATFORM=iPhoneOS; OUT=build/device ;;
  sim)    SDK_NAME=iphonesimulator; TARGET=arm64-apple-ios${MIN_IOS}-simulator; PLATFORM=iPhoneSimulator; OUT=build/sim ;;
  *) echo "用法：$0 [device|sim]"; exit 2 ;;
esac
SDK=$(xcrun --sdk $SDK_NAME --show-sdk-path)
SDK_VER=$(xcrun --sdk $SDK_NAME --show-sdk-version)
APP=$OUT/Huijian.app
rm -rf "$APP"; mkdir -p "$APP" build

# 图标：Resources/AppIcon.png（浅色）与 AppIcon-dark.png（深色模式）由 design/icon/make.py 生成
XC=$OUT/Assets.xcassets; rm -rf "$XC"; mkdir -p "$XC/AppIcon.appiconset"
cp Resources/AppIcon.png Resources/AppIcon-dark.png "$XC/AppIcon.appiconset/"
cat > "$XC/Contents.json" <<'JSON'
{"info":{"author":"xcode","version":1}}
JSON
cat > "$XC/AppIcon.appiconset/Contents.json" <<'JSON'
{"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"ios","size":"1024x1024"},{"appearances":[{"appearance":"luminosity","value":"dark"}],"filename":"AppIcon-dark.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
JSON
xcrun actool "$XC" --compile "$APP" --platform $SDK_NAME --minimum-deployment-target $MIN_IOS \
  --app-icon AppIcon --target-device iphone --output-partial-info-plist $OUT/icon-partial.plist \
  --output-format human-readable-text --notices --warnings > $OUT/actool.log 2>&1 || { cat $OUT/actool.log; exit 1; }

# 编译。模拟器版把 entitlements 嵌进二进制的 __entitlements 段（Xcode 也是这么做的），否则模拟器里用不了钥匙串；
# 真机版不带 entitlements，由 GBox 重签时按它的描述文件写入
LINK_ENT=()
if [ "$MODE" = sim ]; then
  ENT=$OUT/sim.entitlements
  cat > "$ENT" <<ENTXML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>application-identifier</key><string>SIMULATOR.${BUNDLE_ID}</string>
 <key>keychain-access-groups</key><array><string>SIMULATOR.${BUNDLE_ID}</string></array>
</dict></plist>
ENTXML
  LINK_ENT=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$ENT")
fi
# 共用核心（Rust：端到端加密、Markdown 解析）编译成静态库，链接进 App；-dead_strip 去掉用不到的部分
CORE_T=$([ "$SDK_NAME" = iphonesimulator ] && echo ios-sim || echo ios)
../core/build.sh $CORE_T > /dev/null
CORE_DIR=../core/target/$([ "$CORE_T" = ios-sim ] && echo aarch64-apple-ios-sim || echo aarch64-apple-ios)/release
CORE=(-I ../core/include -L "$CORE_DIR" -Xlinker -dead_strip)
# -wmo：全模块优化（跨文件内联、去虚化）
xcrun -sdk $SDK_NAME swiftc -parse-as-library -target "$TARGET" -sdk "$SDK" -swift-version 5 -O -wmo "${CORE[@]}" \
  -module-name Huijian Sources/*.swift -o "$APP/Huijian" ${LINK_ENT[@]+"${LINK_ENT[@]}"}

# Info.plist。ATS 只写 NSAllowsArbitraryLoads：同时写 NSAllowsLocalNetworking 时系统会忽略前者，
# http://域名（DDNS、内网域名）就被拦（-1022）
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
 <key>CFBundleName</key><string>Huijian</string>
 <key>CFBundleDisplayName</key><string>回笺</string>
 <key>CFBundleExecutable</key><string>Huijian</string>
 <key>CFBundlePackageType</key><string>APPL</string>
 <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
 <key>CFBundleShortVersionString</key><string>${VERSION}</string>
 <key>CFBundleVersion</key><string>${BUILD}</string>
 <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
 <key>CFBundleSupportedPlatforms</key><array><string>${PLATFORM}</string></array>
 <key>MinimumOSVersion</key><string>${MIN_IOS}</string>
 <key>DTPlatformName</key><string>${SDK_NAME}</string>
 <key>DTPlatformVersion</key><string>${SDK_VER}</string>
 <key>DTSDKName</key><string>${SDK_NAME}${SDK_VER}</string>
 <key>LSRequiresIPhoneOS</key><true/>
 <key>UIDeviceFamily</key><array><integer>1</integer></array>
 <key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
 <key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string></array>
 <key>UILaunchScreen</key><dict/>
 <key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
 <key>ITSAppUsesNonExemptEncryption</key><false/>
 <key>HuijianDefaultServer</key><string>${DEFAULT_SERVER}</string>
 <key>HuijianUpdatePublicKey</key><string>${UPDATE_PUBKEY}</string>
 <key>UIBackgroundModes</key><array><string>fetch</string></array>
 <key>BGTaskSchedulerPermittedIdentifiers</key><array><string>${REFRESH_ID}</string></array>
 <key>NSAppTransportSecurity</key><dict>
   <key>NSAllowsArbitraryLoads</key><true/>
 </dict>
 <key>NSLocalNetworkUsageDescription</key><string>连接局域网里的回笺服务器（例如 http://192.168.1.10:8790）</string>
 <key>CFBundleURLTypes</key><array><dict>
   <key>CFBundleURLName</key><string>${BUNDLE_ID}</string>
   <key>CFBundleURLSchemes</key><array><string>huijian</string><string>hongyan</string></array>
 </dict></array>
</dict></plist>
PLIST
# 合并 actool 生成的图标声明（CFBundleIcons）
/usr/libexec/PlistBuddy -c "Merge $OUT/icon-partial.plist" "$APP/Info.plist" > /dev/null
plutil -lint "$APP/Info.plist" > /dev/null

if [ "$MODE" = sim ]; then
  codesign --force -s - --identifier "$BUNDLE_ID" "$APP"
  echo "构建完成：${APP}  ${VERSION} (build ${BUILD})  模拟器${UPDATE_PUBKEY:+  带更新公钥}"
  exit 0
fi

# 真机：ad-hoc 签名（只为让包结构完整，GBox 安装时会用自己的证书重签）→ Payload/Huijian.app → .ipa
codesign --force -s - --identifier "$BUNDLE_ID" "$APP"
IPA="build/Huijian-${VERSION}-${BUILD}.ipa"
STAGE=$OUT/ipa; rm -rf "$STAGE"; mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
rm -f "$IPA"
(cd "$STAGE" && /usr/bin/zip -qry -X "../../../$IPA" Payload)
echo "构建完成：$IPA  ${VERSION} (build ${BUILD})  ${BUNDLE_ID}${DEFAULT_SERVER:+  默认服务器 ${DEFAULT_SERVER}}${UPDATE_PUBKEY:+  带更新公钥}"
