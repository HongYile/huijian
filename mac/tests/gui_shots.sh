#!/usr/bin/env bash
# 视觉验收：独立 hub + 丰富演示数据，分别以 --demo 模式截取 主窗口(浅/深)、菜单栏面板、设置各页、账户窗口、完成账号设置页、配对窗口，
# 以及回笺 Markdown 演示消息（tests/markdown_demo.md：表格、提示框、进度条、正文里的附件图片，浅 / 深）。
# 用法：tests/gui_shots.sh [只截某几个，例如 main-light panel]
# 只有 update-* 三张显示演示用的「有新版本」，其余截图和刚装好最新版时一样，不出现更新提示
#
# 0.9.0：账号只能注册产生（注册即开启加密），演示数据照 tests/selftest.sh 的方式准备：
#   invite new 生成邀请码 → register 注册演示账号拿到 token → 用账号 token 建 pushkey、生成配对码 → 配对出演示设备。
#   演示消息以加密为主（和 iOS 一致）：16 条里 14 条用加密发送密钥（<pushkey>.e2e.<公钥>）在本机加密后发（🔒），
#   只有「今日采集完成」（crawler）和「nightly backup ok · 2.1 GB」（infra）用普通 pushkey 发（服务器代加密，标「明文发送」）。
# 隔离：演示 App 单独构建（Bundle ID …huijian.shots），--demo 模式只用独立的偏好域和进程内存里的钥匙串替身（见 Sources/DemoMode.swift）；
#   命令行 huijian push 的 HOME 指到演示目录，不碰本机 ~/.huijian 里的发送队列。任何一步准备失败都立即退出，不启动 App。
# 焦点：演示 App 默认不激活（不抢键盘焦点），窗口放在浮动层，按窗口 id 截图；只有 channel-menu 要模拟右键，需要把回笺切到前台。
set -u
cd "$(dirname "$0")/.."
fail(){ echo "❌ $*"; exit 1; }
echo "=================================================================="
echo "  ⚠️  截图期间请不要打字、不要点击屏幕：会弹出多个回笺演示窗口"
echo "     （channel-menu 一张会把回笺切到前台并模拟右键）"
echo "=================================================================="
sleep 3
if [ ! -x ../server/bin/huijian ] || [ -n "$(find ../server -name '*.go' -newer ../server/bin/huijian | head -1)" ]; then
  (cd ../server && GOTOOLCHAIN=local go build -o bin/huijian .) || fail "编译服务端失败"
fi
# 公开构建，不带 build.local.env 里的私人服务器配置；构建号由 build.sh 计算（git 提交数 + 100，和发版一致）。
# 演示构建（DEMO_ONLY=1）：单独的 Bundle ID，Info.plist 带 HuijianDemoOnly，只能带 --demo 启动（不带就退出，
# 不会从启动台、访达或 huijian:// 链接被当成正式版打开）。放在 build.noindex/shots（不进 Spotlight），脚本结束时注销并删除。
SHOT_ID=io.github.hongyile.huijian.shots
SHOT_APP=$PWD/build.noindex/shots/Huijian.app
APP_PID=""; HUB=""; DEMO=/tmp/huijian-gui; T=test-run-gui.noindex
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
cleanup(){
  [ -n "$APP_PID" ] && kill $APP_PID 2>/dev/null
  [ -n "$HUB" ] && kill $HUB 2>/dev/null
  rm -f $T/cli.token
  # 演示构建从 LaunchServices 注销后删除，huijian:// 链接只指向正式安装的回笺
  [ -d "$SHOT_APP" ] && { $LSR -u "$SHOT_APP" 2>/dev/null; rm -rf "$SHOT_APP"; }
  # 演示数据（hub 数据库、admin token、各演示 App 的数据）用完即删
  rm -rf "$DEMO"
}
trap cleanup EXIT
DEMO_ONLY=1 PUBLIC_BUILD=1 BUNDLE_ID=$SHOT_ID OUT_DIR=build.noindex/shots ./build.sh > /dev/null || fail "构建失败"
APP_BIN=$SHOT_APP/Contents/MacOS/Huijian
PL=$SHOT_APP/Contents/Info.plist
SHOT_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PL")
GOT_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PL")
[ "$GOT_ID" = "$SHOT_ID" ] || fail "演示构建的 Bundle ID 不对（$GOT_ID），不启动"
[ "$(/usr/libexec/PlistBuddy -c 'Print :HuijianDemoOnly' "$PL" 2>/dev/null)" = true ] || fail "演示构建没有 HuijianDemoOnly 标记，不启动"
echo "截图用的构建：$(cat VERSION) (build $SHOT_BUILD)"
F=test-run-gui-files; S=screenshots; rm -rf test-run-gui
rm -rf $T; mkdir -p $T $S
# 演示数据、日志、token 只给本用户看
umask 077
# 附件素材（每次重新生成，不依赖之前留下的目录）
rm -rf $F; mkdir -p $F; python3 ../server/tests/make_fixtures.py $F || fail "生成附件素材失败"
{ cp $F/loss.png $F/confusion.png && cp $F/report.pdf $F/周报.docx && head -c 48000 /dev/urandom > $F/metrics.xlsx \
  && head -c 3200000 /dev/urandom > $F/ckpt-exp42.zip && seq 1 4000 | sed 's/^/step /' > $F/train.log; } || fail "准备附件素材失败"
# 演示数据放在中性路径下（截图里不能出现本机用户目录）
rm -rf $DEMO; mkdir -p $DEMO/data $DEMO/nas/files $DEMO/nas/backup $DEMO/home || fail "建演示目录失败"
PUB=http://127.0.0.1:28790; B=../server/bin/huijian
TZ=UTC HUIJIAN_DATA=$DEMO/data HUIJIAN_FILES=$DEMO/nas/files HUIJIAN_BACKUP_DIR=$DEMO/nas/backup HUIJIAN_PUBLIC_ADDR=127.0.0.1:28790 HUIJIAN_ADMIN_ADDR=127.0.0.1:28791 $B hub > $T/hub.log 2>&1 &
HUB=$!
for i in $(seq 1 30); do curl -sf $PUB/healthz >/dev/null && break; sleep 0.2; done
curl -sf $PUB/healthz >/dev/null || fail "演示 hub 没有启动：$(tail -3 $T/hub.log)"

# ---------- 演示账号 ----------
INV=$(HUIJIAN_DATA=$DEMO/data HUIJIAN_ADMIN_ADDR=127.0.0.1:28791 $B invite new -n 1 -uses 1 -note "gui shots" 2>/dev/null | head -1)
[ -n "$INV" ] || fail "生成邀请码失败"
# 演示账号密码：随机生成，不 export，只在启动演示 App 的那一行作为环境变量传入（配对码登录的设备用它解锁加密；
# 第一次启动时还用它设好恢复码，HUIJIAN_DEMO_RECOVERY=1，截图里不出现「还没有设置恢复码」的建议）
DEMO_PW="Demo#Shots-$RANDOM-$RANDOM-pw"
printf '%s\n' "$DEMO_PW" | HOME=$DEMO/home $B register -u $PUB -invite "$INV" -platform cli -name "gpu-node-1" \
  -token-out $T/cli.token "me" >/dev/null 2>$T/register.err || fail "注册演示账号失败：$(cat $T/register.err)"
CT=$(cat $T/cli.token 2>/dev/null)
[ -n "$CT" ] || fail "注册后没有拿到 token"
# token 不放进 curl 的命令行参数（ps 能看到）：写进只有本用户可读的请求头文件，用 -H @文件 读
AUTHF=$DEMO/auth.header; printf 'Authorization: Bearer %s\n' "$CT" > $AUTHF || fail "写请求头文件失败"
# JSON 先放变量（bash 3.2 会把 "$(… -d "{…,…}" …)" 里的逗号做花括号展开）
newkey(){
  local body; body=$(python3 -c 'import json,sys;print(json.dumps({"name":sys.argv[1]},ensure_ascii=False))' "$1")
  curl -sf -X POST -H @$AUTHF -H 'Content-Type: application/json' -d "$body" $PUB/v1/keys \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["key"])' 2>/dev/null
}
K_TRAIN=$(newkey "训练脚本"); K_MON=$(newkey "服务器监控"); K_REP=$(newkey "周报机器人"); K_JOB=$(newkey "数据采集")
[ -n "$K_TRAIN" ] && [ -n "$K_MON" ] && [ -n "$K_REP" ] && [ -n "$K_JOB" ] || fail "新建 pushkey 失败"
# 加密发送密钥 = pushkey + ".e2e." + 账号当前公钥（客户端 Pushkey 页复制的就是这个）
ACCPUB=$(curl -sf -H @$AUTHF $PUB/v1/e2e | python3 -c '
import sys,json
d=json.load(sys.stdin)
ks=[k["pub"] for k in d.get("keys") or [] if k.get("active")]
print(ks[-1] if d.get("enabled") and ks else "")' 2>/dev/null)
[ -n "$ACCPUB" ] || fail "取不到账号公钥（账号没有开启加密？）"
E_TRAIN="$K_TRAIN.e2e.$ACCPUB"; E_MON="$K_MON.e2e.$ACCPUB"; E_REP="$K_REP.e2e.$ACCPUB"; E_JOB="$K_JOB.e2e.$ACCPUB"
CODE=$(curl -sf -X POST -H @$AUTHF $PUB/v1/pair-codes | python3 -c 'import sys,json;print(json.load(sys.stdin)["code"])' 2>/dev/null)
[ -n "$CODE" ] || fail "生成配对码失败"
PAIRBODY=$(python3 -c 'import json,sys;print(json.dumps({"code":sys.argv[1],"name":"我的 MacBook","platform":"macos"},ensure_ascii=False))' "$CODE")
DT=$(curl -sf -X POST $PUB/v1/pair -H 'Content-Type: application/json' -d "$PAIRBODY" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])' 2>/dev/null)
[ -n "$DT" ] || fail "用配对码配对演示设备失败（没有设备 token）"

# ---------- 演示消息 ----------
# p 发一条，失败立即退出；pid 发一条并输出消息 id。HOME 指到演示目录：不碰本机 ~/.huijian 的发送队列
p(){ HOME=$DEMO/home $B push -u $PUB "$@" >/dev/null 2>>$T/push.err || fail "发送演示消息失败：$(tail -1 $T/push.err)"; }
pid(){ HOME=$DEMO/home $B push -u $PUB "$@" 2>>$T/push.err | sed -n 's/^已发送，消息 id: *//p'; }
# 三条一个多月前的（自动归档，「归档」截图里能看到）。E_* 是加密发送密钥（本机加密），K_* 是普通 pushkey（明文发送），
# 普通 pushkey 只用在「今日采集完成」和「nightly backup ok · 2.1 GB」两条
p -k $E_REP -p 3 -topic report -d "本周实验周报已生成" "周报已生成（10/06–10/12）"
p -k $E_JOB -p 3 -topic crawler -d "新增 1,804 · 更新 622 · 失败 41" "10 月采集汇总 68,402 条"
p -k $E_MON -p 2 -topic infra "nightly backup ok · 1.9 GB → NAS"
p -k $E_TRAIN -p 1 -topic train -thread exp42 "data loader ready: 1.28M images"
p -k $E_TRAIN -p 4 -topic train -thread exp42 -d $'- 模型：**ResNet-50**\n- 学习率：`3e-4`，batch 256\n- 主机：gpu-node-1 / 单卡' "exp42 训练开始"
p -k $E_TRAIN -p 2 -topic train -thread exp42 -d "train_loss 0.412 · val_loss 0.455 · 剩余约 3.1 小时" "epoch 37/100"
p -k $E_TRAIN -p 3 -topic train -thread exp42 -d $'阶段评估：top-1 **91.2%**，混淆矩阵见附件。' -f $F/confusion.png -f $F/metrics.xlsx "exp42 阶段评估 @ epoch 50"
p -k $E_TRAIN -p 0 -topic train -thread exp42 "debug: grad norm 1.83"
p -k $E_MON -p 5 -topic infra -d $'`/srv/data` 所在分区占用 **95%**（438 GB / 460 GB）。\n\n> 建议清理 `~/ckpt` 下的旧 checkpoint，或扩容数据盘。' "gpu-node-1 磁盘使用率 95%"
p -k $E_REP -p 3 -topic report -d $'本周实验周报已生成：\n\n1. exp42 完成，val_loss 0.198\n2. exp43 进行中\n3. 下周：消融实验' -f "$F/周报.docx" -f $F/metrics.xlsx "周报已生成（11/10–11/16）"
p -k $K_MON -p 2 -topic infra "nightly backup ok · 2.1 GB → NAS"
p -k $E_TRAIN -p 3 -topic train -thread exp43 -d "lr warmup 完成，进入余弦退火" "exp43 epoch 5/60"
p -k $K_JOB -p 3 -topic crawler -d "新增 128 · 更新 57 · 失败 3" "今日采集完成 2,315 条"
# 「exp42 完成」的消息 id 从发送结果里取（0.9.0 服务端存的是密文，不能再按标题查库）
E42=$(pid -k $E_TRAIN -p 4 -topic train -thread exp42 -d $'## 结果\n- best val_loss **0.198** @ epoch 87\n- top-1 acc **93.4%**，比 baseline 高 1.7 个点\n- 训练用时 6.2 小时\n\n加载最佳权重：\n\n```python\nmodel.load_state_dict(torch.load("best.pt"))\nmodel.eval()\n```\n\n> 附件里有曲线、评估报告和 checkpoint。' \
  -f $F/loss.png -f $F/report.pdf -f $F/ckpt-exp42.zip -f $F/train.log "exp42 完成")
case "$E42" in ''|*[!0-9]*) fail "发送「exp42 完成」失败：$(tail -1 $T/push.err)";; esac
# 覆盖全部回笺 Markdown 语法的演示消息：正文里用 attachment: 引用图片和 PDF，huijian://message/<id> 指向上面的「exp42 完成」
p -k $E_TRAIN -p 3 -topic train -thread exp43 -d "$(sed "s/E42_ID/$E42/" tests/markdown_demo.md)" -f $F/loss.png -f $F/report.pdf "exp43 训练报告"
# 把时间铺开（只改测试库的时间戳）：分钟前
python3 - $DEMO/data/huijian.db <<'PY' || fail "调整演示消息时间失败"
import sqlite3,sys,time
c=sqlite3.connect(sys.argv[1]); now=int(time.time())
ago=[400,395,250,180,170,95,75,52,30,12,3,1]
ids=[r[0] for r in c.execute("select id from messages order by id")]
assert len(ids)==15, "演示消息应有 15 条，实际 %d" % len(ids)
for i,d in zip(ids[:3],[47,41,35]): c.execute("update messages set created_at=? where id=?",(now-d*86400,i))
for i,a in zip(ids[3:],ago): c.execute("update messages set created_at=? where id=?",(now-a*60,i))
c.commit()
PY
# 频道设置：train 改名「训练」并置顶，infra 静音，debug 隐藏（侧栏底部「已隐藏」）
p -k $E_TRAIN -p 1 -topic debug "debug: dataloader worker 4 restarted"
chan(){ curl -sf -o /dev/null -X PATCH -H "Authorization: Bearer $DT" -H 'Content-Type: application/json' -d "$1" $PUB/v1/channels || fail "频道设置失败：$1"; }
chan '{"topic":"train","alias":"训练","pinned":true}'; chan '{"topic":"infra","muted":true}'; chan '{"topic":"debug","hidden":true}'
echo "演示数据已就绪：pushkey 4 个、消息 16 条（加密发送 14 条、明文发送 2 条）"

# ---------- 截图 ----------
FAILS=0
bad(){ echo "❌ $*"; FAILS=$((FAILS + 1)); }
# launch 名称 环境变量...：启动演示 App（设备 token 为空时绝不启动）
launch(){
  local name=$1; shift
  [ -n "$DT" ] || fail "没有演示设备 token，不启动 App"
  env HUIJIAN_DEMO_PASSWORD="$DEMO_PW" HUIJIAN_DEMO_RECOVERY=1 "$@" "$APP_BIN" --demo "$PUB" "$DT" "$DEMO/app-$name" > $T/app-$name.log 2>&1 &
  APP_PID=$!
}
stop(){ [ -n "$APP_PID" ] && { kill $APP_PID 2>/dev/null; wait $APP_PID 2>/dev/null; }; APP_PID=""; }
alive(){ kill -0 $APP_PID 2>/dev/null || { bad "$1：演示 App 已退出（$(tail -2 $T/app-$1.log | tr '\n' ' ')）"; APP_PID=""; return 1; }; }
# 窗口 id（演示窗口在普通层或浮动层）
winid(){ xcrun swift tests/winid.swift $APP_PID "$@" 2>/dev/null | head -1; }
shot(){ # 名称 等待秒数 环境变量...（等待时间多 2 秒：配对码登录的演示设备要先用密码解锁加密）
  local name=$1 wait=$2; shift 2
  launch $name HUIJIAN_DEMO_PREFETCH="loss.png,report.pdf,confusion.png,周报.docx" HUIJIAN_DEMO_SELECT="exp42 完成" \
    HUIJIAN_DEMO_READ_OLDEST=9 HUIJIAN_DEMO_STAR="周报已生成" HUIJIAN_DEMO_PROGRESS=1 "$@"
  sleep $((wait + 2))
  alive $name || return 0
  local ok="" W=0 WID=""
  for try in 1 2 3 4 5; do
    WID=$(winid)
    if [ -n "$WID" ]; then
      screencapture -x -o -l $WID $S/$name.png
      W=$(sips -g pixelWidth $S/$name.png 2>/dev/null | tail -1 | awk '{print $2}')
      if [ "${W:-0}" -ge 500 ]; then ok=1; break; fi
    fi
    sleep 2
  done
  if [ -n "$ok" ]; then echo "✅ $S/$name.png (${W}px)"; else bad "$name 截图失败（窗口 ${WID:-没找到}，宽 ${W:-0}）"; fi
  stop
}
ONLY="${*:-}"
[ -z "$ONLY" ] || echo "只截：$ONLY"
inc(){ [ -z "$ONLY" ] || [[ " $ONLY " == *" $1 "* ]]; }
inc main-light && shot main-light 8 HUIJIAN_DEMO_LIGHT=1
inc main-dark && shot main-dark 8 HUIJIAN_DEMO_DARK=1
# 回笺 Markdown：选中演示消息，HUIJIAN_DEMO_SCROLL_BLOCK 滚到某种块第一次出现的位置
inc markdown-light && shot markdown-light 9 HUIJIAN_DEMO_LIGHT=1 HUIJIAN_DEMO_SELECT="exp43 训练报告" HUIJIAN_DEMO_SCROLL_BLOCK=progress
inc markdown-dark && shot markdown-dark 9 HUIJIAN_DEMO_DARK=1 HUIJIAN_DEMO_SELECT="exp43 训练报告" HUIJIAN_DEMO_SCROLL_BLOCK=progress
inc markdown-image && shot markdown-image 9 HUIJIAN_DEMO_LIGHT=1 HUIJIAN_DEMO_SELECT="exp43 训练报告" HUIJIAN_DEMO_SCROLL_BLOCK=image
inc markdown-image-dark && shot markdown-image-dark 9 HUIJIAN_DEMO_DARK=1 HUIJIAN_DEMO_SELECT="exp43 训练报告" HUIJIAN_DEMO_SCROLL_BLOCK=image
inc panel && shot panel 6 HUIJIAN_DEMO_SHOW=panel HUIJIAN_DEMO_LIGHT=1
inc panel-dark && shot panel-dark 6 HUIJIAN_DEMO_SHOW=panel HUIJIAN_DEMO_DARK=1
inc settings-general && shot settings-general 5 HUIJIAN_DEMO_SHOW=settings HUIJIAN_DEMO_TAB=general HUIJIAN_DEMO_LIGHT=1
inc settings-notify && shot settings-notify 5 HUIJIAN_DEMO_SHOW=settings HUIJIAN_DEMO_TAB=notify HUIJIAN_DEMO_LIGHT=1
inc settings-keys && shot settings-keys 6 HUIJIAN_DEMO_SHOW=settings HUIJIAN_DEMO_TAB=keys HUIJIAN_DEMO_LIGHT=1
inc settings-server && shot settings-server 6 HUIJIAN_DEMO_SHOW=settings HUIJIAN_DEMO_TAB=server HUIJIAN_DEMO_LIGHT=1
inc settings-network && shot settings-network 5 HUIJIAN_DEMO_SHOW=settings HUIJIAN_DEMO_TAB=network HUIJIAN_DEMO_LIGHT=1
inc archive && shot archive 8 HUIJIAN_DEMO_FILTER=archived HUIJIAN_DEMO_LIGHT=1
inc cleanup && shot cleanup 8 HUIJIAN_DEMO_CLEANUP=crawler HUIJIAN_DEMO_LIGHT=1
inc account && shot account 6 HUIJIAN_DEMO_SHOW=account HUIJIAN_DEMO_LIGHT=1
inc setup && shot setup 4 HUIJIAN_DEMO_SHOW=setup HUIJIAN_DEMO_LIGHT=1
for ph in downloading verifying installing; do
  inc update-$ph && shot update-$ph 6 HUIJIAN_DEMO_SHOW=settings HUIJIAN_DEMO_TAB=general HUIJIAN_DEMO_LIGHT=1 HUIJIAN_DEMO_UPDATE=1 HUIJIAN_DEMO_UPDATE_PHASE=$ph
done
if inc channel-rename; then
  # 改名弹窗是挂在主窗口上的独立小窗口，按窗口 id 截不到它，只能按区域截：主窗口在浮动层，区域里只有回笺的窗口
  launch channel-rename HUIJIAN_DEMO_RENAME=train HUIJIAN_DEMO_LIGHT=1 HUIJIAN_DEMO_SELECT="exp42 完成" HUIJIAN_DEMO_READ_OLDEST=9
  sleep 11
  if alive channel-rename; then
    RB=$(winid bounds)
    if [ -n "$RB" ] && screencapture -x -R "$RB" $S/channel-rename.png; then echo "✅ $S/channel-rename.png"; else bad "channel-rename 截图失败（窗口 ${RB:-没找到}）"; fi
  fi
  stop
fi
if inc channel-menu; then
  # 在「训练」频道上右键，截出频道菜单：要模拟右键，只有这一张把回笺切到前台（HUIJIAN_DEMO_ACTIVATE=1）
  # 需要辅助功能权限；没有权限时截图里没有菜单，脚本会提示
  echo "⚠️  channel-menu：3 秒后把回笺切到前台并模拟右键，请不要打字"; sleep 3
  launch channel-menu HUIJIAN_DEMO_ACTIVATE=1 HUIJIAN_DEMO_LIGHT=1 HUIJIAN_DEMO_SELECT="exp42 完成" HUIJIAN_DEMO_READ_OLDEST=9
  sleep 10
  if alive channel-menu; then
    osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $APP_PID) to true" >/dev/null 2>&1; sleep 1
    RB=$(winid bounds)
    if [ -n "$RB" ]; then
      IFS=, read WX WY WW WH <<< "$RB"
      # 「训练」是频道下的第一项：距窗口左边约 60pt、顶部约 319pt（窗口宽 1180pt 时）
      xcrun swift tests/rightclick.swift $((WX + 60)) $((WY + 319)) 2>/dev/null; sleep 1.5
      screencapture -x -R "$WX,$WY,$((WW < 640 ? WW : 640)),$((WH))" $S/channel-menu.png && echo "✅ $S/channel-menu.png（请确认截图里有右键菜单）" || bad "channel-menu 截图失败"
    else
      bad "channel-menu：没找到窗口"
    fi
  fi
  stop
fi
if inc pair-used; then
  # 账户页生成配对码 → 用它配对一台「新 iPhone」→ 截图应显示「已被「新 iPhone」使用」
  launch pair-used HUIJIAN_DEMO_SHOW=account HUIJIAN_DEMO_LIGHT=1 HUIJIAN_DEMO_PAIRCODE=1
  PCODE=""
  for i in $(seq 1 40); do PCODE=$(grep -o 'DEMO_PAIRCODE=[0-9]*' $T/app-pair-used.log | tail -1 | cut -d= -f2); [ -n "$PCODE" ] && break; sleep 0.5; done
  if [ -n "$PCODE" ]; then
    NEWBODY=$(python3 -c 'import json,sys;print(json.dumps({"code":sys.argv[1],"name":"新 iPhone","platform":"ios"},ensure_ascii=False))' "$PCODE")
    if curl -sf -o /dev/null -H 'Content-Type: application/json' -d "$NEWBODY" $PUB/v1/pair; then
      sleep 5
      WID=$(winid)
      if [ -n "$WID" ] && screencapture -x -o -l $WID $S/pair-used.png; then echo "✅ $S/pair-used.png"; else bad "pair-used 截图失败（窗口 ${WID:-没找到}）"; fi
    else
      bad "pair-used：用演示配对码配对「新 iPhone」失败"
    fi
  else
    bad "pair-used：没拿到配对码（$(tail -2 $T/app-pair-used.log | tr '\n' ' ')）"
  fi
  stop
fi
inc pair && shot pair 4 HUIJIAN_DEMO_SHOW=pair HUIJIAN_DEMO_LIGHT=1
chmod -f 644 $S/*.png 2>/dev/null   # 截图是要公开的，不受上面 umask 077 影响
if [ $FAILS -gt 0 ]; then echo "❌ 共 $FAILS 张截图失败"; exit 1; fi
echo "✅ 截图全部完成"
