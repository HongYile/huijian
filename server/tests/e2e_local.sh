#!/usr/bin/env bash
# 本机端到端测试（0.9.0）：在 127.0.0.1:18790/18791 启动 hub，跑完自动关闭。
#
# 0.9.0 起服务器不保存明文、管理后台只管账号、账号只能注册产生，所以流程和真实客户端一样：
#   服务器上 huijian invite new 拿邀请码 → huijian register 注册（本机生成钥匙，注册即登录、即开启加密）
#   → /v1/keys 建 pushkey → 推送 → 解密后核对内容。
# 解密、新登录协议的凭证用 bin/huijian-e2etool（go build -tags e2etool，只给测试用，正式版本里没有这些命令）。
set -u
cd "$(dirname "$0")/.."
# 二进制不存在、或源码比它新时重新编译（避免拿旧服务端测新功能）
if [ ! -x bin/huijian ] || [ -n "$(find . -name '*.go' -newer bin/huijian | head -1)" ]; then
  GOTOOLCHAIN=local go build -o bin/huijian . || exit 1
fi
if [ ! -x bin/huijian-e2etool ] || [ -n "$(find . -name '*.go' -newer bin/huijian-e2etool | head -1)" ]; then
  GOTOOLCHAIN=local go build -tags e2etool -o bin/huijian-e2etool . || exit 1
fi
TOOL=bin/huijian-e2etool
T=tests/run; rm -rf $T; mkdir -p $T/data
KEYS=$T/keys.txt; : > $KEYS          # 各账号的私钥（解密用），每行一个
PUB=http://127.0.0.1:18790; ADM=http://127.0.0.1:18791
HENV=(HUIJIAN_DATA=$T/data HUIJIAN_PUBLIC_ADDR=127.0.0.1:18790 HUIJIAN_ADMIN_ADDR=127.0.0.1:18791 HUIJIAN_ADMIN_DENY=10.0.0.1 HUIJIAN_SERVER_UPDATE=0)
env "${HENV[@]}" ./bin/huijian hub > $T/hub.log 2>&1 &
HUB=$!; trap 'kill $HUB 2>/dev/null' EXIT
for i in $(seq 1 30); do curl -sf $PUB/healthz >/dev/null && break; sleep 0.2; done
pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
ng(){ echo "  ❌ $1"; fail=$((fail+1)); }
chk(){ if [ "$2" = "$3" ]; then ok "$1"; else ng "$1（期望 $3，实际 $2）"; fi; }
# pj 表达式：从标准输入的 JSON（变量 d）里取值
pj(){ python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }
pjx(){ python3 -c "import sys,json;d=json.load(sys.stdin);$1"; }   # 多条语句，自己 print
CJ=(-H 'Content-Type: application/json')
# json k v k v …：拼 JSON 请求体（值都是字符串）
json(){ python3 -c 'import sys,json;a=sys.argv[1:];print(json.dumps(dict(zip(a[::2],a[1::2])),ensure_ascii=False))' "$@"; }
# 管理后台表单（带会话 cookie 和同源 Origin），返回跳转地址
form(){ local path=$1; shift; curl -s -b $J -o /dev/null -w '%{redirect_url}' -X POST -H "Origin: $ADM" "$@" "$ADM$path"; }
flash(){ python3 -c 'import sys,urllib.parse as u;print(u.parse_qs(u.urlparse(sys.argv[1]).query).get("f",[""])[0])' "$1"; }
# login 用户名 密码 设备名 平台 [指纹] [客户端版本]：先 /v1/prelogin，已升级的账号用 auth_key，旧账号用密码；输出响应 JSON
login(){
  local pre kdf salt body hdr=()
  pre=$(curl -s -G $PUB/v1/prelogin --data-urlencode "username=$1")
  kdf=$(echo "$pre" | pj 'd["kdf"]'); salt=$(echo "$pre" | pj 'd["salt"]')
  if [ "$kdf" = argon2id ]; then body=$(json username "$1" auth_key "$($TOOL e2e-authkey "$2" "$salt")" name "$3" platform "$4" fingerprint "${5:-}")
  else body=$(json username "$1" password "$2" name "$3" platform "$4" fingerprint "${5:-}"); fi
  [ -n "${6:-}" ] && hdr=(-H "X-Huijian-Client: $6")
  curl -s "${CJ[@]}" ${hdr[@]+"${hdr[@]}"} -d "$body" $PUB/v1/login
}
# reg 用户名 密码 [邀请码] [平台] [设备名]：用 huijian register 注册（本机生成钥匙，注册即登录、即开启加密），
# 私钥记进钥匙文件，输出设备 token；失败时输出「状态码 错误文字」
reg(){
  local tf=$T/reg-tok kf=$T/reg-key; rm -f $tf $kf
  if echo "$2" | ./bin/huijian register -u $PUB ${3:+-invite "$3"} -platform "${4:-macos}" -name "${5:-x}" -token-out $tf -key-out $kf "$1" >/dev/null 2>$T/reg-err
  then cat $kf >> $KEYS; cat $tf; else sed -E 's/^注册失败（HTTP ([0-9]+)）：/\1 /' $T/reg-err; fi
}
# inv [参数]：在「服务器上」用命令行生成邀请码（本机管理端口 + 数据目录里的管理令牌）
inv(){ HUIJIAN_DATA=$T/data HUIJIAN_ADMIN_ADDR=127.0.0.1:18791 ./bin/huijian invite new "$@" 2>/dev/null; }
# msgs 设备token 查询串：拉消息并解密
msgs(){ curl -s -H "Authorization: Bearer $1" "$PUB/v1/messages?$2" | $TOOL e2e-open $KEYS; }
newkey(){ curl -s "${CJ[@]}" -H "Authorization: Bearer $1" -d "$(json name "$2")" $PUB/v1/keys; }
dbq(){ python3 -c 'import sqlite3,sys;c=sqlite3.connect("file:"+sys.argv[1]+"?mode=ro",uri=True);r=c.execute(sys.argv[2],sys.argv[3:]).fetchone();print(r[0] if r else "")' $T/data/huijian.db "$@"; }

echo "[1] 管理后台登录；0.9.0 删掉的页面"
J=$T/cookies; TOK=$(cat $T/data/admin.token)
chk "未登录跳转登录页" "$(curl -s -o /dev/null -w '%{http_code}' $ADM/)" 303
chk "错误令牌" "$(curl -s -o /dev/null -w '%{redirect_url}' -d token=wrong $ADM/login | grep -c 'e=1')" 1
curl -s -c $J -o /dev/null -d "token=$TOK" $ADM/login
chk "登录后首页" "$(curl -s -b $J -o /dev/null -w '%{http_code}' $ADM/)" 200
chk "伪造 Origin 的 POST 被拒" "$(curl -s -b $J -o /dev/null -w '%{http_code}' -H 'Origin: http://evil.com' -d count=1 $ADM/invites)" 403
chk "后台不能建账号（POST /accounts 405，账号只能注册产生）" "$(curl -s -b $J -o /dev/null -w '%{http_code}' -H "Origin: $ADM" -d username=后台建的 -d password=admin-made-01 $ADM/accounts) $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOK" "${CJ[@]}" -d '{"username":"x","password":"admin-made-01"}' $ADM/api/accounts)" "405 404"
chk "全新部署不预建账号" "$(dbq 'select count(*) from users')" 0
for p in "GET /messages" "GET /keys" "GET /devices" "POST /pair" "POST /pushkeys" "POST /test" "GET /switch?u=1" "GET /att/a_x"; do
  chk "后台已删除 ${p%% *} ${p#* }（404）" "$(curl -s -b $J -o /dev/null -w '%{http_code}' -X ${p%% *} -H "Origin: $ADM" "$ADM${p#* }")" 404; done

echo "[2] 账号：服务器上生成邀请码 → 命令行注册（注册即登录、即开启加密）→ 客户端建 pushkey"
IC0=$(inv -note 自己)
[[ $IC0 =~ ^[2-9A-HJKMNP-Z]{10}$ ]] && ok "命令行生成邀请码" || ng "生成邀请码失败: $IC0"
OLDREG=$(curl -s "${CJ[@]}" -d "$(json username owner1 password pass-owner-1 name x platform macos invite_code "$IC0")" $PUB/v1/register)
chk "旧客户端注册（密码原文、不带加密字段）返回 400，邀请码不扣" "$(echo "$OLDREG" | pj 'd["code"], d["error"]') $(dbq 'select used from invites where code=?' $IC0)" "400 请更新回笺客户端后注册（新版注册时同时开启端到端加密） 0"
DT=$(reg owner1 pass-owner-1 "$IC0" macos test-mac)
[[ $DT == DT_* ]] && ok "注册拿到设备 token" || ng "注册失败: $DT"
H="Authorization: Bearer $DT"
DID=$(curl -s -H "$H" $PUB/v1/me | pj 'd["device_id"]')
chk "第一个注册的人就是第一个账号（#1）" "$(dbq 'select id from users where username=?' owner1)" 1
chk "/v1/e2e：注册时就开启了加密、没有「只接受加密消息」" "$(curl -s -H "$H" $PUB/v1/e2e | pj 'd["enabled"], d["e2e_only"], d["server_seal"], d["plain_messages"], d["auth_key"]')" "True False True 0 True"
chk "注册后不能再 setup（409）" "$(curl -s -o /dev/null -w '%{http_code}' -X POST "${CJ[@]}" -H "$H" -d "$($TOOL e2e-setup pass-owner-1 | tail -1)" $PUB/v1/e2e/setup)" 409
PK=$(newkey $DT 本机测试 | pj 'd["key"]')
[[ $PK == PK_* ]] && ok "客户端新建 pushkey" || ng "pushkey 创建失败"
chk "旧协议（密码原文）登录返回 426" "$(curl -s -o /dev/null -w '%{http_code}' "${CJ[@]}" -d "$(json username owner1 password pass-owner-1)" $PUB/v1/login)" 426
EPUB=$(curl -s -H "$H" $PUB/v1/e2e | pj '[k["pub"] for k in d["keys"] if k["active"]][0]')
SENDKEY="$PK.e2e.$EPUB"
PC=$(curl -s -X POST -H "$H" $PUB/v1/pair-codes | pj 'd["code"]')
RP=$(curl -s "${CJ[@]}" -d "$(json code "$PC" name test-phone platform ios)" $PUB/v1/pair)
DTP=$(echo "$RP" | pj 'd.get("token","")'); DIDP=$(echo "$RP" | pj 'd.get("device_id","")')
[[ $DTP == DT_* ]] && ok "客户端生成的配对码：另一台设备加入（可选方式）" || ng "配对失败: $RP"
chk "配对码不能重复使用" "$(curl -s -o /dev/null -w '%{http_code}' -X POST "${CJ[@]}" -d "$(json code "$PC")" $PUB/v1/pair)" 403

echo "[4] 打开实时流（后台）"
curl -sN -H "$H" "$PUB/v1/stream?since=0" > $T/stream.txt & SP=$!
sleep 0.5

echo "[5] 发送（普通 pushkey 由服务器代加密；加密发送密钥在本机加密）"
chk "PushDeer 兼容 GET" "$(curl -s -G $PUB/message/push --data-urlencode "pushkey=$PK" --data-urlencode 'text=训练开始' | pj 'd["code"]')" 0
chk "表单 POST + markdown" "$(curl -s $PUB/message/push -d pushkey=$PK -d text=标题 --data-urlencode 'desp=**粗体** 正文' -d type=markdown -d priority=4 | pj 'd["code"]')" 0
head -c 3000000 /dev/urandom > $T/big.bin
python3 - "$T/pic.png" <<'PY'
import sys,zlib,struct
w=h=64
def chunk(t,d): return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
rows=b''.join(b'\x00'+b''.join(bytes([x*4,y*4,128]) for x in range(w)) for y in range(h))
open(sys.argv[1],'wb').write(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b''))
PY
OUT=$(./bin/huijian push -u $PUB -k $PK -p 4 -topic train -thread exp42 -d "val_loss 0.231" -f $T/pic.png -f $T/big.bin "exp42 完成")
echo "    $OUT"; [[ $OUT == 已发送* ]] && ok "CLI 带 2 个附件发送（服务器代加密）" || ng "CLI 发送失败"
OUT=$(./bin/huijian push -u $PUB -k "$SENDKEY" -topic train "本机加密的消息")
[[ $OUT == 已发送* ]] && ok "CLI 用加密发送密钥发送（本机加密）" || ng "加密发送失败: $OUT"
chk "错误 pushkey 被拒" "$(curl -s -o /dev/null -w '%{http_code}' "$PUB/message/push?pushkey=PK_wrong&text=x")" 403
chk "缺少 text 被拒" "$(curl -s -o /dev/null -w '%{http_code}' "$PUB/message/push?pushkey=$PK")" 400
chk "非法 priority 被拒" "$(curl -s -o /dev/null -w '%{http_code}' "$PUB/message/push?pushkey=$PK&text=x&priority=9")" 400
chk "加密发送密钥不带信封被拒（不让人以为发出去的是加密的）" "$(curl -s -o /dev/null -w '%{http_code}' "$PUB/message/push?pushkey=$SENDKEY&text=x")" 400

echo "[6] 拉取历史并解密"
msgs $DT since=0 > $T/msgs.json
chk "历史消息条数" "$(pj 'len(d["messages"])' < $T/msgs.json)" 4
chk "全部是密文：服务器上 type=e2e、只有占位文字，前 3 条由服务器代加密" "$(curl -s -H "$H" "$PUB/v1/messages?since=0" | pj '[(m["type"], m["text"][:2], m.get("sealed","")) for m in d["messages"]]')" "[('e2e', '🔒 ', 'server'), ('e2e', '🔒 ', 'server'), ('e2e', '🔒 ', 'server'), ('e2e', '🔒 ', '')]"
chk "服务器不再带 doc / preview（Markdown 由客户端解析）" "$(curl -s -H "$H" "$PUB/v1/messages?since=0" | pj 'sum(1 for m in d["messages"] if m.get("doc") or m.get("preview"))')" 0
chk "解密：Markdown 正文、类型、优先级" "$(pj '[(m["desp"], m["type"], m["priority"]) for m in d["messages"] if m["text"]=="标题"][0]' < $T/msgs.json)" "('**粗体** 正文', 'markdown', 4)"
chk "解密：附件真实名字和大小在信封里，服务器上只有 encrypted-N.bin" "$(pj '[(a["name"],a["size"]) for a in d["messages"][2]["atts"]], [a["name"] for a in d["messages"][2]["attachments"]]' < $T/msgs.json)" "[('pic.png', $(stat -f%z $T/pic.png 2>/dev/null || stat -c%s $T/pic.png)), ('big.bin', 3000000)] ['encrypted-1.bin', 'encrypted-2.bin']"
chk "解密：本机加密的消息" "$(pj 'd["messages"][3]["text"], d["messages"][3]["decrypted"]' < $T/msgs.json)" "本机加密的消息 True"
chk "未带 token 被拒" "$(curl -s -o /dev/null -w '%{http_code}' $PUB/v1/messages)" 401

echo "[7] 实时流"
sleep 0.5; kill $SP 2>/dev/null
chk "流中收到 4 条 message 事件" "$(grep -c '^event: message' $T/stream.txt)" 4
chk "流里也只有密文" "$(grep -c '训练开始\|粗体\|val_loss' $T/stream.txt)" 0

echo "[7b] 长轮询"
MAXID=$(curl -s -H "$H" "$PUB/v1/messages?limit=1" | pj 'd["messages"][-1]["id"]')
( sleep 1; curl -s -o /dev/null "$PUB/message/push?pushkey=$PK&text=longpoll" ) &
LP=$(curl -s -w ' %{time_total}' -H "$H" "$PUB/v1/messages?since=$MAXID&wait=10")
LPT=${LP##* }; LPB=${LP% *}
chk "长轮询在新消息到达时立即返回" "$(echo "$LPB" | $TOOL e2e-open $KEYS | pj '[m["text"] for m in d["messages"]]')" "['longpoll']"
python3 -c "import sys;sys.exit(0 if 0.8<$LPT<3 else 1)" && ok "返回耗时 ${LPT}s（约等于发送延迟 1s）" || ng "返回耗时异常 ${LPT}s"
LP=$(curl -s -w ' %{time_total}' -H "$H" "$PUB/v1/messages?since=$((MAXID+1))&wait=2")
python3 -c "import sys;sys.exit(0 if 1.9<${LP##* }<3 else 1)" && ok "无消息时 wait=2 超时返回空列表" || ng "超时行为异常: $LP"

echo "[7c] 幂等键、outbox（带附件）与并发补发"
I1=$(curl -s "$PUB/message/push" -d pushkey=$PK -d text=idem-test -d idem=fixed-key-1 | pj 'd["content"]["result"][0]')
I2=$(curl -s "$PUB/message/push" -d pushkey=$PK -d text=idem-test -d idem=fixed-key-1 | pj 'd["content"]["result"][0]')
chk "相同幂等键返回同一消息 id" "$I2" "$I1"
chk "空结果返回 [] 而不是 null" "$(curl -s -H "$H" "$PUB/v1/messages?since=999999" | pj 'd["messages"]')" "[]"
OLDHOME=$HOME; export HOME=$PWD/$T/home; mkdir -p $HOME
echo "OUTBOX-ATT" > $T/att-old.txt
./bin/huijian push -u http://127.0.0.1:1 -k $PK "outbox-1" >/dev/null 2>&1
./bin/huijian push -u http://127.0.0.1:1 -k $PK -f $T/att-old.txt "outbox-2" >/dev/null 2>&1
./bin/huijian push -u http://127.0.0.1:1 -k "$SENDKEY" -f $T/att-old.txt "outbox-3" >/dev/null 2>&1
rm $T/att-old.txt   # 原文件删掉也能补发（outbox 里有副本）
chk "3 条进入 outbox（两条带附件）" "$(ls $HOME/.huijian/outbox | wc -l | tr -d ' ')" 3
for f in $HOME/.huijian/outbox/*/job.json; do python3 -c "import json,sys;p=sys.argv[1];j=json.load(open(p));j['urls']=['$PUB'];json.dump(j,open(p,'w'))" $f; done
BEFORE=$(curl -s -H "$H" "$PUB/v1/messages?limit=1" | pj 'd["messages"][-1]["id"]')
FP=""; for i in 1 2 3 4 5; do ./bin/huijian flush >/dev/null 2>&1 & FP="$FP $!"; done; wait $FP
chk "5 个进程并发补发，outbox 清空，没有进 failed/" "$(ls $HOME/.huijian/outbox | grep -vc failed) $(ls $HOME/.huijian/outbox/failed 2>/dev/null | wc -l | tr -d ' ')" "0 0"
msgs $DT since=$BEFORE > $T/ob.json
chk "并发补发后服务端只多 3 条（无重复）" "$(pj 'sorted(m["text"] for m in d["messages"])' < $T/ob.json)" "['outbox-1', 'outbox-2', 'outbox-3']"
chk "补发的附件名不带 outbox 的序号前缀（普通 key / 加密发送密钥）" "$(pj 'sorted(m["atts"][0]["name"] for m in d["messages"] if m.get("atts"))' < $T/ob.json)" "['att-old.txt', 'att-old.txt']"
export HOME=$OLDHOME

echo "[8] 附件下载 / 断点续传 / 校验 / 解密"
read AID ASHA AKEY < <(pjx 'a=d["messages"][2]["attachments"][1]; print(a["id"],a["sha256"],d["messages"][2]["atts"][1]["key"])' < $T/msgs.json)
curl -s -H "$H" -o $T/dl.bin -D $T/dl.h "$PUB/v1/att/$AID"
chk "完整下载 sha256 与服务器记录一致（密文）" "$(shasum -a 256 $T/dl.bin | cut -d' ' -f1)" "$ASHA"
grep -qi 'content-disposition: attachment' $T/dl.h && ok "Content-Disposition 为 attachment" || ng "缺少 Content-Disposition"
chk "Range 请求返回 206" "$(curl -s -H "$H" -H 'Range: bytes=1000000-' -o $T/part.bin -w '%{http_code}' "$PUB/v1/att/$AID")" 206
head -c 1000000 $T/dl.bin > $T/joined.bin; cat $T/part.bin >> $T/joined.bin
chk "断点续传拼接后 sha256 一致" "$(shasum -a 256 $T/joined.bin | cut -d' ' -f1)" "$ASHA"
chk "用信封里的钥匙解密，和原文件一致" "$($TOOL e2e-file "$AKEY" < $T/dl.bin | shasum -a 256 | cut -d' ' -f1)" "$(shasum -a 256 $T/big.bin | cut -d' ' -f1)"
chk "不存在的附件 404" "$(curl -s -o /dev/null -w '%{http_code}' -H "$H" $PUB/v1/att/a_nope)" 404

echo "[9] 移除设备（客户端自助）"
chk "移除本账号的另一台设备" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$H" $PUB/v1/devices/$DIDP/revoke)" 200
chk "移除后 token 失效" "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $DTP" $PUB/v1/messages)" 401

echo "[10] 日志中不应出现 pushkey；数据库和附件目录里没有明文"
grep -q "$PK" $T/hub.log && ng "日志泄露了 pushkey" || ok "日志未记录 pushkey"
# 频道（topic）和 thread 是路由用的元数据，按设计不加密；标题、正文、附件名都在信封里
chk "数据库（含 WAL）里没有明文标题和正文" "$(for s in 训练开始 粗体 val_loss outbox-2 本机加密; do cat $T/data/huijian.db* | grep -ac "$s"; done | paste -sd+ - | bc)" 0
chk "附件目录里没有明文文件名" "$(find $T/data/files -name 'pic.png' -o -name 'big.bin' -o -name '*att-old*' | wc -l | tr -d ' ')" 0

echo "[11] 管理后台：记住登录 / 命令行一次性链接 / 页面渲染；客户端不能进入后台"
J2=$T/cookies2; curl -s -c $J2 -o /dev/null -d "token=$TOK" -d remember=1 $ADM/login
grep -q "huijian_admin" $J2 && ok "记住登录：拿到持久 cookie" || ng "没有持久 cookie"
kill $HUB; wait $HUB 2>/dev/null
RKEY=$T/release.key; RPUB=$(./bin/huijian release-key $RKEY)
env HUIJIAN_DATA=$T/data HUIJIAN_PUBLIC_ADDR=127.0.0.1:18790 HUIJIAN_ADMIN_ADDR=127.0.0.1:18791 HUIJIAN_ADMIN_DENY=10.0.0.1 \
  HUIJIAN_UPDATE_PUBKEY=$RPUB ./bin/huijian hub >> $T/hub.log 2>&1 &
HUB=$!; trap 'kill $HUB 2>/dev/null' EXIT
for i in $(seq 1 30); do curl -sf $PUB/healthz >/dev/null && break; sleep 0.2; done
J=$J2
chk "服务重启后记住的会话仍有效" "$(curl -s -b $J2 -o /dev/null -w '%{http_code}' $ADM/)" 200
for pg in / /accounts /invites /settings; do
  chk "页面 $pg 渲染" "$(curl -s -b $J2 -o /dev/null -w '%{http_code}' "$ADM$pg")" 200; done
grep -q "模板渲染失败" $T/hub.log && ng "日志中有模板错误：$(grep 模板渲染失败 $T/hub.log | head -1)" || ok "无模板渲染错误"
chk "后台页面不出现消息内容、pushkey、设备名" "$(for pg in / /accounts /invites /settings; do curl -s -b $J2 "$ADM$pg"; done | grep -c "$PK\|test-mac\|训练开始")" 0
LINK=$(HUIJIAN_DATA=$T/data HUIJIAN_ADMIN_ADDR=127.0.0.1:18791 ./bin/huijian admin-link | tail -1)
J3=$T/cookies3
chk "命令行一次性链接登录" "$(curl -s -c $J3 -o /dev/null -w '%{redirect_url}' "$LINK" | grep -c 'f=')" 1
chk "链接登录后可访问" "$(curl -s -b $J3 -o /dev/null -w '%{http_code}' $ADM/)" 200
chk "链接不能重复使用" "$(curl -s -o /dev/null -w '%{redirect_url}' "$LINK" | grep -c 'e=link')" 1
LINK4=$(HUIJIAN_DATA=$T/data HUIJIAN_ADMIN_ADDR=127.0.0.1:18791 ./bin/huijian admin-link | tail -1)
J4=$T/cookies4; curl -s -c $J4 -o /dev/null "$LINK4"
for p in "POST /v1/admin/link" "GET /v1/storage" "POST /v1/storage/backup"; do
  chk "客户端进入后台 / 服务器级接口已删除：${p}（404）" "$(curl -s -o /dev/null -w '%{http_code}' -X ${p%% *} -H "$H" "$PUB${p#* }")" 404; done
chk "/v1/me：can_admin 恒为 false，admin_url 为空" "$(curl -s -H "$H" $PUB/v1/me | pj 'd["can_admin"], repr(d["admin_url"])')" "False ''"
# 精确注销 J4 的会话（列表按 last_seen 排序，同一秒内顺序不确定，不能取第一条）
H4=$(awk '$6=="huijian_admin"{print $7}' $J4 | tail -1 | tr -d '\n' | shasum -a 256 | cut -d' ' -f1)
chk "设置页列出 J4 的会话" "$(curl -s -b $J2 $ADM/settings | grep -c "/sessions/$H4/revoke")" 1
curl -s -b $J2 -o /dev/null -H "Origin: $ADM" -X POST "$ADM/sessions/$H4/revoke"
N_OK=0; for j in $J2 $J3 $J4; do [ "$(curl -s -b $j -o /dev/null -w '%{http_code}' $ADM/)" = 200 ] && N_OK=$((N_OK+1)); done
chk "注销一个会话后剩 2 个有效" "$N_OK" 2
chk "被注销的是 J4" "$(curl -s -b $J4 -o /dev/null -w '%{http_code}' $ADM/)" 303

echo "[12] 客户端应用内更新"
DT2=$DT; DID2=$DID
chk "release-pubkey 与生成时一致" "$(./bin/huijian release-pubkey $RKEY)" "$RPUB"
./bin/huijian release-key $RKEY >/dev/null 2>&1 && ng "release-key 覆盖了已有私钥" || ok "release-key 不覆盖已有私钥"
head -c 300000 /dev/urandom > $T/pkg10.zip; PSHA=$(shasum -a 256 $T/pkg10.zip | cut -d' ' -f1)
chk "无令牌发布 401" "$(curl -s -o /dev/null -w '%{http_code}' -F platform=macos -F version=1 -F build=1 -F file=@$T/pkg10.zip $ADM/api/releases)" 401
chk "Cookie 会话不能调用发布 API" "$(curl -s -b $J2 -o /dev/null -w '%{http_code}' -F platform=macos -F file=@$T/pkg10.zip $ADM/api/releases)" 401
export HUIJIAN_ADMIN_URL=$ADM HUIJIAN_ADMIN_TOKEN=$TOK
./bin/huijian release -key $RKEY -version 0.9.0 -build 10 -notes "第一版" $T/pkg10.zip > $T/rel.out 2>&1 && ok "huijian release 上传成功" || ng "上传失败：$(cat $T/rel.out)"
SIG10=$(./bin/huijian release -dry -key $RKEY -version 0.9.0 -build 10 -notes "第一版" $T/pkg10.zip | awk '/^signature/{print $2}')
U=$(curl -s -H "Authorization: Bearer $DT2" "$PUB/v1/update?build=9")
chk "旧版本查到更新 build 10" "$(echo "$U" | pj 'd["update"]["build"]')" 10
chk "返回的签名与发布签名一致" "$(echo "$U" | pj 'd["update"]["signature"]')" "$SIG10"
chk "已是最新时 update 为 null" "$(curl -s -H "Authorization: Bearer $DT2" "$PUB/v1/update?build=10")" '{"update":null}'
chk "未带 token 查询 401" "$(curl -s -o /dev/null -w '%{http_code}' "$PUB/v1/update?build=1")" 401
UURL=$(echo "$U" | pj 'd["update"]["url"]')
chk "下载更新包 sha256 一致" "$(curl -s -H "Authorization: Bearer $DT2" "$PUB$UURL" | shasum -a 256 | cut -d' ' -f1)" "$PSHA"
chk "更新包支持 Range" "$(curl -s -o /dev/null -w '%{http_code}' -H 'Range: bytes=100-199' -H "Authorization: Bearer $DT2" "$PUB$UURL")" 206
chk "长轮询响应带最新构建号" "$(curl -s -D - -o /dev/null -H "Authorization: Bearer $DT2" "$PUB/v1/messages?since=999999&limit=1" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-huijian-latest-build"{print $2}')" 10
R3=$(login owner1 pass-owner-1 phone ios "$(python3 -c 'import hashlib;print(hashlib.sha256(b"e2e-phone-1").hexdigest())')")
DT3=$(echo "$R3" | pj 'd["token"]')
chk "密码登录的新设备拿到加密钥匙（不需要别的设备批准）" "$(echo "$R3" | pj 'd["e2e"]["enabled"], d["e2e"]["password_wrap"][:5]')" "True hjp1."
chk "其他平台查不到 macOS 更新" "$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/update?build=0")" '{"update":null}'
chk "其他平台不能下载 macOS 更新包" "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $DT3" "$PUB$UURL")" 404
# iPhone：GBox 软件源和安装包（不需要登录）
chk "还没有 iOS 版本时软件源 404" "$(curl -s -o /dev/null -w '%{http_code}' $PUB/ios/gbox.appsrc)" 404
head -c 3000 /dev/urandom > $T/ios3.ipa; ISHA=$(shasum -a 256 $T/ios3.ipa | cut -d' ' -f1)
./bin/huijian release -key $RKEY -platform ios -version 0.1.0 -build 3 -notes "iPhone 第一版" $T/ios3.ipa >/dev/null 2>&1 && ok "发布 iOS 版本" || ng "发布 iOS 版本失败"
SRC=$(curl -s $PUB/ios/gbox.appsrc)
chk "软件源列出最新 iOS 版本" "$(echo "$SRC" | pjx 'a=d["appRepositories"][0]; print(a["appType"],a["appVersion"],a["appPackage"].rsplit("/",1)[1])')" "SELF_SIGN 0.1.0 Huijian-0.1.0-3.ipa"
IPA=$(echo "$SRC" | pj 'd["appRepositories"][0]["appPackage"]')
chk "安装包可直接下载且 sha256 一致" "$(curl -s "$IPA" | shasum -a 256 | cut -d' ' -f1)" "$ISHA"
chk "不存在的构建号 404" "$(curl -s -o /dev/null -w '%{http_code}' $PUB/ios/Huijian-0.1.0-99.ipa)" 404
chk "路径穿越被拒绝" "$(curl -s -o /dev/null -w '%{http_code}' "$PUB/ios/..%2F..%2Fhuijian.db")" 404
chk "macOS 版本不能当 iOS 安装包下载" "$(curl -s -o /dev/null -w '%{http_code}' $PUB/ios/Huijian-0.9.0-10.ipa)" 404
chk "iPhone 查到 iOS 更新" "$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/update?build=1" | pj 'd["update"]["build"]')" 3
chk "公开图标" "$(curl -s -o /dev/null -w '%{http_code} %{content_type}' $PUB/icon.png)" "200 image/png"
# Bark 转发设置
BK(){ curl -s -o /dev/null -w '%{http_code}' -X PUT -H "Authorization: Bearer $DT3" "${CJ[@]}" -d "$1" $PUB/v1/bark; }
chk "Bark 地址格式错误 400" "$(BK '{"url":"api.day.app/abc"}')" 400
chk "加密密钥长度不对 400" "$(BK '{"url":"https://api.day.app/AbCd123","cipher_key":"short","cipher_iv":"abcdef9876543210"}')" 400
chk "保存 Bark 地址（加密）" "$(BK '{"url":"https://api.day.app/AbCd123/这里改成你自己的推送内容","cipher_key":"0123456789abcdef0123456789abcdef","cipher_iv":"abcdef9876543210"}')" 200
chk "/v1/me 返回规范化的 Bark 地址" "$(curl -s -H "Authorization: Bearer $DT3" $PUB/v1/me | pj 'd["bark"]["url"], d["bark"]["encrypted"]')" "https://api.day.app/AbCd123 True"
chk "/v1/me 不返回加密密钥" "$(curl -s -H "Authorization: Bearer $DT3" $PUB/v1/me | grep -c 0123456789abcdef)" 0
BK '{"url":"http://127.0.0.1:9/KeyXyz1"}' >/dev/null
chk "Bark 连不上时测试返回 502" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $DT3" $PUB/v1/bark/test)" 502
chk "关闭 Bark 转发" "$(BK '{"url":""}')$(curl -s -H "Authorization: Bearer $DT3" $PUB/v1/me | pj 'd["bark"]')" "200None"
chk "未配置时测试 400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $DT3" $PUB/v1/bark/test)" 400
./bin/huijian release -key $RKEY -version 0.9.0 -build 10 $T/pkg10.zip >/dev/null 2>&1 && ng "重复 build 被接受" || ok "重复 build 被拒绝"
./bin/huijian release -key $RKEY -version 0.8.0 -build 9 $T/pkg10.zip > $T/rel.out 2>&1 && ng "降级 build 被接受" || { grep -q 409 $T/rel.out && ok "降级 build 被拒绝（409）" || ng "降级返回异常：$(cat $T/rel.out)"; }
OKEY=$T/other.key; ./bin/huijian release-key $OKEY >/dev/null
./bin/huijian release -key $OKEY -version 1.0.0 -build 11 $T/pkg10.zip > $T/rel.out 2>&1 && ng "错误私钥签名被接受" || { grep -q "签名校验失败" $T/rel.out && ok "错误私钥签名被拒绝" || ng "异常：$(cat $T/rel.out)"; }
chk "sha256 不符被拒绝" "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOK" -F platform=macos -F version=1.0.0 -F build=12 -F sha256=$(printf '0%.0s' {1..64}) -F signature=$SIG10 -F file=@$T/pkg10.zip $ADM/api/releases)" 400
for b in 11 12 13 14 15; do head -c 1000 /dev/urandom > $T/pkg$b.zip; ./bin/huijian release -key $RKEY -version 0.9.$b -build $b $T/pkg$b.zip >/dev/null 2>&1 || ng "发布 build $b 失败"; done
chk "每个平台只保留最近 5 个版本的文件（macOS 5 个 + iOS 1 个）" "$(ls $T/data/releases | wc -l | tr -d ' ')" 6
curl -s -o /dev/null -H "Authorization: Bearer $DT2" -H "X-Huijian-Client: macos 0.9.14 (14)" "$PUB/v1/me"
chk "概览按平台和版本统计设备（只有计数）" "$(curl -s -b $J2 $ADM/ | grep -c '0.9.14 × 1')" 1
chk "设置页列出 6 个版本" "$(curl -s -b $J2 $ADM/settings | grep -oE '/releases/[0-9]+/delete' | wc -l | tr -d ' ')" 6
RID=$(curl -s -H "Authorization: Bearer $DT2" "$PUB/v1/update?build=1" | pj 'd["update"]["id"]')
curl -s -b $J2 -o /dev/null -H "Origin: $ADM" -X POST $ADM/releases/$RID/delete
chk "删除最新版后回退到 build 14" "$(curl -s -H "Authorization: Bearer $DT2" "$PUB/v1/update?build=1" | pj 'd["update"]["build"]')" 14
grep -q "模板渲染失败" $T/hub.log && ng "日志中有模板错误" || ok "更新相关页面无模板错误"

echo "[13] 无域名部署：地址自动推导、登录限速"
CK=$(awk '/huijian_admin/{print $7}' $J2 | tail -1)
chk "设置页公网地址以明确的监听地址为准（不被 Host 改写）" "$(curl -s -H "Cookie: huijian_admin=$CK" -H 'Host: 5.6.7.8:18791' $ADM/settings | grep -c 'http://5.6.7.8:18790')" 0
unset HUIJIAN_ADMIN_URL
chk "命令行 admin-link 无法推导时给出占位提示" "$(HUIJIAN_DATA=$T/data HUIJIAN_ADMIN_ADDR=0.0.0.0:18791 ./bin/huijian admin-link | grep -c '<服务器IP>:18791')" 1
chk "配置 PUBLIC_URL 后 admin-link 自动填好主机" "$(HUIJIAN_DATA=$T/data HUIJIAN_ADMIN_ADDR=0.0.0.0:18791 HUIJIAN_PUBLIC_URL=http://9.9.9.9:18790 ./bin/huijian admin-link | grep -c 'http://9.9.9.9:18791/auth/link')" 1
R=""; for i in $(seq 1 8); do R="$R $(curl -s -o /dev/null -w '%{redirect_url}' -d token=wrong $ADM/login)"; done
chk "连续错误登录触发限速" "$(echo "$R" | grep -c 'e=rate')" 1
chk "限速提示渲染" "$(curl -s "$ADM/login?e=rate" | grep -c '尝试太频繁')" 1
chk "已登录会话不受限速影响" "$(curl -s -b $J2 -o /dev/null -w '%{http_code}' $ADM/)" 200
VLINK=$(HUIJIAN_DATA=$T/data HUIJIAN_ADMIN_ADDR=127.0.0.1:18791 ./bin/huijian admin-link | tail -1)
J5=$T/cookies5; curl -s -c $J5 -o /dev/null "$VLINK"
chk "限速期间有效的一次性链接仍能登录（别人乱试锁不住运营方）" "$(curl -s -b $J5 -o /dev/null -w '%{http_code}' $ADM/)" 200
for i in 1 2 3; do RB=$(curl -s -o /dev/null -w '%{redirect_url}' "$ADM/auth/link?t=L_bogus"); done   # 前面的步骤耗时可能回补了令牌，多试几次
chk "限速期间无效链接被限速" "$(echo "$RB" | grep -c 'e=rate')" 1

echo "[14] 设备自助管理：改名、pushkey、时间戳设备 ID"
[[ $DID2 =~ ^d_[0-9]{14}_[0-9a-f]{4}$ ]] && ok "新设备 ID 为时间戳格式（${DID2}）" || ng "设备 ID 格式不对：${DID2}"
AU=(-H "Authorization: Bearer $DT2" "${CJ[@]}")
chk "设备给自己改名" "$(curl -s -X PATCH "${AU[@]}" -d '{"name":"  我的 MacBook Pro \n"}' $PUB/v1/me | pj 'd["name"]')" "我的 MacBook Pro"
chk "空名称被拒绝" "$(curl -s -o /dev/null -w '%{http_code}' -X PATCH "${AU[@]}" -d '{"name":"  "}' $PUB/v1/me)" 400
NK=$(curl -s "${AU[@]}" $PUB/v1/keys | pj 'len(d["keys"])')
[ "$NK" -ge 1 ] && ok "设备列出 pushkey（${NK} 把）" || ng "列出 pushkey 失败"
CK1="my-custom-key-$(date +%s)"
R=$(curl -s "${AU[@]}" -d "{\"name\":\"脚本 A\",\"key\":\"$CK1\"}" $PUB/v1/keys); KID=$(echo "$R" | pj 'd["id"]')
chk "设备新建自定义 key" "$(echo "$R" | pj 'd["key"]')" "$CK1"
chk "自定义 key 可以发送" "$(curl -s -o /dev/null -w '%{http_code}' "$PUB/message/push?pushkey=$CK1&text=custom")" 200
chk "太短的 key 被拒绝" "$(curl -s -o /dev/null -w '%{http_code}' "${AU[@]}" -d '{"name":"x","key":"short"}' $PUB/v1/keys)" 400
chk "重复的 key 被拒绝（409）" "$(curl -s -o /dev/null -w '%{http_code}' "${AU[@]}" -d "$(json name x key "$CK1")" $PUB/v1/keys)" 409
CK2="renamed-key-$(date +%s)-xyz"
UPR=$(curl -s -X PATCH "${AU[@]}" -d "$(json name "脚本 A2" key "$CK2")" $PUB/v1/keys/$KID)
chk "设备改名并更换 key（返回更新后的这一把）" "$(echo "$UPR" | pj 'd["name"],d["key"]')" "脚本 A2 $CK2"
chk "旧 key 立即失效" "$(curl -s -o /dev/null -w '%{http_code}' "$PUB/message/push?pushkey=$CK1&text=old")" 403
chk "新 key 可以发送" "$(curl -s -o /dev/null -w '%{http_code}' "$PUB/message/push?pushkey=$CK2&text=new")" 200
curl -s -o /dev/null -X POST "${AU[@]}" $PUB/v1/keys/$KID/revoke
chk "设备吊销后不能再发送" "$(curl -s -o /dev/null -w '%{http_code}' "$PUB/message/push?pushkey=$CK2&text=x")" 403
chk "已吊销的不能再修改" "$(curl -s -o /dev/null -w '%{http_code}' -X PATCH "${AU[@]}" -d '{"name":"y"}' $PUB/v1/keys/$KID)" 400
chk "不能改别人的 / 不存在的 key" "$(curl -s -o /dev/null -w '%{http_code}' -X PATCH "${AU[@]}" -d '{"name":"y"}' $PUB/v1/keys/999999)" 404
chk "未带 token 不能列出 key" "$(curl -s -o /dev/null -w '%{http_code}' $PUB/v1/keys)" 401
chk "本账号的任何设备都能管理 key" "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $DT3" $PUB/v1/keys)" 200
chk "吊销不存在的 key 返回 404" "$(curl -s -o /dev/null -w '%{http_code}' -X POST "${AU[@]}" $PUB/v1/keys/999999/revoke)" 404
LONG=$(python3 -c 'print("鸿"*40)')
LCODE=$(curl -s -X POST -H "Authorization: Bearer $DT3" $PUB/v1/pair-codes | pj 'd["code"]')
chk "配对时超长中文名按字符截断（不产生非法 UTF-8）" "$(curl -s -X POST "${CJ[@]}" -d "$(json code "$LCODE" name "$LONG" platform macos)" $PUB/v1/pair | pj 'len(d["name"])')" 40

echo "[15] 版本协商 / 账号 / 设备身份"
INFO=$(curl -s $PUB/v1/info)
chk "/v1/info：版本、功能清单、注册模式（新部署默认需要邀请码）" "$(echo "$INFO" | pj 'd["name"], all(x in [f["id"] for f in d["features"]] for x in ("account","admin.accounts","push.e2e","register.invite")), d["register_open"], d["register"]')" "huijian True False invite"
chk "响应头带 X-Huijian-Server" "$(curl -sI $PUB/healthz | grep -ci '^x-huijian-server: ')" 1
chk "不存在的接口返回非 JSON 404（客户端据此判断服务端较旧）" "$(curl -s $PUB/v1/no-such | head -c 9)" "not found"
chk "已开启加密的账号改密码要走新协议（426）" "$(curl -s -o /dev/null -w '%{http_code}' "${CJ[@]}" -H "Authorization: Bearer $DT3" -d '{"username":"owner1","password":"another-pass","current_password":"pass-owner-1"}' $PUB/v1/account/credentials)" 426
chk "改用户名要核对当前凭证" "$(curl -s -o /dev/null -w '%{http_code}' "${CJ[@]}" -H "Authorization: Bearer $DT3" -d "$(json username owner2 current_auth_key "$($TOOL e2e-authkey wrong-pass 00112233445566778899aabbccddeeff)")" $PUB/v1/account/credentials)" 403
FP=$(python3 -c 'import hashlib;print(hashlib.sha256(b"e2e-mac-2").hexdigest())')
R1=$(login OWNER1 pass-owner-1 笔记本 macos "$FP")
LID=$(echo "$R1" | pj 'd["device_id"]'); LT1=$(echo "$R1" | pj 'd["token"]')
chk "用户名不区分大小写登录，得到设备 token" "$(echo "$R1" | pj 'd["token"][:3], d["reused"]')" "DT_ False"
R2=$(login owner1 pass-owner-1 笔记本 macos "$FP")
chk "同一台设备再次登录：沿用原设备记录" "$(echo "$R2" | pj 'd["device_id"], d["reused"]')" "$LID True"
chk "旧 token 作废" "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $LT1" $PUB/v1/me)" 401
sleep 7   # 配对接口按 IP 限速（每分钟 10 次、最多连发 5 次）
LCODE2=$(curl -s -X POST -H "Authorization: Bearer $DT3" $PUB/v1/pair-codes | pj 'd["code"]')
R3=$(curl -s "${CJ[@]}" -d "$(json code "$LCODE2" name 另一个名字 platform macos fingerprint "$FP")" $PUB/v1/pair)
LT3=$(echo "$R3" | pj 'd["token"]')
chk "用配对码重新配对同一台设备：仍是同一条记录，名称不变" "$(curl -s -H "Authorization: Bearer $LT3" $PUB/v1/me | pj 'd["device_id"], d["name"]')" "$LID 笔记本"
ACC=$(curl -s -H "Authorization: Bearer $LT3" $PUB/v1/account)
chk "/v1/account 列出配对记录（密码 2 次 + 配对码 1 次）" "$(echo "$ACC" | pj '[(x["pair_count"], [p["method"] for p in x["pairings"]]) for x in d["devices"] if x["current"]][0]')" "(3, ['code', 'password', 'password'])"
chk "密码错误被拒绝" "$(curl -s -o /dev/null -w '%{http_code}' "${CJ[@]}" -d "$(json username owner1 auth_key "$($TOOL e2e-authkey wrong-pass 00112233445566778899aabbccddeeff)")" $PUB/v1/login)" 403

echo "[16] 注册模式与邀请码（账号只能注册产生）"
chk "需要邀请码：没带 403" "$(reg 自助0 self-pass-1)" "403 这个服务器注册需要邀请码，请向管理员索取"
F=$(form /invites -d count=2 -d uses=1 -d days=7 --data-urlencode "note=脚本测试")
CODES=$(python3 -c 'import sys,urllib.parse as u;print(" ".join(u.parse_qs(u.urlparse(sys.argv[1]).query)["new"][0].split(",")))' "$F")
read IC1 IC2 <<< "$CODES"
[[ $IC1 =~ ^[2-9A-HJKMNP-Z]{10}$ ]] && ok "后台批量生成邀请码（${IC1}）" || ng "生成邀请码失败: $F"
chk "邀请码注册（不区分大小写）" "$(reg 自助1 self-pass-1 "$(echo $IC1 | tr A-Z a-z)" | cut -c1-3)" DT_
chk "单次邀请码再用：已用完" "$(reg 自助2 self-pass-1 $IC1)" "403 邀请码已用完"
chk "无效邀请码" "$(reg 自助2 self-pass-1 ZZZZZZZZZZ)" "403 邀请码无效，请检查是否输错"
form /invites/$IC2/revoke >/dev/null
sleep 7   # 邀请码注册和配对共用按 IP 的限速（每分钟 10 次、最多连发 5 次）
chk "作废的邀请码" "$(reg 自助2 self-pass-1 $IC2)" "403 邀请码已作废"
chk "邀请码页列出使用者和状态" "$(curl -s -b $J2 $ADM/invites | grep -c "自助1\|已作废")" 2
IC3=$(curl -s -H "Authorization: Bearer $TOK" "${CJ[@]}" -d '{"count":1,"uses":2,"note":"命令行"}' $ADM/api/invites | pj 'd["codes"][0]')   # 令牌接口 /api/invites（和 huijian invite new 一样）
sleep 7
chk "命令行生成的码可以注册" "$(reg 自助3 self-pass-1 $IC3 | cut -c1-3)" DT_
chk "命令行列出邀请码" "$(HUIJIAN_DATA=$T/data HUIJIAN_ADMIN_ADDR=127.0.0.1:18791 ./bin/huijian invite list | grep -cE "^$IC3 +ok +1/2 ")" 1
chk "没有建号命令" "$(./bin/huijian account add x </dev/null >/dev/null 2>&1; echo $?) $(./bin/huijian 2>&1 | grep -c 'account add')" "2 0"
form /accounts/register -d mode=open >/dev/null
chk "开放注册：不用邀请码" "$(reg 自助4 self-pass-1 | cut -c1-3)" DT_
chk "用户名重复返回 409" "$(reg 自助4 self-pass-1)" "409 这个用户名已被使用"
chk "注册时用户名不合法返回 400（不是 500）" "$(reg a/b self-pass-1 | cut -c1-3)" 400
OUTR=$($TOOL e2e-register 接口注册 raw-pass-01 "" macos 接口); echo "$OUTR" | head -1 >> $KEYS
RR=$(curl -s "${CJ[@]}" -d "$(echo "$OUTR" | tail -1)" $PUB/v1/register)
chk "直接调 /v1/register（请求体由 e2e-register 生成）：返回 token 和已开启的加密" "$(echo "$RR" | pj 'd["token"][:3], d["reused"], d["e2e"]["enabled"], d["e2e"]["password_wrap"][:5]')" "DT_ False True hjp1."
chk "旧客户端注册 400" "$(curl -s -o /dev/null -w '%{http_code}' "${CJ[@]}" -d "$(json username 旧客户端 password self-pass-1 name x platform macos)" $PUB/v1/register)" 400
form /accounts/register -d mode=closed >/dev/null
chk "关闭注册：403" "$(reg 自助5 self-pass-1 $IC3)" "403 这个服务器没有开放注册，请联系管理员"
form /accounts/register -d mode=invite >/dev/null
# 家人：注册即开启加密，马上就能收消息
sleep 7
FT=$(reg 家人 family-pass-1 "$(inv -note 家人)" macos "家人的 Mac"); FID=$(curl -s -H "Authorization: Bearer $FT" $PUB/v1/me | pj 'd["device_id"]')
chk "新账号不预置 pushkey，也看不到别人的 key" "$(curl -s -H "Authorization: Bearer $FT" $PUB/v1/keys | pj 'd["keys"]')" "[]"
FKEY=$(newkey $FT default | pj 'd["key"]')
curl -s -o /dev/null "$PUB/message/push?pushkey=$FKEY&text=给家人"
chk "注册后马上能收消息，只投递给所属账号" "$(msgs $FT since=0 | pj '[m["text"] for m in d["messages"]]')" "['给家人']"
FK2=$(newkey $FT 临时 | pj 'd["id"], d["key"]' | tr -d "(),'")
read FK2ID FK2KEY <<< "$FK2"
curl -s -o /dev/null "$PUB/message/push?pushkey=$FK2KEY&text=删除前发的"
chk "未吊销的 pushkey 不能删除" "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer $FT" $PUB/v1/keys/$FK2ID)" 409
curl -s -o /dev/null -X POST -H "Authorization: Bearer $FT" $PUB/v1/keys/$FK2ID/revoke
chk "吊销后可以删除，列表里不再出现" "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer $FT" $PUB/v1/keys/$FK2ID) $(curl -s -H "Authorization: Bearer $FT" $PUB/v1/keys | pj '[k["name"] for k in d["keys"]]')" "204 ['default']"
chk "删除 pushkey 后历史消息保留" "$(msgs $FT since=0 | pj '"删除前发的" in [m["text"] for m in d["messages"]]')" True
chk "不能删除别的账号的 pushkey" "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer $FT" $PUB/v1/keys/1)" 404
chk "其他账号收不到" "$(msgs $LT3 since=0 | pj '"给家人" in [m["text"] for m in d["messages"]]')" False
reg "  Alex   Chen " space-pass-1 "$(inv)" >/dev/null
chk "用户名中间可以有空格；登录时不区分大小写、空格数量" "$(login "alex chen" space-pass-1 x test | pj '"token" in d')" True
chk "账号页：空格合并后保存；注册的账号都是已加密，没有「未加密（旧账号）」" "$(curl -s -b $J2 $ADM/accounts | python3 -c 'import sys;s=sys.stdin.read();print("<b>Alex Chen</b>" in s, "<b>家人</b>" in s, "未加密（旧账号" in s, "新建账号" in s)')" "True True False False"
FUID=$(dbq "select id from users where username=?" 家人)
form /accounts/$FUID/disable -d on=1 >/dev/null
chk "停用账号后设备被拒绝" "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $FT" $PUB/v1/me)" 403
chk "停用账号后 pushkey 不能发送" "$(curl -s -o /dev/null -w '%{http_code}' "$PUB/message/push?pushkey=$FKEY&text=x")" 403
form /accounts/$FUID/disable -d on=0 >/dev/null
chk "重新启用后恢复" "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $FT" $PUB/v1/me)" 200
chk "第一个账号不能停用" "$(flash "$(form /accounts/1/disable -d on=1)")" "第一个账号接收服务器自己的通知（备份失败等），不能停用"

echo "[17] 接收规则 / 在用设备（主账号：LT3 = 笔记本，DT3 = 手机）"
KA=$(newkey $LT3 告警); KAID=$(echo "$KA" | pj 'd["id"]'); KAKEY=$(echo "$KA" | pj 'd["key"]')
KB=$(newkey $LT3 日常); KBID=$(echo "$KB" | pj 'd["id"]'); KBKEY=$(echo "$KB" | pj 'd["key"]')
curl -s -o /dev/null -X PUT "${CJ[@]}" -H "Authorization: Bearer $LT3" -d '{"mode":"off"}' $PUB/v1/subscriptions/$KAID
curl -s -o /dev/null -X PUT "${CJ[@]}" -H "Authorization: Bearer $LT3" -d '{"mode":"silent"}' $PUB/v1/subscriptions/$KBID
chk "非法 mode 被拒绝" "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "${CJ[@]}" -H "Authorization: Bearer $LT3" -d '{"mode":"loud"}' $PUB/v1/subscriptions/$KBID)" 400
chk "不能设置别的账号的 key" "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "${CJ[@]}" -H "Authorization: Bearer $FT" -d '{"mode":"off"}' $PUB/v1/subscriptions/$KBID)" 404
LAST(){ curl -s -H "Authorization: Bearer $1" "$PUB/v1/messages?since=-1&limit=1" | pj 'd["messages"][-1]["id"] if d["messages"] else 0'; }
MAXL=$(LAST $LT3); MAXP=$(LAST $DT3)
curl -s -o /dev/null "$PUB/message/push?pushkey=$KAKEY&text=告警消息&priority=4"
curl -s -o /dev/null "$PUB/message/push?pushkey=$KBKEY&text=日常消息"
curl -s -o /dev/null "$PUB/message/push?pushkey=$KBKEY&text=日常紧急&priority=5"
chk "笔记本：不接收告警，日常静默，紧急照常提醒" "$(msgs $LT3 since=$MAXL | pj '[(m["text"],m.get("silent",False)) for m in d["messages"]]')" "[('日常消息', True), ('日常紧急', False)]"
chk "手机（默认规则）三条都收到且提醒" "$(msgs $DT3 since=$MAXP | pj '[(m["text"],m.get("silent",False),m["pushkey_id"]>0) for m in d["messages"]]')" "[('告警消息', False, True), ('日常消息', False, True), ('日常紧急', False, True)]"
chk "/v1/subscriptions 返回本机规则" "$(curl -s -H "Authorization: Bearer $LT3" $PUB/v1/subscriptions | pj 'sorted((s["name"],s["mode"]) for s in d["subscriptions"] if s["name"] in ("告警","日常")), d["away_silent"]')" "[('告警', 'off'), ('日常', 'silent')] True"
MAXL=$(LAST $LT3)
( sleep 1; curl -s -o /dev/null "$PUB/message/push?pushkey=$KAKEY&text=告警2" ) &
T0=$(date +%s); LP=$(curl -s -H "Authorization: Bearer $LT3" "$PUB/v1/messages?since=$MAXL&wait=3"); T1=$(date +%s)
chk "长轮询：不接收的消息不唤醒，等到超时返回空" "$(echo "$LP" | pj 'len(d["messages"])') $(( T1-T0 >= 3 ))" "0 1"
chk "返回 next_since：不接收的消息也算扫过，游标照样前进" "$(echo "$LP" | pj 'd["next_since"] > '"$MAXL")" True
MAXP=$(LAST $DT3)
chk "上报在用" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $LT3" $PUB/v1/presence)" 204
curl -s -o /dev/null "$PUB/message/push?pushkey=$KBKEY&text=在用时普通"
curl -s -o /dev/null "$PUB/message/push?pushkey=$KBKEY&text=在用时紧急&priority=5"
chk "笔记本在用：手机普通消息静默、紧急照常" "$(msgs $DT3 since=$MAXP | pj '[(m["text"],m.get("silent_reason","")) for m in d["messages"]]')" "[('在用时普通', 'active_elsewhere'), ('在用时紧急', '')]"
curl -s -o /dev/null -X POST -H "Authorization: Bearer $DT3" $PUB/v1/presence
chk "两台都在用：手机照常提醒（不会两边都不响）" "$(msgs $DT3 since=$MAXP | pj '[m.get("silent",False) for m in d["messages"]]')" "[False, False]"

echo "[18] 删除 / 归档消息，多设备同步"
MK=$(newkey $LT3 消息管理测试 | pj 'd["key"]')
CS=$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=-1&limit=1&changes_since=-1" | pj 'd["changes_next"]')
TOPM=$(LAST $DT3)
echo "附件内容" > $T/del.txt
./bin/huijian push -u $PUB -k $MK -f $T/del.txt "要删的带附件" >/dev/null
curl -s -o /dev/null "$PUB/message/push?pushkey=$MK&text=要归档的"
MM=$(msgs $DT3 since=$TOPM)
MID() { echo "$MM" | python3 -c 'import sys,json;print([m["id"] for m in json.load(sys.stdin)["messages"] if m["text"]==sys.argv[1]][0])' "$1"; }
DEL=$(MID 要删的带附件); ARC=$(MID 要归档的)
DATT=$(echo "$MM" | pj '[m for m in d["messages"] if m["text"]=="要删的带附件"][0]["attachments"][0]["id"]')
DBLOB=$(dbq "select blob from attachments where id=?" $DATT)
TOPM2=$(LAST $DT3)
( T0=$(date +%s); R=$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=$TOPM2&wait=20&changes_since=$CS"); echo "$(( $(date +%s)-T0 )) $R" > $T/lp_changes.txt ) &
LPC=$!; sleep 1
OTHER=$(dbq "select max(id) from messages where user_id=?" $FUID)
# 注意：bash 3.2 会对 "$(… "{a,b}" …)" 里的花括号做展开，所以 JSON 先放进变量
BD="{\"ids\":[$DEL,$OTHER]}"; BA="{\"ids\":[$ARC],\"state\":1}"; BX="{\"ids\":[$ARC],\"state\":7}"
chk "删除消息（只删本账号的）" "$(curl -s "${CJ[@]}" -H "Authorization: Bearer $LT3" -d "$BD" $PUB/v1/messages/delete | pj 'd["deleted"]')" 1
wait $LPC
chk "另一台设备的长轮询立即收到删除" "$(python3 -c 'import sys,json;t,r=open(sys.argv[1]).read().split(" ",1);d=json.loads(r);print(int(t)<=3, [(c["id"],c["kind"]) for c in d["changes"]]==[(int(sys.argv[2]),"delete")])' $T/lp_changes.txt $DEL)" "True True"
CS=$(python3 -c 'import sys,json;print(json.loads(open(sys.argv[1]).read().split(" ",1)[1])["changes_next"])' $T/lp_changes.txt)
chk "删除后附件文件和下载链接都没了" "$([ -n "$(find $T/data/files -path "*$DBLOB" 2>/dev/null)" ] && echo 存在 || echo 无) $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $DT3" $PUB/v1/att/$DATT)" "无 404"
chk "其他账号的消息不受影响" "$(dbq "select count(*) from messages where id=?" $OTHER)" 1
chk "归档" "$(curl -s "${CJ[@]}" -H "Authorization: Bearer $LT3" -d "$BA" $PUB/v1/messages/archive | pj 'd["updated"]')" 1
chk "其他设备拿到归档变更，消息本身也带归档状态" "$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=$TOPM&changes_since=$CS" | python3 -c 'import sys,json;d=json.load(sys.stdin);print([(c["id"],c["kind"],c["state"]) for c in d["changes"]]==[(int(sys.argv[1]),"archive",1)], [m.get("archive",0) for m in d["messages"] if m["id"]==int(sys.argv[1])])' $ARC)" "True [1]"
chk "归档状态不合法被拒绝" "$(curl -s -o /dev/null -w '%{http_code}' "${CJ[@]}" -H "Authorization: Bearer $LT3" -d "$BX" $PUB/v1/messages/archive)" 400
chk "对账接口：只有本账号的消息，带归档状态，游标与变更一致" "$(curl -s -H "Authorization: Bearer $DT3" $PUB/v1/messages/state | python3 -c 'import sys,json;d=json.load(sys.stdin);ids={i:a for i,a in d["items"]};print(int(sys.argv[1]) in ids, ids.get(int(sys.argv[2])), int(sys.argv[3]) in ids, d["changes_next"]>0)' $DEL $ARC $OTHER)" "False 1 False True"
chk "没有带 changes_since 的旧客户端不受影响" "$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=$TOPM" | pj '"changes" in d')" False

echo "[19] 频道设置（同账号所有设备共用）"
CS2=$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=-1&limit=1&changes_since=-1" | pj 'd["changes_next"]')
chk "频道改名 + 静音" "$(curl -s -X PATCH "${CJ[@]}" -H "Authorization: Bearer $LT3" -d '{"topic":"chtest","alias":"测试 频道","muted":true}' $PUB/v1/channels | pj 'd["alias"],d["muted"],d["hidden"]')" "测试 频道 True False"
curl -s -o /dev/null -X PATCH "${CJ[@]}" -H "Authorization: Bearer $LT3" -d '{"topic":"chhide","hidden":true}' $PUB/v1/channels
chk "频道排序" "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "${CJ[@]}" -H "Authorization: Bearer $LT3" -d '{"topics":["chhide","chtest"]}' $PUB/v1/channels/order)" 204
chk "其他设备拿到频道设置和变更通知" "$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=$TOPM&changes_since=$CS2" | pj 'sorted({c["kind"] for c in d["changes"]})') $(curl -s -H "Authorization: Bearer $DT3" $PUB/v1/channels | pj 'sorted((c["topic"],c["sort"],c["hidden"]) for c in d["channels"])')" "['channels'] [('chhide', 1, True), ('chtest', 2, False)]"
CHM=$(LAST $DT3)
for x in "chtest&priority=3" "chtest&priority=5" "chhide&priority=5"; do curl -s -o /dev/null "$PUB/message/push?pushkey=$MK&text=ch&topic=$x"; done
chk "静音频道普通消息静默、紧急照常；隐藏频道紧急也静默" "$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=$CHM" | pj '[(m["topic"],m["priority"],m.get("silent_reason","")) for m in d["messages"]]')" "[('chtest', 3, 'channel_muted'), ('chtest', 5, ''), ('chhide', 5, 'channel_hidden')]"
chk "删除频道：全部消息删除，设置清掉" "$(curl -s "${CJ[@]}" -H "Authorization: Bearer $LT3" -d '{"topic":"chtest"}' $PUB/v1/channels/delete | pj 'd["deleted"]') $(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=$CHM" | pj '[m["topic"] for m in d["messages"]]') $(curl -s -H "Authorization: Bearer $DT3" $PUB/v1/channels | pj '[c["topic"] for c in d["channels"]]')" "2 ['chhide'] ['chhide']"
chk "显示名太长被拒绝" "$(curl -s -o /dev/null -w '%{http_code}' -X PATCH "${CJ[@]}" -H "Authorization: Bearer $LT3" -d "$(json topic x alias "$(python3 -c 'print("长"*33)')")" $PUB/v1/channels)" 400

echo "[20] 配对码、移除设备、退出登录"
sleep 7
PC=$(curl -s -X POST -H "Authorization: Bearer $LT3" $PUB/v1/pair-codes | pj 'd["code"]')
RC=$(curl -s "${CJ[@]}" -d "$(json code "$PC" name "新 iPad" platform ios)" $PUB/v1/pair); CT=$(echo "$RC" | pj 'd["token"]'); CID=$(echo "$RC" | pj 'd["device_id"]')
chk "配对码：新设备直接进入本账号，can_admin 恒为 false" "$(curl -s -H "Authorization: Bearer $CT" $PUB/v1/me | pj 'd["account"]["username"], d["can_admin"]')" "owner1 False"
chk "配对码有效期 3 分钟" "$(curl -s -X POST -H "Authorization: Bearer $DT3" $PUB/v1/pair-codes | pj 'd["expires_in"]')" 180
chk "配对码状态：已被哪台设备使用" "$(curl -s -H "Authorization: Bearer $LT3" $PUB/v1/pair-codes/$PC | pj 'd["state"], d["used_by"]')" "used 新 iPad"
PCS=(); for i in 1 2 3; do PCS+=("$(curl -s -X POST -H "Authorization: Bearer $DT3" $PUB/v1/pair-codes | pj 'd.get("code","")')"); done
chk "同一台设备重新生成：旧配对码立即作废，只有最新的有效" "$(curl -s -H "Authorization: Bearer $DT3" $PUB/v1/pair-codes/${PCS[0]} | pj 'd["state"]') $(curl -s -H "Authorization: Bearer $DT3" $PUB/v1/pair-codes/${PCS[2]} | pj 'd["state"]')" "expired waiting"
chk "查不到别的账号的配对码" "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $FT" $PUB/v1/pair-codes/${PCS[2]})" 404
chk "移除本账号的另一台设备" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $DT3" $PUB/v1/devices/$CID/revoke) $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $CT" $PUB/v1/me)" "200 401"
chk "不能移除别的账号的设备" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $FT" $PUB/v1/devices/$LID/revoke)" 404
chk "退出登录后 token 失效" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $LT3" $PUB/v1/logout) $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $LT3" $PUB/v1/me)" "200 401"

echo "[21] 存储与备份（只在后台和服务器上）"
F=$(form /backup/run)
chk "后台「立即备份」" "$(flash "$F")" "已开始备份，稍后刷新页面查看结果"
for i in $(seq 1 30); do ls $T/data/backups/db/ 2>/dev/null | grep -q '^huijian-.*\.db$' && break; sleep 0.2; done
chk "备份目录里有数据库快照" "$(ls $T/data/backups/db/ | grep -c '^huijian-.*\.db$')" 1
chk "设置页有存储与备份卡片" "$(curl -s -b $J2 $ADM/settings | grep -c '存储与备份')" 1
NEWATT=$(curl -s $PUB/message/push -F pushkey=$MK -F "text=附件/路径:测试" -F "file=@tests/e2e_local.sh;filename=../../逃逸.txt" | pj 'd["code"]')
chk "带 ../ 的附件名：真实名字只在信封里，附件目录里没有" "$NEWATT $(msgs $DT3 since=0 | pj '[a["name"] for m in d["messages"] if m["text"]=="附件/路径:测试" for a in m["atts"]]') $(find $T/data -name '*逃逸*' | wc -l | tr -d ' ')" "0 ['逃逸.txt'] 0"
chk "管理后台标签页图标" "$(curl -s -o /dev/null -w "%{http_code} %{content_type}" $ADM/favicon.png) $(curl -s $ADM/login | grep -c "rel=\"icon\"")" "200 image/png 1"

echo "[22] 后台账号操作：注销全部登录、删除账号"
F=$(form /accounts/$FUID/logout)
chk "注销「家人」的全部登录" "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $FT" $PUB/v1/me)" 401
RF=$(login 家人 family-pass-1 "家人的 Mac" macos); FT=$(echo "$RF" | pj 'd["token"]')
chk "注销后用密码重新登录，消息和加密钥匙还在" "$(echo "$RF" | pj 'd["e2e"]["enabled"]') $(msgs $FT since=0 | pj 'len(d["messages"])')" "True 2"
chk "删除账号：用户名不一致不删" "$(flash "$(form /accounts/$FUID/delete --data-urlencode confirm=家)")" "没有删除：输入的用户名和「家人」不一致"
chk "删除账号" "$(flash "$(form /accounts/$FUID/delete --data-urlencode confirm=家人)")" "已删除账号「家人」和它的全部数据"
chk "删除后设备失效、pushkey 不能发送、数据清空" "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $FT" $PUB/v1/me) $(curl -s -o /dev/null -w '%{http_code}' "$PUB/message/push?pushkey=$FKEY&text=x") $(dbq "select count(*) from messages where user_id=?" $FUID)" "401 403 0"
chk "删除后它的 pushkey 字符串不能被别的账号认领（409），推送提示已删除" "$(curl -s -o /dev/null -w '%{http_code}' "${CJ[@]}" -H "Authorization: Bearer $DT3" -d "$(json name x key "$FKEY")" $PUB/v1/keys) $(curl -s "$PUB/message/push?pushkey=$FKEY&text=x" | pj 'd["error"]')" "409 pushkey 已停用（所属账号已删除，或已换成新的 key）"
chk "第一个账号不能删除" "$(flash "$(form /accounts/1/delete --data-urlencode confirm=owner1)")" "第一个账号接收服务器自己的通知（备份失败等），不能删除"
grep -q "模板渲染失败" $T/hub.log && ng "日志中有模板错误" || ok "0.9.0 页面无模板错误"
chk "最后检查：数据库里没有明文消息" "$(dbq "select count(*) from messages where e2e=''")" 0

echo; echo "结果：通过 ${pass}，失败 ${fail}"
[ $fail -eq 0 ]
