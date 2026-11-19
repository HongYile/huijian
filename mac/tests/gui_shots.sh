#!/usr/bin/env bash
# 视觉验收：独立 hub + 丰富演示数据，分别以 --demo 模式截取 主窗口(浅/深)、菜单栏面板、设置各页、账户窗口、完成账号设置页、配对窗口，
# 以及回笺 Markdown 演示消息（tests/markdown_demo.md：表格、提示框、进度条、正文里的附件图片，浅 / 深）。
# 用法：tests/gui_shots.sh [只截某几个，例如 main-light panel]
# 只有 update-* 三张显示演示用的「有新版本」，其余截图和刚装好最新版时一样，不出现更新提示
set -u
cd "$(dirname "$0")/.."
[ -x ../server/bin/huijian ] || (cd ../server && GOTOOLCHAIN=local go build -o bin/huijian .)
# 截图里的版本号要和发布出去的一致：VERSION 已提交时用它所在提交的构建号（发版时 build = 提交数），
# VERSION 还没提交（正在准备新版）时用 当前提交数 + 1。公开构建，不带 build.local.env 里的私人服务器配置；
# 输出到 build/shots，不覆盖开发用的 build/Huijian.app。
if git diff --quiet HEAD -- VERSION 2>/dev/null; then SHOT_BUILD=$(git rev-list --count "$(git log -1 --format=%H -- VERSION)")
else SHOT_BUILD=$(( $(git rev-list --count HEAD) + 1 )); fi
PUBLIC_BUILD=1 BUILD=$SHOT_BUILD OUT_DIR=build/shots ./build.sh > /dev/null || { echo "❌ 构建失败"; exit 1; }
echo "截图用的构建：$(cat VERSION) (build $SHOT_BUILD)"
T=test-run-gui.noindex; F=test-run-gui-files; S=screenshots; rm -rf test-run-gui
rm -rf $T; mkdir -p $T $S
# 附件素材（每次重新生成，不依赖之前留下的目录）
rm -rf $F; mkdir -p $F; python3 ../server/tests/make_fixtures.py $F
cp $F/loss.png $F/confusion.png; cp $F/report.pdf $F/周报.docx; head -c 48000 /dev/urandom > $F/metrics.xlsx
head -c 3200000 /dev/urandom > $F/ckpt-exp42.zip; seq 1 4000 | sed 's/^/step /' > $F/train.log
# 演示数据放在中性路径下：设置页会显示服务端的数据 / 附件 / 备份目录，截图里不能出现本机用户目录
DEMO=/tmp/huijian-gui; rm -rf $DEMO; mkdir -p $DEMO/data $DEMO/nas/files $DEMO/nas/backup
PUB=http://127.0.0.1:28790; ADM=http://127.0.0.1:28791; B=../server/bin/huijian
TZ=UTC HUIJIAN_DATA=$DEMO/data HUIJIAN_FILES=$DEMO/nas/files HUIJIAN_BACKUP_DIR=$DEMO/nas/backup HUIJIAN_PUBLIC_ADDR=127.0.0.1:28790 HUIJIAN_ADMIN_ADDR=127.0.0.1:28791 $B hub > $T/hub.log 2>&1 &
HUB=$!; APP_PID=""
trap 'kill $HUB 2>/dev/null; [ -n "$APP_PID" ] && kill $APP_PID 2>/dev/null' EXIT
for i in $(seq 1 30); do curl -sf $PUB/healthz >/dev/null && break; sleep 0.2; done
J=$T/cookies
curl -s -c $J -o /dev/null -d "token=$(cat $DEMO/data/admin.token)" $ADM/login
key(){ curl -s -b $J -o /dev/null -w '%{redirect_url}' -H "Origin: $ADM" --data-urlencode "name=$1" $ADM/pushkeys \
  | python3 -c "import sys,urllib.parse as u;print(u.parse_qs(u.urlparse(sys.stdin.read()).query)['key'][0])"; }
K_TRAIN=$(key "训练脚本"); K_MON=$(key "服务器监控"); K_REP=$(key "周报机器人"); K_JOB=$(key "数据采集")
CODE=$(curl -s -b $J -o /dev/null -w '%{redirect_url}' -H "Origin: $ADM" -d can_admin=on $ADM/pair | sed -E 's/.*code=([0-9]+).*/\1/')
DT=$(curl -s -X POST $PUB/v1/pair -H 'Content-Type: application/json' -d "{\"code\":\"$CODE\",\"name\":\"我的 MacBook\",\"platform\":\"macos\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
p(){ $B push -u $PUB "$@" >/dev/null; }
# 三条一个多月前的（自动归档，「归档」截图里能看到）
p -k $K_REP -p 3 -topic report -d "本周实验周报已生成" "周报已生成（10/06–10/12）"
p -k $K_JOB -p 3 -topic crawler -d "新增 1,804 · 更新 622 · 失败 41" "10 月采集汇总 68,402 条"
p -k $K_MON -p 2 -topic infra "nightly backup ok · 1.9 GB → NAS"
p -k $K_TRAIN -p 1 -topic train -thread exp42 "data loader ready: 1.28M images"
p -k $K_TRAIN -p 4 -topic train -thread exp42 -d $'- 模型：**ResNet-50**\n- 学习率：`3e-4`，batch 256\n- 主机：gpu-node-1 / 单卡' "exp42 训练开始"
p -k $K_TRAIN -p 2 -topic train -thread exp42 -d "train_loss 0.412 · val_loss 0.455 · 剩余约 3.1 小时" "epoch 37/100"
p -k $K_TRAIN -p 3 -topic train -thread exp42 -d $'阶段评估：top-1 **91.2%**，混淆矩阵见附件。' -f $F/confusion.png -f $F/metrics.xlsx "exp42 阶段评估 @ epoch 50"
p -k $K_TRAIN -p 0 -topic train -thread exp42 "debug: grad norm 1.83"
p -k $K_MON -p 5 -topic infra -d $'`/srv/data` 所在分区占用 **95%**（438 GB / 460 GB）。\n\n> 建议清理 `~/ckpt` 下的旧 checkpoint，或扩容数据盘。' "gpu-node-1 磁盘使用率 95%"
p -k $K_REP -p 3 -topic report -d $'本周实验周报已生成：\n\n1. exp42 完成，val_loss 0.198\n2. exp43 进行中\n3. 下周：消融实验' -f "$F/周报.docx" -f $F/metrics.xlsx "周报已生成（11/10–11/16）"
p -k $K_MON -p 2 -topic infra "nightly backup ok · 2.1 GB → NAS"
p -k $K_TRAIN -p 3 -topic train -thread exp43 -d "lr warmup 完成，进入余弦退火" "exp43 epoch 5/60"
p -k $K_JOB -p 3 -topic crawler -d "新增 128 · 更新 57 · 失败 3" "今日采集完成 2,315 条"
p -k $K_TRAIN -p 4 -topic train -thread exp42 -d $'## 结果\n- best val_loss **0.198** @ epoch 87\n- top-1 acc **93.4%**，比 baseline 高 1.7 个点\n- 训练用时 6.2 小时\n\n加载最佳权重：\n\n```python\nmodel.load_state_dict(torch.load("best.pt"))\nmodel.eval()\n```\n\n> 附件里有曲线、评估报告和 checkpoint。' \
  -f $F/loss.png -f $F/report.pdf -f $F/ckpt-exp42.zip -f $F/train.log "exp42 完成"
# 覆盖全部回笺 Markdown 语法的演示消息（服务端 0.6.0 解析成 doc）：正文里用 attachment: 引用图片和 PDF，
# huijian://message/<id> 指向上面的「exp42 完成」
E42=$(python3 -c "import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute(\"select id from messages where text='exp42 完成'\").fetchone()[0])" $DEMO/data/huijian.db)
p -k $K_TRAIN -p 3 -topic train -thread exp43 -d "$(sed "s/E42_ID/$E42/" tests/markdown_demo.md)" -f $F/loss.png -f $F/report.pdf "exp43 训练报告"
# 把时间铺开（只改测试库）：分钟前
python3 - $DEMO/data/huijian.db <<'PY'
import sqlite3,sys,time
c=sqlite3.connect(sys.argv[1]); now=int(time.time())
ago=[400,395,250,180,170,95,75,52,30,12,3,1]
ids=[r[0] for r in c.execute("select id from messages order by id")]
for i,d in zip(ids[:3],[47,41,35]): c.execute("update messages set created_at=? where id=?",(now-d*86400,i))
for i,a in zip(ids[3:],ago): c.execute("update messages set created_at=? where id=?",(now-a*60,i))
c.commit()
PY
# 账号设好用户名密码，再跑一次备份（设置 → 账户 / 服务器 页有内容可看）
curl -s -b $J -o /dev/null -H "Origin: $ADM" --data-urlencode "username=me" -d password=demo-pass-1 $ADM/accounts/1/credentials
TZ=UTC HUIJIAN_DATA=$DEMO/data HUIJIAN_FILES=$DEMO/nas/files HUIJIAN_BACKUP_DIR=$DEMO/nas/backup $B backup >/dev/null 2>&1
# 频道设置：train 改名「训练」并置顶，infra 静音，debug 隐藏（侧栏底部「已隐藏」）
p -k $K_TRAIN -p 1 -topic debug "debug: dataloader worker 4 restarted"
chan(){ curl -s -o /dev/null -X PATCH -H "Authorization: Bearer $DT" -H 'Content-Type: application/json' -d "$1" $PUB/v1/channels; }
chan '{"topic":"train","alias":"训练","pinned":true}'; chan '{"topic":"infra","muted":true}'; chan '{"topic":"debug","hidden":true}'
shot(){ # 名称 等待秒数 环境变量...
  local name=$1 wait=$2; shift 2
  env HUIJIAN_DEMO_PREFETCH="loss.png,report.pdf,confusion.png,周报.docx" HUIJIAN_DEMO_SELECT="exp42 完成" \
    HUIJIAN_DEMO_READ_OLDEST=9 HUIJIAN_DEMO_STAR="周报已生成" HUIJIAN_DEMO_PROGRESS=1 HUIJIAN_DEMO_CANADMIN=1 "$@" \
    build/shots/Huijian.app/Contents/MacOS/Huijian --demo $PUB $DT $DEMO/app-$name > $T/app-$name.log 2>&1 &
  APP_PID=$!
  sleep $wait
  local ok=""
  for try in 1 2 3 4 5; do
    WID=$(xcrun swift tests/winid.swift $APP_PID 2>/dev/null | head -1)
    if [ -n "$WID" ]; then
      screencapture -x -o -l $WID $S/$name.png
      W=$(sips -g pixelWidth $S/$name.png 2>/dev/null | tail -1 | awk '{print $2}')
      if [ "${W:-0}" -ge 500 ]; then ok=1; break; fi
    fi
    osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $APP_PID) to true" >/dev/null 2>&1
    sleep 2
  done
  if [ -n "$ok" ]; then echo "✅ $S/$name.png (${W}px)"; else echo "❌ $name 截图失败（宽 ${W:-0}）"; fi
  kill $APP_PID 2>/dev/null; wait $APP_PID 2>/dev/null; APP_PID=""
}
want(){ [ $# -eq 0 ] || [[ " $ONLY " == *" $1 "* ]]; }
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
  env HUIJIAN_DEMO_RENAME=train HUIJIAN_DEMO_LIGHT=1 HUIJIAN_DEMO_SELECT="exp42 完成" HUIJIAN_DEMO_READ_OLDEST=9 \
    build/shots/Huijian.app/Contents/MacOS/Huijian --demo $PUB $DT $DEMO/app-channel-rename > $T/app-channel-rename.log 2>&1 &
  APP_PID=$!; sleep 9
  RB=$(xcrun swift tests/winid.swift $APP_PID bounds 2>/dev/null | head -1)
  if [ -n "$RB" ] && screencapture -x -R "$RB" $S/channel-rename.png; then echo "✅ $S/channel-rename.png"; else echo "❌ channel-rename 截图失败"; fi
  kill $APP_PID 2>/dev/null; wait $APP_PID 2>/dev/null; APP_PID=""
fi
if inc channel-menu; then
  # 在「训练」频道上右键，截出频道菜单（需要辅助功能权限；没有权限时截图里没有菜单，脚本会提示）
  env HUIJIAN_DEMO_LIGHT=1 HUIJIAN_DEMO_SELECT="exp42 完成" HUIJIAN_DEMO_READ_OLDEST=9 \
    build/shots/Huijian.app/Contents/MacOS/Huijian --demo $PUB $DT $DEMO/app-channel-menu > $T/app-channel-menu.log 2>&1 &
  APP_PID=$!; sleep 8
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $APP_PID) to true" >/dev/null 2>&1; sleep 1
  RB=$(xcrun swift tests/winid.swift $APP_PID bounds 2>/dev/null | head -1)
  if [ -n "$RB" ]; then
    IFS=, read WX WY WW WH <<< "$RB"
    # 「训练」是频道下的第一项：距窗口左边约 60pt、顶部约 319pt（窗口宽 1180pt 时）
    xcrun swift tests/rightclick.swift $((WX + 60)) $((WY + 319)) 2>/dev/null; sleep 1.5
    screencapture -x -R "$WX,$WY,$((WW < 640 ? WW : 640)),$((WH))" $S/channel-menu.png && echo "✅ $S/channel-menu.png（请确认截图里有右键菜单）" || echo "❌ channel-menu 截图失败"
  fi
  kill $APP_PID 2>/dev/null; wait $APP_PID 2>/dev/null; APP_PID=""
fi
if inc pair-used; then
  # 账户页生成配对码 → 用它配对一台「新 iPhone」→ 截图应显示「已被「新 iPhone」使用」
  env HUIJIAN_DEMO_SHOW=account HUIJIAN_DEMO_LIGHT=1 HUIJIAN_DEMO_PAIRCODE=1 \
    build/shots/Huijian.app/Contents/MacOS/Huijian --demo $PUB $DT $DEMO/app-pair-used > $T/app-pair-used.log 2>&1 &
  APP_PID=$!
  for i in $(seq 1 30); do PCODE=$(grep -o 'DEMO_PAIRCODE=[0-9]*' $T/app-pair-used.log | tail -1 | cut -d= -f2); [ -n "$PCODE" ] && break; sleep 0.5; done
  sleep 2; PCODE=$(grep -o 'DEMO_PAIRCODE=[0-9]*' $T/app-pair-used.log | tail -1 | cut -d= -f2)
  if [ -n "$PCODE" ]; then
    curl -s -o /dev/null -H 'Content-Type: application/json' -d "{\"code\":\"$PCODE\",\"name\":\"新 iPhone\",\"platform\":\"ios\"}" $PUB/v1/pair
    sleep 4
    WID=$(xcrun swift tests/winid.swift $APP_PID 2>/dev/null | head -1)
    [ -n "$WID" ] && screencapture -x -o -l $WID $S/pair-used.png && echo "✅ $S/pair-used.png"
  else
    echo "❌ pair-used：没拿到配对码"
  fi
  kill $APP_PID 2>/dev/null; wait $APP_PID 2>/dev/null; APP_PID=""
fi
inc pair && shot pair 4 HUIJIAN_DEMO_SHOW=pair HUIJIAN_DEMO_LIGHT=1
true
