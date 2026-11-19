#!/usr/bin/env bash
# 管理网页视觉验收：起演示实例(38790/38791) → 填充演示数据 → Edge 无头截图（浅色/深色）
set -u
cd "$(dirname "$0")/.."
D=tests/web-shots; mkdir -p $D/files
# 演示数据放在中性路径下：设置页会显示数据 / 附件 / 备份目录，截图里不能出现本机用户目录
DEMO=/tmp/huijian; rm -rf $DEMO; mkdir -p $DEMO/data $DEMO/nas/files $DEMO/nas/backup
PUB=http://127.0.0.1:38790; ADM=http://127.0.0.1:38791
export TZ=UTC HUIJIAN_PUBLIC_URL=https://push.example.com HUIJIAN_DATA=$DEMO/data HUIJIAN_FILES=$DEMO/nas/files HUIJIAN_BACKUP_DIR=$DEMO/nas/backup HUIJIAN_PUBLIC_ADDR=127.0.0.1:38790 HUIJIAN_ADMIN_ADDR=127.0.0.1:38791
./bin/huijian hub > $D/hub.log 2>&1 & HUB=$!
trap 'kill $HUB $LP 2>/dev/null' EXIT; LP=0
for i in $(seq 1 30); do curl -sf $PUB/healthz >/dev/null && break; sleep 0.2; done
J=$D/c; curl -s -c $J -o /dev/null -d "token=$(cat $DEMO/data/admin.token)" $ADM/login
key(){ curl -s -b $J -o /dev/null -w '%{redirect_url}' -H "Origin: $ADM" --data-urlencode "name=$1" $ADM/keys | python3 -c "import sys,urllib.parse as u;print(u.parse_qs(u.urlparse(sys.stdin.read()).query)['key'][0])"; }
K1=$(key "PC 训练脚本"); K2=$(key "gpu-01 监控"); K3=$(key "CI 流水线"); K4=$(key "旧笔记本（已停用）")
curl -s -b $J -o /dev/null -H "Origin: $ADM" -X POST $ADM/keys/4/revoke
python3 tests/make_fixtures.py $D/files
cp $D/files/report.pdf "$D/files/实验记录-第三周.docx"; head -c 48000 /dev/urandom > "$D/files/指标汇总.xlsx"
head -c 5200000 /dev/urandom > $D/files/checkpoint-ep87.zip; seq 1 4000 | sed 's/^/step /' > $D/files/train.log
B="./bin/huijian push -u $PUB"
$B -k $K1 -p 4 -topic train -thread exp42-lr3e-4 -d $'训练开始，配置：\n- lr 3e-4\n- batch 64\n- 100 epochs' "▶️ exp42 开始" >/dev/null
for e in 25 50 75; do $B -k $K1 -p 2 -topic train -thread exp42-lr3e-4 "epoch $e/100 loss 0.$((60-e/3))" >/dev/null; done
$B -k $K1 -p 3 -topic train -thread exp42-lr3e-4 -d "val_loss **0.247**，比基线低 4.1%" -f $D/files/loss.png "📈 exp42 第 50 轮评估" >/dev/null
$B -k $K1 -p 1 -topic train -thread exp42-lr3e-4 -f $D/files/train.log "训练日志（自动上传）" >/dev/null
$B -k $K1 -p 4 -topic train -thread exp42-lr3e-4 -d $'best val_loss **0.231** @ epoch 87\n\n用时 6.2 小时，报告和曲线见附件。下一步：\n1. 用 lr 1e-4 复跑\n2. 在 test 集上评估\n\n```\npython eval.py --ckpt ep87 --split test\n```' -f $D/files/loss.png -f $D/files/report.pdf -f "$D/files/实验记录-第三周.docx" -f "$D/files/指标汇总.xlsx" -f $D/files/checkpoint-ep87.zip "✅ exp42 完成" >/dev/null
$B -k $K2 -p 5 -topic infra -d "gpu-01 根分区使用率 95%（338G/356G），请尽快清理 docker 镜像" "🚨 gpu-01 磁盘即将写满" >/dev/null
$B -k $K2 -p 3 -topic infra "每日备份完成：NAS 同步 1.2 GB" >/dev/null
$B -k $K3 -p 4 -topic ci -d "main 分支 42 个测试全部通过，用时 3 分 12 秒" "CI 构建成功 #128" >/dev/null
$B -k $K2 -p 0 -topic debug "heartbeat ok" >/dev/null
$B -k $K3 -p 2 -topic ci "依赖缓存命中率 96%" >/dev/null
VER=$(sed -nE 's/^const version = "(.*)"/\1/p' main.go)
pair(){ C=$(curl -s -b $J -o /dev/null -w '%{redirect_url}' -H "Origin: $ADM" $3 -X POST $ADM/pair | sed -E 's/.*code=([0-9]+).*/\1/')
  curl -s -X POST $PUB/v1/pair -H 'Content-Type: application/json' -H "X-Huijian-Client: Huijian $VER ($2)" -d "{\"code\":\"$C\",\"name\":\"$1\",\"platform\":\"$2\"}" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["token"],d["device_id"])'; }
read T1 D1 < <(pair "我的 MacBook" macos "-d can_admin=1"); read T2 D2 < <(pair "我的 iPhone" ios ""); read T3 D3 < <(pair "测试设备" test "")
curl -s -b $J -o /dev/null -H "Origin: $ADM" -X POST $ADM/devices/$D3/revoke
curl -s -H "Authorization: Bearer $T2" "$PUB/v1/messages?limit=1" >/dev/null
( while :; do curl -s -m 60 -H "Authorization: Bearer $T1" "$PUB/v1/messages?since=999999&wait=50" >/dev/null; done ) & LP=$!
sleep 0.5
EDGE="/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
shot(){ local page=$1 name=$2 mode=$3 h=${4:-1100}
  local link=$(./bin/huijian admin-link | tail -1)
  local extra=""; [ "$mode" = dark ] && extra="--force-dark-mode --blink-settings=preferredColorScheme=0"
  "$EDGE" --headless=new --disable-gpu --hide-scrollbars --user-data-dir=$(mktemp -d) $extra --window-size=1440,$h \
    --virtual-time-budget=4000 --screenshot="$D/$name-$mode.png" "$link&next=$page" >/dev/null 2>&1; }
# 账号：给第一个账号设用户名密码，再建一个家人账号（页面顶部出现账号切换）
curl -s -b $J -o /dev/null -H "Origin: $ADM" --data-urlencode "username=me" -d password=demo-pass-1 $ADM/accounts/1/credentials
curl -s -b $J -o /dev/null -H "Origin: $ADM" --data-urlencode "username=家人" -d password=demo-pass-2 $ADM/accounts
./bin/huijian backup >/dev/null 2>&1
# 配对码页面需要先生成
CODEURL=$(curl -s -b $J -o /dev/null -w '%{redirect_url}' -H "Origin: $ADM" -d can_admin=1 -X POST $ADM/pair | sed "s|$ADM||")
for m in light dark; do
  shot / overview $m 1250; shot /messages messages $m 1500; shot /keys keys $m 1250
  shot "$(python3 -c 'import sys,urllib.parse as u;print(u.quote(sys.argv[1],safe=""))' "$CODEURL")" devices $m 950; shot /settings settings $m 1750; shot /accounts accounts $m 1100
done
"$EDGE" --headless=new --disable-gpu --hide-scrollbars --user-data-dir=$(mktemp -d) --window-size=1440,900 --screenshot="$D/login-light.png" "$ADM/login?e=1" >/dev/null 2>&1
ls -la $D/*.png | awk '{print $5, $9}'
grep "模板渲染失败" $D/hub.log || echo "无模板错误"
