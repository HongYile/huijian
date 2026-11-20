#!/usr/bin/env bash
# 管理网页视觉验收（0.9.0）：起演示实例(38790/38791) → 填充演示数据 → Edge 无头截图（浅色/深色）
#
# 0.9.0 的后台只有 概览 / 账号 / 邀请码 / 设置 四页，只显示账号和计数统计。演示数据按真实流程造：
# 服务器上发邀请码 → 命令行注册（注册即开启加密）→ 其他设备密码登录 → /v1/keys 建 pushkey → 推送（明文发送，服务器代加密保存）。
set -u
cd "$(dirname "$0")/.."
for b in "" e2etool; do
  out=bin/huijian${b:+-$b}
  if [ ! -x $out ] || [ -n "$(find . -name '*.go' -newer $out | head -1)" ]; then
    GOTOOLCHAIN=local go build ${b:+-tags $b} -o $out . || exit 1
  fi
done
TOOL=bin/huijian-e2etool
D=tests/web-shots; mkdir -p $D/files
# 演示数据放在中性路径下：设置页会显示数据 / 附件 / 备份目录，截图里不能出现本机用户目录
DEMO=/tmp/huijian; rm -rf $DEMO; mkdir -p $DEMO/data $DEMO/nas/files $DEMO/nas/backup
PUB=http://127.0.0.1:38790; ADM=http://127.0.0.1:38791
export TZ=UTC HUIJIAN_PUBLIC_URL=https://push.example.com HUIJIAN_DATA=$DEMO/data HUIJIAN_FILES=$DEMO/nas/files HUIJIAN_BACKUP_DIR=$DEMO/nas/backup HUIJIAN_PUBLIC_ADDR=127.0.0.1:38790 HUIJIAN_ADMIN_ADDR=127.0.0.1:38791
unset HUIJIAN_URL HUIJIAN_PUSHKEY HUIJIAN_ADMIN_URL HUIJIAN_ADMIN_TOKEN
./bin/huijian hub > $D/hub.log 2>&1 & HUB=$!
trap 'kill $HUB $LP 2>/dev/null' EXIT; LP=0
for i in $(seq 1 30); do curl -sf $PUB/healthz >/dev/null && break; sleep 0.2; done
J=$D/c; curl -s -c $J -o /dev/null -d "token=$(cat $DEMO/data/admin.token)" $ADM/login
post(){ curl -s -b $J -o /dev/null -X POST -H "Origin: $ADM" "$@"; }
json(){ python3 -c 'import sys,json;a=sys.argv[1:];print(json.dumps(dict(zip(a[::2],a[1::2])),ensure_ascii=False))' "$@"; }
pj(){ python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }
VER=$(sed -nE 's/^(var|const) version = "(.*)"/\2/p' main.go)
# login 用户名 密码 平台 [客户端版本]：已开启加密的账号用 auth_key（新登录协议），输出设备 token
login(){
  local pre kdf body hdr=()
  pre=$(curl -s -G $PUB/v1/prelogin --data-urlencode "username=$1"); kdf=$(echo "$pre" | pj 'd["kdf"]')
  if [ "$kdf" = argon2id ]; then body=$(json username "$1" auth_key "$($TOOL e2e-authkey "$2" "$(echo "$pre" | pj 'd["salt"]')")" name d platform "$3" fingerprint "$(openssl rand -hex 16)")
  else body=$(json username "$1" password "$2" name d platform "$3" fingerprint "$(openssl rand -hex 16)"); fi
  [ -n "${4:-}" ] && hdr=(-H "X-Huijian-Client: $4")
  curl -s -H 'Content-Type: application/json' ${hdr[@]+"${hdr[@]}"} -d "$body" $PUB/v1/login | pj 'd.get("token","")'
}
# reg 用户名 密码 平台 客户端版本：服务器上发邀请码 → 命令行注册（本机生成钥匙，注册即开启加密），输出设备 token
reg(){
  local code tf=$D/reg-tok; code=$(./bin/huijian invite new 2>/dev/null); rm -f $tf
  echo "$2" | ./bin/huijian register -u $PUB -invite "$code" -platform "$3" -name d -token-out $tf "$1" >/dev/null || return 1
  curl -s -o /dev/null -H "Authorization: Bearer $(cat $tf)" -H "X-Huijian-Client: $4" $PUB/v1/me   # 上报客户端版本（概览按平台和版本统计）
  cat $tf
}

# 账号：都是用户自己注册的（「访客」之后停用）。第一个注册的 me 接收系统通知
T1=$(reg me demo-pass-01 macos "macos $VER (52)")
login me demo-pass-01 ios "ios 0.5.0 (21)" >/dev/null
login me demo-pass-01 android "android 0.5.0 (30)" >/dev/null
reg 家人 demo-pass-02 ios "ios 0.4.3 (18)" >/dev/null
login 家人 demo-pass-02 android "android 0.5.0 (30)" >/dev/null
reg "Alex Chen" demo-pass-02 macos "macos 0.8.2 (48)" >/dev/null
login "Alex Chen" demo-pass-02 windows "windows 0.1.0 (3)" >/dev/null
login "Alex Chen" demo-pass-02 ios >/dev/null   # 没上报版本号的旧客户端：算较旧
reg 访客 demo-pass-02 android "android 0.4.1 (22)" >/dev/null
post -d on=1 $ADM/accounts/4/disable
sleep 7   # 邀请码注册按 IP 限速
# 邀请码：两批；一个被客户端注册用掉，一个作废
post -d count=3 -d uses=1 -d days=7 --data-urlencode "note=实验室同学" $ADM/invites
post -d count=1 -d uses=5 -d days=30 --data-urlencode "note=家里人" $ADM/invites
C=($(sqlite3 $DEMO/data/huijian.db "SELECT code FROM invites WHERE note='实验室同学' ORDER BY code"))
C3=$(sqlite3 $DEMO/data/huijian.db "SELECT code FROM invites WHERE note='家里人'")
for x in "小王 ${C[0]}" "表姐 $C3"; do set -- $x; echo demo-pass-03 | ./bin/huijian register -u $PUB -invite $2 -platform ios -name d -token-out $D/reg-tok $1 >/dev/null; done
post $ADM/invites/${C[1]}/revoke
# macOS 有一个更新的发布：0.8.2 算较旧
sqlite3 $DEMO/data/huijian.db "INSERT INTO releases(platform,version,build,sha256,size,signature,created_at) VALUES('macos','$VER',52,'x',1,'x',1);"

# pushkey（客户端自助接口）+ 消息：服务器代加密，库里只有密文
K1=$(curl -s -H 'Content-Type: application/json' -H "Authorization: Bearer $T1" -d "$(json name 'PC 训练脚本')" $PUB/v1/keys | pj 'd["key"]')
python3 tests/make_fixtures.py $D/files
head -c 5200000 /dev/urandom > $D/files/checkpoint-ep87.zip
B="./bin/huijian push -u $PUB -k $K1"
$B -p 4 -topic train -thread exp42 -d $'训练开始，配置：\n- lr 3e-4\n- batch 64' "▶️ exp42 开始" >/dev/null
$B -p 4 -topic train -thread exp42 -d "best val_loss **0.231**" -f $D/files/loss.png -f $D/files/report.pdf -f $D/files/checkpoint-ep87.zip "✅ exp42 完成" >/dev/null
$B -p 5 -topic infra "🚨 gpu-01 磁盘即将写满" >/dev/null
./bin/huijian backup >/dev/null 2>&1

# 演示用的 30 天统计（只有计数）
python3 - $DEMO/data/huijian.db <<'EOF'
import sqlite3, sys, datetime, random
random.seed(7)
db = sqlite3.connect(sys.argv[1])
today = datetime.date.today()
for i in range(1, 31):
    d = (today - datetime.timedelta(days=i)).isoformat()
    for u in [1] + [u for u in (2, 3, 4, 5) if random.random() < (0.75 if u < 4 else 0.3)]:
        db.execute("INSERT OR IGNORE INTO daily_active(day,user_id) VALUES(?,?)", (d, u))
    msgs = random.randint(8, 60) + (40 if i % 7 in (2, 3) else 0)
    db.execute("""INSERT INTO stats_daily(day,messages,att_bytes,new_accounts) VALUES(?,?,?,?)
      ON CONFLICT(day) DO UPDATE SET messages=excluded.messages, att_bytes=excluded.att_bytes, new_accounts=excluded.new_accounts""",
      (d, msgs, msgs * random.randint(20000, 400000), 1 if i in (4, 11, 19, 26) else 0))
db.commit()
EOF
# 一台在线（长轮询）
( while :; do curl -s -m 60 -H "Authorization: Bearer $T1" "$PUB/v1/messages?since=999999&wait=50" >/dev/null; done ) & LP=$!
sleep 0.5

EDGE="/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
shot(){ local page=$1 name=$2 mode=$3 h=${4:-1100}
  local link=$(./bin/huijian admin-link | tail -1)
  local extra=""; [ "$mode" = dark ] && extra="--force-dark-mode --blink-settings=preferredColorScheme=0"
  "$EDGE" --headless=new --disable-gpu --hide-scrollbars --user-data-dir=$(mktemp -d) $extra --window-size=1440,$h \
    --virtual-time-budget=4000 --screenshot="$D/$name-$mode.png" "$link&next=$page" >/dev/null 2>&1; }
rm -f $D/*.png
for m in light dark; do
  shot / overview $m 1320; shot /accounts accounts $m 1100; shot /invites invites $m 1000; shot /settings settings $m 1750
done
"$EDGE" --headless=new --disable-gpu --hide-scrollbars --user-data-dir=$(mktemp -d) --window-size=1440,900 --screenshot="$D/login-light.png" "$ADM/login?e=1" >/dev/null 2>&1
ls -la $D/*.png | awk '{print $5, $9}'
# 页面里不出现 pushkey、设备名、消息内容；库里没有明文
echo "页面泄露检查（应为 0）：$(for p in / /accounts /invites /settings; do curl -s -b $J $ADM$p; done | grep -c "$K1\|exp42 完成\|磁盘\|PC 训练脚本")"
echo "库里明文检查（应为 0）：$(cat $DEMO/data/huijian.db* | grep -ac '训练开始\|val_loss\|磁盘')"
grep "模板渲染失败" $D/hub.log || echo "无模板错误"
