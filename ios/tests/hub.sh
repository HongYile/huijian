# 测试用的独立 hub（被 selftest.sh / sim_shots.sh 用 source 引入，在 ios/ 目录下执行）：
# 临时数据目录、127.0.0.1:28790（公网 API）/ 28791（管理后台），账号 me / demo-pass-1，
# 4 把 pushkey、十几条演示消息（含图片、PDF、压缩包附件；一条覆盖全部回笺 Markdown 语法的报告，tests/markdown_demo.md），频道设置（train 改名「训练」并置顶、infra 静音、debug 隐藏），
# 外加一个模拟 Bark 服务器（127.0.0.1:28799，请求记录在 $T/bark.log）。
# 服务端 0.9.0 起账号只能注册产生、注册即开启加密：演示账号用 huijian invite new + huijian register 建（不设恢复码），
# 它的第一台设备「我的 MacBook」的 token 只写进 $T/demo.token，用来建 pushkey、改频道设置。
# 演示消息大部分用加密发送密钥（PK_xxx.e2e.<账号公钥>）发：huijian push 在本机加密，客户端显示 🔒；
# 只有「数据采集」和最近一条备份通知用普通 pushkey 发（像 curl 脚本），服务器代加密保存，客户端标「明文发送」。
# 另给端到端加密联网自检一个可用多次的邀请码（$T/e2e.invite）和一个还没注册的账号名 / 密码，由自检自己注册。
# 邀请码、token 只写文件，不打印。
# 测试数据目录：$T（默认 ios/test-run）、$DEMO（默认 /tmp/huijian-ios-test），可用 HUIJIAN_TEST_DIR / HUIJIAN_TEST_DATA 改到别处。
# 导出：PUB ADM J DEMO DEMO_USER DEMO_PASS DT E2E_USER E2E_PASS E2E_INVITE BARK_URL T HUB BARK_PID
set -u
# rm -rf 的保护：只删 /tmp 下、名为 test-run 的目录，或者 hub.sh 自己建的测试目录（里面有 .huijian-test-dir 标记）。
# 防止 HUIJIAN_TEST_DIR / HUIJIAN_TEST_DATA 被误设成真实的数据目录
wipe(){ local d
  for d in "$@"; do
    case "$d" in ""|/|*..*) echo "❌ 测试目录不安全：「$d」"; exit 1;; esac
    [ -e "$d" ] || continue
    case "$d" in
      /tmp/?*|/private/tmp/?*|test-run|*/test-run) ;;
      *) [ -f "$d/.huijian-test-dir" ] || { echo "❌ 拒绝删除 $d：不在 /tmp 下、不叫 test-run，也不是 hub.sh 建的测试目录（没有 .huijian-test-dir）"; exit 1; };;
    esac
  done
  rm -rf "$@"; }
# 准备演示数据的任何一步失败都立即退出（不带着残缺的数据去跑自检 / 截图）
fail(){ echo "❌ $1"; exit 1; }
B=../server/bin/huijian
(cd ../server && GOTOOLCHAIN=local go build -o bin/huijian .) || fail "服务端编译失败"
# 测试 hub 的数据、邀请码、token 都只给自己读写；结尾恢复调用方原来的 umask（本文件被 source）
HUB_UMASK=$(umask); umask 077
T=${HUIJIAN_TEST_DIR:-test-run}; F=$T/files
DEMO=${HUIJIAN_TEST_DATA:-/tmp/huijian-ios-test}; wipe "$DEMO" "$T"; mkdir -p "$DEMO/data" "$DEMO/home" "$F" || fail "建测试目录失败"
touch "$DEMO/.huijian-test-dir" "$T/.huijian-test-dir"
# 命令行 huijian（register / invite / push）的 HOME 指到演示目录：不碰本机 ~/.huijian（push 发送前会补发那里积压的真实消息，
# 发送失败时还会把演示消息存进去）
H=$DEMO/home
python3 ../server/tests/make_fixtures.py $F > /dev/null || fail "生成演示附件失败"
{ cp $F/loss.png $F/confusion.png && head -c 48000 /dev/urandom > $F/metrics.xlsx \
  && head -c 3200000 /dev/urandom > $F/ckpt-exp42.zip && seq 1 4000 | sed 's/^/step /' > $F/train.log; } || fail "生成演示附件失败"
PUB=http://127.0.0.1:28790; ADM=http://127.0.0.1:28791
DEMO_USER=me; DEMO_PASS=demo-pass-1
TZ=UTC HUIJIAN_DATA=$DEMO/data HUIJIAN_PUBLIC_ADDR=127.0.0.1:28790 HUIJIAN_ADMIN_ADDR=127.0.0.1:28791 $B hub > $T/hub.log 2>&1 &
HUB=$!
python3 tests/bark_mock.py 28799 $T/bark.log > $T/bark-mock.log 2>&1 &
BARK_PID=$!
BARK_URL=http://127.0.0.1:28799/hyTestKey123
trap 'kill $HUB $BARK_PID 2>/dev/null' EXIT
for i in $(seq 1 50); do curl -sf $PUB/healthz >/dev/null && break; sleep 0.2; done
curl -sf $PUB/healthz >/dev/null || { cat $T/hub.log; fail "hub 没起来"; }
# 管理后台登录（sim_shots.sh 用它切换注册方式、发布测试版本）
J=$T/cookies
case "$(curl -s -c $J -o /dev/null -w '%{http_code} %{redirect_url}' -d "token=$(cat $DEMO/data/admin.token)" $ADM/login)" in
  "303 $ADM/") ;; *) fail "管理后台登录失败";; esac
# 新部署默认邀请制（register = invite）。邀请码只写文件
inv(){ HOME=$H HUIJIAN_DATA=$DEMO/data HUIJIAN_ADMIN_ADDR=127.0.0.1:28791 $B invite new -note "$1" -uses "$2" > "$3" 2>> $T/invite.log \
  && [ -s "$3" ] || { cat $T/invite.log; fail "生成邀请码失败"; }; }
inv "iOS 演示账号" 1 $T/demo.invite
# 注册演示账号：注册即开启加密，本机（CLI）作为第一台设备「我的 MacBook」，token 写进 $T/demo.token
printf '%s\n' "$DEMO_PASS" | HOME=$H $B register -u $PUB -invite "$(cat $T/demo.invite)" -platform macos -name "我的 MacBook" \
  -token-out $T/demo.token $DEMO_USER > $T/register.log 2>&1 || { cat $T/register.log; fail "注册演示账号失败"; }
DT=$(cat $T/demo.token); [ -n "$DT" ] || fail "演示账号的 token 文件是空的"
# 端到端加密联网自检：自检用这个邀请码注册 $E2E_USER（可用多次：注册失败重试、以后加用例都够用）
E2E_USER=e2etest; E2E_PASS='Hj-E2e-Selftest-7q!'
inv "iOS 加密自检" 10 $T/e2e.invite
E2E_INVITE=$(cat $T/e2e.invite)
# pushkey 用演示账号自己的设备 token 建（POST /v1/keys）。JSON 先用 python 拼好放进变量（bash 3.2 不拆花括号）
key(){ local body; body=$(python3 -c 'import json,sys;print(json.dumps({"name":sys.argv[1]}))' "$1")
  curl -s -X POST -H "Authorization: Bearer $DT" -H 'Content-Type: application/json' -d "$body" $PUB/v1/keys \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["key"])' 2>/dev/null; }
K_TRAIN=$(key "训练脚本"); K_MON=$(key "服务器监控"); K_REP=$(key "周报机器人"); K_JOB=$(key "数据采集")
[ -n "$K_TRAIN" ] && [ -n "$K_MON" ] && [ -n "$K_REP" ] && [ -n "$K_JOB" ] || fail "建 pushkey 失败"
# 加密发送密钥 = pushkey + ".e2e." + 账号启用中的公钥（客户端 Pushkey 页默认复制的就是它）
ACCT_PUB=$(curl -s -H "Authorization: Bearer $DT" $PUB/v1/e2e \
  | python3 -c 'import sys,json;print(next(k["pub"] for k in json.load(sys.stdin)["keys"] if k.get("active")))' 2>/dev/null)
[ -n "$ACCT_PUB" ] || fail "取账号公钥失败"
E_TRAIN=$K_TRAIN.e2e.$ACCT_PUB; E_MON=$K_MON.e2e.$ACCT_PUB; E_REP=$K_REP.e2e.$ACCT_PUB
# p 发一条，失败立即退出；pid 发一条并输出消息 id（huijian push 打印「已发送，消息 id: N」）
p(){ HOME=$H $B push -u $PUB "$@" >/dev/null 2>>$T/push.err || fail "发送演示消息失败：$(tail -1 $T/push.err)"; }
pid(){ HOME=$H $B push -u $PUB "$@" 2>>$T/push.err | sed -n 's/^已发送，消息 id: *//p'; }
p -k $E_REP -p 3 -topic report -d "本周实验周报已生成" "周报已生成（10/06–10/12）"
p -k $E_MON -p 2 -topic infra "nightly backup ok · 1.9 GB → NAS"
p -k $E_TRAIN -p 1 -topic train -thread exp42 "data loader ready: 1.28M images"
p -k $E_TRAIN -p 4 -topic train -thread exp42 -d $'- 模型：**ResNet-50**\n- 学习率：`3e-4`，batch 256\n- 主机：gpu-node-1 / 单卡' "exp42 训练开始"
p -k $E_TRAIN -p 2 -topic train -thread exp42 -d "train_loss 0.412 · val_loss 0.455 · 剩余约 3.1 小时" "epoch 37/100"
p -k $E_TRAIN -p 3 -topic train -thread exp42 -d $'阶段评估：top-1 **91.2%**，混淆矩阵见附件。' -f $F/confusion.png -f $F/metrics.xlsx "exp42 阶段评估 @ epoch 50"
p -k $E_MON -p 5 -topic infra -d $'`/srv/data` 所在分区占用 **95%**（438 GB / 460 GB）。\n\n> 建议清理 `~/ckpt` 下的旧 checkpoint，或扩容数据盘。' "gpu-node-1 磁盘使用率 95%"
p -k $E_REP -p 3 -topic report -d $'本周实验周报已生成：\n\n1. exp42 完成，val_loss 0.198\n2. exp43 进行中\n3. 下周：消融实验' -f $F/report.pdf "周报已生成（11/10–11/16）"
# 这条和后面的「今日采集完成」用普通 pushkey（像 curl 脚本）：服务器代加密，客户端标「明文发送」
p -k $K_MON -p 2 -topic infra "nightly backup ok · 2.1 GB → NAS"
p -k $E_TRAIN -p 3 -topic train -thread exp43 -d "lr warmup 完成，进入余弦退火" "exp43 epoch 5/60"
p -k $K_JOB -p 3 -topic crawler -d "新增 128 · 更新 57 · 失败 3" "今日采集完成 2,315 条"
p -k $E_TRAIN -p 1 -topic debug "debug: dataloader worker 4 restarted"
E42=$(pid -k $E_TRAIN -p 4 -topic train -thread exp42 -d $'## 结果\n- best val_loss **0.198** @ epoch 87\n- top-1 acc **93.4%**，比 baseline 高 1.7 个点\n- 训练用时 6.2 小时\n\n加载最佳权重：\n\n```python\nmodel.load_state_dict(torch.load("best.pt"))\nmodel.eval()\n```\n\n> 附件里有曲线、评估报告和 checkpoint。详见 [实验记录](https://example.com/exp42)。' \
  -f $F/loss.png -f $F/report.pdf -f $F/ckpt-exp42.zip -f $F/train.log "exp42 完成")
case "$E42" in ''|*[!0-9]*) fail "发送「exp42 完成」失败：$(tail -1 $T/push.err)";; esac
# 覆盖全部回笺 Markdown 语法的演示消息（服务端 0.6.0 解析成 doc）：正文里用 attachment: 引用图片和 PDF，
# huijian://message/<id> 指向上面的「exp42 完成」（id 取自发送时 huijian push 的输出）
p -k $E_TRAIN -p 3 -topic train -thread exp43 -d "$(sed "s/E42_ID/$E42/" tests/markdown_demo.md)" -f $F/loss.png -f $F/report.pdf "exp43 训练报告"
# 把时间铺开（只改测试库）：几分钟到几小时前
python3 - $DEMO/data/huijian.db <<'PY'
import sqlite3,sys,time
c=sqlite3.connect(sys.argv[1]); now=int(time.time())
ago=[2900,400,395,250,180,170,95,75,52,30,20,12,3,1]
ids=[r[0] for r in c.execute("select id from messages order by id")]
for i,a in zip(ids,ago): c.execute("update messages set created_at=? where id=?",(now-a*60,i))
n=c.execute("select count(*) from messages").fetchone()[0]
assert n==len(ago), "演示消息应有 %d 条，实际 %d 条" % (len(ago), n)
c.commit()
PY
[ $? -eq 0 ] || fail "调整演示消息时间失败"
# 频道设置：用演示账号「我的 MacBook」的 token 调 /v1/channels
chan(){ [ "$(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H "Authorization: Bearer $DT" -H 'Content-Type: application/json' -d "$1" $PUB/v1/channels)" = 200 ] \
  || fail "频道设置失败：$1"; }
chan '{"topic":"train","alias":"训练","pinned":true}'; chan '{"topic":"infra","muted":true}'; chan '{"topic":"debug","hidden":true}'
umask $HUB_UMASK
echo "hub 已就绪：${PUB}（账号 ${DEMO_USER}），模拟 Bark：${BARK_URL}"
