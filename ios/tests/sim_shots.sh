#!/usr/bin/env bash
# 视觉验收：本地独立 hub + 演示数据，在 iOS 模拟器上以演示模式启动，截取
# 登录页、消息列表（浅 / 深）、详情（Markdown / 图片附件 / 回笺 Markdown 演示的表格、提示框、进度条、正文图片），
# 设置页 Bark 卡片、管理页（Pushkey、账户与设备、频道）、开放注册时的登录页，截图放 screenshots/。
# 用法：tests/sim_shots.sh            环境变量 SIM 指定模拟器名称（默认 iPhone 16 Pro）
set -u
cd "$(dirname "$0")/.."
. tests/update_key.sh
# 公开构建（不带私人配置）；内置公钥用测试密钥，「有新版本」截图里能看到「下载并用 GBox 安装」
PUBLIC_BUILD=1 UPDATE_PUBKEY=$TEST_UPDATE_PUB ./build.sh sim > /dev/null || { echo "❌ 构建失败"; exit 1; }
. tests/hub.sh
SIM="${SIM:-iPhone 16 Pro}"
UDID=$(xcrun simctl list devices available -j | python3 -c "
import sys,json
for rt,ds in json.load(sys.stdin)['devices'].items():
    for d in ds:
        if d['name']=='$SIM' and 'iOS' in rt: print(d['udid']); sys.exit()")
[ -n "$UDID" ] || { echo "❌ 找不到模拟器 $SIM"; exit 1; }
xcrun simctl boot "$UDID" 2>/dev/null; xcrun simctl bootstatus "$UDID" -b > /dev/null
xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
BID=io.github.hongyile.huijian
S=screenshots; mkdir -p $S; rm -f $S/*.png
xcrun simctl terminate "$UDID" $BID 2>/dev/null
xcrun simctl uninstall "$UDID" $BID 2>/dev/null
xcrun simctl install "$UDID" build/sim/Huijian.app
DEMO_ARGS=(-demoServer $PUB -demoUser $DEMO_USER -demoPass $DEMO_PASS)
shot(){ # 名称 外观 等待秒数 启动参数...
  local name=$1 look=$2 wait=$3; shift 3
  xcrun simctl ui "$UDID" appearance $look
  xcrun simctl launch --terminate-running-process "$UDID" $BID "$@" > /dev/null
  sleep $wait
  xcrun simctl io "$UDID" screenshot --type=png $S/$name.png > /dev/null 2>&1 && echo "✅ $S/$name.png" || echo "❌ $name"
}
shot login light 3
# 服务端开放注册时，登录页多一个「注册」
curl -s -b $J -o /dev/null -H "Origin: $ADM" -d on=1 $ADM/accounts/register
shot login-register light 5 -demoLoginServer $PUB -demoLoginMode register
shot home-light light 8 "${DEMO_ARGS[@]}" -demoReset YES -demoUnread 5
shot detail-markdown light 6 "${DEMO_ARGS[@]}" -demoOpen "exp42 完成"
shot detail-image light 7 "${DEMO_ARGS[@]}" -demoOpen "阶段评估"
shot settings-bark light 6 "${DEMO_ARGS[@]}" -demoPage settings -demoSetBark https://api.day.app/DemoKey8xZ2 \
  -demoBarkKey Yq3vN8pL2xR7tK5mW9cH4bF6jD1sG0aZ -demoBarkIV Pe7Rk2Lm9Qx4Tz6V
shot settings-connection light 6 "${DEMO_ARGS[@]}" -demoPage settings -demoScroll connection
shot home-dark dark 5 "${DEMO_ARGS[@]}" -demoUnread 5
shot detail-dark dark 6 "${DEMO_ARGS[@]}" -demoOpen "exp42 完成"
# 回笺 Markdown（服务端 doc）：-demoScrollBlock 滚到某种块第一次出现的位置
MD=("${DEMO_ARGS[@]}" -demoOpen "exp43 训练报告")
shot detail-md-blocks light 7 "${MD[@]}" -demoScrollBlock progress
shot detail-md-image light 8 "${MD[@]}" -demoScrollBlock image
shot detail-md-more light 7 "${MD[@]}" -demoScrollBlock rule
shot detail-md-blocks-dark dark 7 "${MD[@]}" -demoScrollBlock progress
shot detail-md-image-dark dark 8 "${MD[@]}" -demoScrollBlock image
# 管理：设置页入口、Pushkey、账户与设备（自动生成一个配对码）、频道
shot settings-manage light 6 "${DEMO_ARGS[@]}" -demoPage settings -demoScroll manage
shot manage-keys light 6 "${DEMO_ARGS[@]}" -demoPage keys
shot manage-account light 7 "${DEMO_ARGS[@]}" -demoPage account -demoPairCode YES
shot manage-channels light 6 "${DEMO_ARGS[@]}" -demoPage channels
shot manage-keys-dark dark 6 "${DEMO_ARGS[@]}" -demoPage keys
# 发布一个假的 iOS 新版本到测试 hub，截「有新版本」的提示（首页横幅、设置页关于）
head -c 4096 /dev/urandom > $T/fake.ipa
NEXT=$(( $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' build/sim/Huijian.app/Info.plist) + 1 ))
# 演示的「新版本」= 当前版本的修订号 + 1
NEXT_VER=$(awk -F. '{printf "%d.%d.%d", $1, $2, $3 + 1}' VERSION)
HUIJIAN_ADMIN_URL=$ADM HUIJIAN_ADMIN_TOKEN=$(cat $DEMO/data/admin.token) $B release -key "$TEST_UPDATE_KEY" -platform ios \
  -version $NEXT_VER -build $NEXT -notes $'- 改进后台同步\n- 修复若干问题' $T/fake.ipa > $T/release.log 2>&1 \
  || { echo "❌ 发布测试版本失败"; cat $T/release.log; }
shot home-update light 6 "${DEMO_ARGS[@]}" -demoUnread 3
shot settings-update light 6 "${DEMO_ARGS[@]}" -demoPage settings -demoScroll about
# 深链（模拟点 Bark 通知）：App 没在运行、这条消息还没同步到本机 → 冷启动、补拉、直接打开详情
xcrun simctl terminate "$UDID" $BID 2>/dev/null
xcrun simctl ui "$UDID" appearance light
NEWID=$(curl -s $PUB/message/push -d pushkey=$K_MON -d priority=5 -d topic=infra --data-urlencode "text=gpu-node-2 掉线" \
  --data-urlencode $'desp=最后一次心跳：**3 分钟前**\n\n- 主机：gpu-node-2\n- 影响：exp43 训练暂停' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["content"]["result"][0])')
xcrun simctl launch "$UDID" $BID -demoOpenURL "huijian://message/$NEWID" > /dev/null
sleep 7
xcrun simctl io "$UDID" screenshot --type=png $S/deeplink.png > /dev/null 2>&1 && echo "✅ $S/deeplink.png（huijian://message/${NEWID}）"
xcrun simctl status_bar "$UDID" clear
xcrun simctl terminate "$UDID" $BID 2>/dev/null
