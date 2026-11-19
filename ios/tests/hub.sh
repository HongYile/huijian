# 测试用的独立 hub（被 selftest.sh / sim_shots.sh 用 source 引入，在 ios/ 目录下执行）：
# 临时数据目录、127.0.0.1:28790（公网 API）/ 28791（管理后台），账号 me / demo-pass-1，
# 4 把 pushkey、十几条演示消息（含图片、PDF、压缩包附件；一条覆盖全部回笺 Markdown 语法的报告，tests/markdown_demo.md），频道设置（train 改名「训练」并置顶、infra 静音、debug 隐藏），
# 外加一个模拟 Bark 服务器（127.0.0.1:28799，请求记录在 $T/bark.log）。
# 另有一个只给端到端加密联网自检用的账号 e2etest（管理后台创建，旧方式的密码；自检会开启加密、改掉它的密码）。
# 导出：PUB ADM DEMO_USER DEMO_PASS E2E_USER E2E_PASS BARK_URL T HUB BARK_PID
set -u
B=../server/bin/huijian
(cd ../server && GOTOOLCHAIN=local go build -o bin/huijian .) || { echo "❌ 服务端编译失败"; exit 1; }
T=test-run; F=$T/files
DEMO=/tmp/huijian-ios-test; rm -rf "$DEMO" "$T"; mkdir -p "$DEMO/data" "$F"
python3 ../server/tests/make_fixtures.py $F
cp $F/loss.png $F/confusion.png; head -c 48000 /dev/urandom > $F/metrics.xlsx
head -c 3200000 /dev/urandom > $F/ckpt-exp42.zip; seq 1 4000 | sed 's/^/step /' > $F/train.log
PUB=http://127.0.0.1:28790; ADM=http://127.0.0.1:28791
DEMO_USER=me; DEMO_PASS=demo-pass-1
TZ=UTC HUIJIAN_DATA=$DEMO/data HUIJIAN_PUBLIC_ADDR=127.0.0.1:28790 HUIJIAN_ADMIN_ADDR=127.0.0.1:28791 $B hub > $T/hub.log 2>&1 &
HUB=$!
python3 tests/bark_mock.py 28799 $T/bark.log > $T/bark-mock.log 2>&1 &
BARK_PID=$!
BARK_URL=http://127.0.0.1:28799/hyTestKey123
trap 'kill $HUB $BARK_PID 2>/dev/null' EXIT
for i in $(seq 1 50); do curl -sf $PUB/healthz >/dev/null && break; sleep 0.2; done
curl -sf $PUB/healthz >/dev/null || { echo "❌ hub 没起来"; cat $T/hub.log; exit 1; }
J=$T/cookies
curl -s -c $J -o /dev/null -d "token=$(cat $DEMO/data/admin.token)" $ADM/login
key(){ curl -s -b $J -o /dev/null -w '%{redirect_url}' -H "Origin: $ADM" --data-urlencode "name=$1" $ADM/pushkeys \
  | python3 -c "import sys,urllib.parse as u;print(u.parse_qs(u.urlparse(sys.stdin.read()).query)['key'][0])"; }
K_TRAIN=$(key "训练脚本"); K_MON=$(key "服务器监控"); K_REP=$(key "周报机器人"); K_JOB=$(key "数据采集")
curl -s -b $J -o /dev/null -H "Origin: $ADM" --data-urlencode "username=$DEMO_USER" -d password=$DEMO_PASS $ADM/accounts/1/credentials
E2E_USER=e2etest; E2E_PASS=e2e-old-pass-1
curl -s -b $J -o /dev/null -H "Origin: $ADM" --data-urlencode "username=$E2E_USER" -d password=$E2E_PASS $ADM/accounts
p(){ $B push -u $PUB "$@" >/dev/null; }
p -k $K_REP -p 3 -topic report -d "本周实验周报已生成" "周报已生成（10/06–10/12）"
p -k $K_MON -p 2 -topic infra "nightly backup ok · 1.9 GB → NAS"
p -k $K_TRAIN -p 1 -topic train -thread exp42 "data loader ready: 1.28M images"
p -k $K_TRAIN -p 4 -topic train -thread exp42 -d $'- 模型：**ResNet-50**\n- 学习率：`3e-4`，batch 256\n- 主机：gpu-node-1 / 单卡' "exp42 训练开始"
p -k $K_TRAIN -p 2 -topic train -thread exp42 -d "train_loss 0.412 · val_loss 0.455 · 剩余约 3.1 小时" "epoch 37/100"
p -k $K_TRAIN -p 3 -topic train -thread exp42 -d $'阶段评估：top-1 **91.2%**，混淆矩阵见附件。' -f $F/confusion.png -f $F/metrics.xlsx "exp42 阶段评估 @ epoch 50"
p -k $K_MON -p 5 -topic infra -d $'`/srv/data` 所在分区占用 **95%**（438 GB / 460 GB）。\n\n> 建议清理 `~/ckpt` 下的旧 checkpoint，或扩容数据盘。' "gpu-node-1 磁盘使用率 95%"
p -k $K_REP -p 3 -topic report -d $'本周实验周报已生成：\n\n1. exp42 完成，val_loss 0.198\n2. exp43 进行中\n3. 下周：消融实验' -f $F/report.pdf "周报已生成（11/10–11/16）"
p -k $K_MON -p 2 -topic infra "nightly backup ok · 2.1 GB → NAS"
p -k $K_TRAIN -p 3 -topic train -thread exp43 -d "lr warmup 完成，进入余弦退火" "exp43 epoch 5/60"
p -k $K_JOB -p 3 -topic crawler -d "新增 128 · 更新 57 · 失败 3" "今日采集完成 2,315 条"
p -k $K_TRAIN -p 1 -topic debug "debug: dataloader worker 4 restarted"
p -k $K_TRAIN -p 4 -topic train -thread exp42 -d $'## 结果\n- best val_loss **0.198** @ epoch 87\n- top-1 acc **93.4%**，比 baseline 高 1.7 个点\n- 训练用时 6.2 小时\n\n加载最佳权重：\n\n```python\nmodel.load_state_dict(torch.load("best.pt"))\nmodel.eval()\n```\n\n> 附件里有曲线、评估报告和 checkpoint。详见 [实验记录](https://example.com/exp42)。' \
  -f $F/loss.png -f $F/report.pdf -f $F/ckpt-exp42.zip -f $F/train.log "exp42 完成"
# 覆盖全部回笺 Markdown 语法的演示消息（服务端 0.6.0 解析成 doc）：正文里用 attachment: 引用图片和 PDF，
# huijian://message/<id> 指向上面的「exp42 完成」
E42=$(python3 -c "import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute(\"select id from messages where text='exp42 完成'\").fetchone()[0])" $DEMO/data/huijian.db)
p -k $K_TRAIN -p 3 -topic train -thread exp43 -d "$(sed "s/E42_ID/$E42/" tests/markdown_demo.md)" -f $F/loss.png -f $F/report.pdf "exp43 训练报告"
# 把时间铺开（只改测试库）：几分钟到几小时前
python3 - $DEMO/data/huijian.db <<'PY'
import sqlite3,sys,time
c=sqlite3.connect(sys.argv[1]); now=int(time.time())
ago=[2900,400,395,250,180,170,95,75,52,30,20,12,3,1]
ids=[r[0] for r in c.execute("select id from messages order by id")]
for i,a in zip(ids,ago): c.execute("update messages set created_at=? where id=?",(now-a*60,i))
c.commit()
PY
# 频道设置：用一台临时设备的 token 调 /v1/channels
CODE=$(curl -s -b $J -o /dev/null -w '%{redirect_url}' -H "Origin: $ADM" -d can_admin=on $ADM/pair | sed -E 's/.*code=([0-9]+).*/\1/')
DT=$(curl -s -X POST $PUB/v1/pair -H 'Content-Type: application/json' -d "{\"code\":\"$CODE\",\"name\":\"我的 MacBook\",\"platform\":\"macos\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
chan(){ curl -s -o /dev/null -X PATCH -H "Authorization: Bearer $DT" -H 'Content-Type: application/json' -d "$1" $PUB/v1/channels; }
chan '{"topic":"train","alias":"训练","pinned":true}'; chan '{"topic":"infra","muted":true}'; chan '{"topic":"debug","hidden":true}'
echo "hub 已就绪：${PUB}（账号 ${DEMO_USER}），模拟 Bark：${BARK_URL}"
