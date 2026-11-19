#!/usr/bin/env bash
# 本机端到端测试：在 127.0.0.1:18790/18791 启动 hub，跑完自动关闭。
set -u
cd "$(dirname "$0")/.."
# 二进制不存在、或源码比它新时重新编译（避免拿旧服务端测新功能）
if [ ! -x bin/huijian ] || [ -n "$(find . -name '*.go' -newer bin/huijian | head -1)" ]; then
  GOTOOLCHAIN=local go build -o bin/huijian . || exit 1
fi
T=tests/run; rm -rf $T; mkdir -p $T/data
PUB=http://127.0.0.1:18790; ADM=http://127.0.0.1:18791
HUIJIAN_DATA=$T/data HUIJIAN_PUBLIC_ADDR=127.0.0.1:18790 HUIJIAN_ADMIN_ADDR=127.0.0.1:18791 \
  HUIJIAN_ADMIN_DENY=10.0.0.1 HUIJIAN_SERVER_UPDATE=0 ./bin/huijian hub > $T/hub.log 2>&1 &
HUB=$!; trap 'kill $HUB 2>/dev/null' EXIT
for i in $(seq 1 30); do curl -sf $PUB/healthz >/dev/null && break; sleep 0.2; done
pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
ng(){ echo "  ❌ $1"; fail=$((fail+1)); }
chk(){ if [ "$2" = "$3" ]; then ok "$1"; else ng "$1（期望 $3，实际 $2）"; fi; }

echo "[1] 管理页登录"
J=$T/cookies; TOK=$(cat $T/data/admin.token)
chk "未登录跳转登录页" "$(curl -s -o /dev/null -w '%{http_code}' $ADM/)" 303
chk "错误令牌" "$(curl -s -o /dev/null -w '%{redirect_url}' -d token=wrong $ADM/login | grep -c 'e=1')" 1
curl -s -c $J -o /dev/null -d "token=$TOK" $ADM/login
chk "登录后首页" "$(curl -s -b $J -o /dev/null -w '%{http_code}' $ADM/)" 200
chk "伪造 Origin 的 POST 被拒" "$(curl -s -b $J -o /dev/null -w '%{http_code}' -H 'Origin: http://evil.com' -d name=x $ADM/pushkeys)" 403

echo "[2] 创建 pushkey 与配对码"
LOC=$(curl -s -b $J -o /dev/null -w '%{redirect_url}' -H "Origin: $ADM" --data-urlencode "name=本机测试" $ADM/pushkeys)
PK=$(python3 -c "import sys,urllib.parse as u;print(u.parse_qs(u.urlparse(sys.argv[1]).query)['key'][0])" "$LOC")
[[ $PK == PK_* ]] && ok "pushkey 已创建" || ng "pushkey 创建失败: $LOC"
CODE=$(curl -s -b $J -o /dev/null -w '%{redirect_url}' -H "Origin: $ADM" -X POST $ADM/pair | sed -E 's/.*code=([0-9]+).*/\1/')
[[ $CODE =~ ^[0-9]{6}$ ]] && ok "配对码 $CODE" || ng "配对码失败"

echo "[3] 设备配对"
R=$(curl -s -X POST $PUB/v1/pair -H 'Content-Type: application/json' -d "{\"code\":\"$CODE\",\"name\":\"test-mac\",\"platform\":\"macos\"}")
DT=$(echo "$R" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))')
[[ $DT == DT_* ]] && ok "配对成功拿到设备 token" || ng "配对失败: $R"
chk "配对码不能重复使用" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $PUB/v1/pair -H 'Content-Type: application/json' -d "{\"code\":\"$CODE\"}")" 403
H="Authorization: Bearer $DT"

echo "[4] 打开实时流（后台）"
curl -sN -H "$H" "$PUB/v1/stream?since=0" > $T/stream.txt & SP=$!
sleep 0.5

echo "[5] 发送"
chk "PushDeer 兼容 GET" "$(curl -s -G $PUB/message/push --data-urlencode "pushkey=$PK" --data-urlencode 'text=训练开始' | python3 -c 'import sys,json;print(json.load(sys.stdin)["code"])')" 0
chk "表单 POST + markdown" "$(curl -s $PUB/message/push -d pushkey=$PK -d text=标题 --data-urlencode 'desp=**粗体** 正文' -d type=markdown -d priority=4 | python3 -c 'import sys,json;print(json.load(sys.stdin)["code"])')" 0
head -c 3000000 /dev/urandom > $T/big.bin
python3 - "$T/pic.png" <<'PY'
import sys,zlib,struct
w=h=64; raw=b''.join(b'\x00'+bytes([x*4,y*4,128])*1 for y in range(h) for x in range(1)) # 占位
def chunk(t,d): return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
rows=b''.join(b'\x00'+b''.join(bytes([x*4,y*4,128]) for x in range(w)) for y in range(h))
open(sys.argv[1],'wb').write(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b''))
PY
OUT=$(./bin/huijian push -u $PUB -k $PK -p 4 -topic train -thread exp42 -d "val_loss 0.231" -f $T/pic.png -f $T/big.bin "exp42 完成")
echo "    $OUT"; [[ $OUT == 已发送* ]] && ok "CLI 带 2 个附件发送" || ng "CLI 发送失败"
chk "错误 pushkey 被拒" "$(curl -s -o /dev/null -w '%{http_code}' "$PUB/message/push?pushkey=PK_wrong&text=x")" 403
chk "缺少 text 被拒" "$(curl -s -o /dev/null -w '%{http_code}' "$PUB/message/push?pushkey=$PK")" 400
chk "非法 priority 被拒" "$(curl -s -o /dev/null -w '%{http_code}' "$PUB/message/push?pushkey=$PK&text=x&priority=9")" 400

echo "[6] 拉取历史"
curl -s -H "$H" "$PUB/v1/messages?since=0" > $T/msgs.json
chk "历史消息条数" "$(python3 -c 'import json;print(len(json.load(open("'$T/msgs.json'"))["messages"]))')" 3
python3 - $T/msgs.json <<'PY'
import json,sys; m=json.load(open(sys.argv[1]))["messages"][-1]
print("    最后一条:", m["text"], "P%d"%m["priority"], m["topic"], m["thread"], [(a["name"],a["mime"],a["size"]) for a in m["attachments"]])
PY
chk "回笺 Markdown：消息带 doc（粗体）" "$(python3 -c 'import json;m=[x for x in json.load(open("'$T/msgs.json'"))["messages"] if x["text"]=="标题"][0];print(m["doc"]["v"], m["doc"]["blocks"][0]["runs"][0])')" "1 {'text': '粗体', 'b': True}"
chk "回笺 Markdown：preview 纯文本" "$(python3 -c 'import json;print([x for x in json.load(open("'$T/msgs.json'"))["messages"] if x["text"]=="标题"][0]["preview"])')" "粗体 正文"
chk "没有正文的消息不带 doc" "$(python3 -c 'import json;print([x for x in json.load(open("'$T/msgs.json'"))["messages"] if x["text"]=="训练开始"][0].get("doc"))')" "None"
chk "未带 token 被拒" "$(curl -s -o /dev/null -w '%{http_code}' $PUB/v1/messages)" 401

echo "[7] 实时流"
sleep 0.5; kill $SP 2>/dev/null
chk "流中收到 3 条 message 事件" "$(grep -c '^event: message' $T/stream.txt)" 3
chk "流里的 Markdown 消息也带 doc" "$([ "$(grep -c '"doc":{"v":1' $T/stream.txt)" -ge 1 ] && echo 是)" 是

echo "[7b] 长轮询"
MAXID=$(curl -s -H "$H" "$PUB/v1/messages?limit=1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["messages"][-1]["id"])')
( sleep 1; curl -s -o /dev/null "$PUB/message/push?pushkey=$PK&text=longpoll" ) &
LP=$(curl -s -w ' %{time_total}' -H "$H" "$PUB/v1/messages?since=$MAXID&wait=10")
LPT=${LP##* }; LPB=${LP% *}
chk "长轮询在新消息到达时立即返回" "$(echo "$LPB" | python3 -c 'import sys,json;print([m["text"] for m in json.load(sys.stdin)["messages"]])')" "['longpoll']"
python3 -c "import sys;sys.exit(0 if 0.8<$LPT<3 else 1)" && ok "返回耗时 ${LPT}s（约等于发送延迟 1s）" || ng "返回耗时异常 ${LPT}s"
LP=$(curl -s -w ' %{time_total}' -H "$H" "$PUB/v1/messages?since=$((MAXID+1))&wait=2")
python3 -c "import sys;sys.exit(0 if 1.9<${LP##* }<3 else 1)" && ok "无消息时 wait=2 超时返回空列表" || ng "超时行为异常: $LP"

echo "[7c] 幂等键与并发补发"
I1=$(curl -s "$PUB/message/push" -d pushkey=$PK -d text=idem-test -d idem=fixed-key-1 | python3 -c 'import sys,json;print(json.load(sys.stdin)["content"]["result"][0])')
I2=$(curl -s "$PUB/message/push" -d pushkey=$PK -d text=idem-test -d idem=fixed-key-1 | python3 -c 'import sys,json;print(json.load(sys.stdin)["content"]["result"][0])')
chk "相同幂等键返回同一消息 id" "$I2" "$I1"
chk "空结果返回 [] 而不是 null" "$(curl -s -H "$H" "$PUB/v1/messages?since=999999" | python3 -c 'import sys,json;print(json.load(sys.stdin)["messages"])')" "[]"
OLDHOME=$HOME; export HOME=$PWD/$T/home; mkdir -p $HOME
for i in 1 2 3; do ./bin/huijian push -u http://127.0.0.1:1 -k $PK "outbox-$i" >/dev/null 2>&1; done
chk "3 条进入 outbox" "$(ls $HOME/.huijian/outbox | wc -l | tr -d ' ')" 3
for f in $HOME/.huijian/outbox/*/job.json; do python3 -c "import json,sys;p=sys.argv[1];j=json.load(open(p));j['urls']=['$PUB'];json.dump(j,open(p,'w'))" $f; done
BEFORE=$(curl -s -H "$H" "$PUB/v1/messages?limit=1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["messages"][-1]["id"])')
FP=""; for i in 1 2 3 4 5; do ./bin/huijian flush >/dev/null 2>&1 & FP="$FP $!"; done; wait $FP
chk "5 个进程并发补发，outbox 清空" "$(ls $HOME/.huijian/outbox | grep -vc failed)" 0
chk "并发补发后服务端只多 3 条（无重复）" "$(curl -s -H "$H" "$PUB/v1/messages?since=$BEFORE" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["messages"]))')" 3
export HOME=$OLDHOME

echo "[8] 附件下载 / 断点续传 / 校验"
read AID ASHA ASIZE < <(python3 -c 'import json;a=json.load(open("'$T/msgs.json'"))["messages"][-1]["attachments"][1];print(a["id"],a["sha256"],a["size"])')
curl -s -H "$H" -o $T/dl.bin -D $T/dl.h "$PUB/v1/att/$AID"
chk "完整下载 sha256 一致" "$(shasum -a 256 $T/dl.bin | cut -d' ' -f1)" "$ASHA"
grep -qi 'content-disposition: attachment' $T/dl.h && ok "Content-Disposition 为 attachment" || ng "缺少 Content-Disposition"
chk "Range 请求返回 206" "$(curl -s -H "$H" -H 'Range: bytes=1000000-' -o $T/part.bin -w '%{http_code}' "$PUB/v1/att/$AID")" 206
head -c 1000000 $T/dl.bin > $T/joined.bin; cat $T/part.bin >> $T/joined.bin
chk "断点续传拼接后 sha256 一致" "$(shasum -a 256 $T/joined.bin | cut -d' ' -f1)" "$ASHA"
chk "不存在的附件 404" "$(curl -s -o /dev/null -w '%{http_code}' -H "$H" $PUB/v1/att/a_nope)" 404

echo "[9] 吊销设备"
DID=$(echo "$R" | python3 -c 'import sys,json;print(json.load(sys.stdin)["device_id"])')
curl -s -b $J -o /dev/null -H "Origin: $ADM" -X POST $ADM/devices/$DID/revoke
chk "吊销后 token 失效" "$(curl -s -o /dev/null -w '%{http_code}' -H "$H" $PUB/v1/messages)" 401

echo "[10] 日志中不应出现 pushkey"
grep -q "$PK" $T/hub.log && ng "日志泄露了 pushkey" || ok "日志未记录 pushkey"

echo "[11] 管理后台 v0.2：记住登录 / 一次性链接 / 设备管理权限 / 页面渲染"
J2=$T/cookies2; curl -s -c $J2 -o /dev/null -d "token=$TOK" -d remember=1 $ADM/login
grep -q "huijian_admin" $J2 && ok "记住登录：拿到持久 cookie" || ng "没有持久 cookie"
kill $HUB; wait $HUB 2>/dev/null
RKEY=$T/release.key; RPUB=$(./bin/huijian release-key $RKEY)
HUIJIAN_DATA=$T/data HUIJIAN_PUBLIC_ADDR=127.0.0.1:18790 HUIJIAN_ADMIN_ADDR=127.0.0.1:18791 HUIJIAN_ADMIN_DENY=10.0.0.1 \
  HUIJIAN_UPDATE_PUBKEY=$RPUB ./bin/huijian hub >> $T/hub.log 2>&1 &
HUB=$!; trap 'kill $HUB 2>/dev/null' EXIT
for i in $(seq 1 30); do curl -sf $PUB/healthz >/dev/null && break; sleep 0.2; done
chk "服务重启后记住的会话仍有效" "$(curl -s -b $J2 -o /dev/null -w '%{http_code}' $ADM/)" 200
for pg in / /messages "/messages?p=4&q=exp&att=1" /keys /devices /settings; do
  chk "页面 $pg 渲染" "$(curl -s -b $J2 -o /dev/null -w '%{http_code}' "$ADM$pg")" 200; done
grep -q "模板渲染失败" $T/hub.log && ng "日志中有模板错误：$(grep 模板渲染失败 $T/hub.log | head -1)" || ok "无模板渲染错误"
chk "管理页下载附件 sha256 一致" "$(curl -s -b $J2 "$ADM/att/$AID" | shasum -a 256 | cut -d' ' -f1)" "$ASHA"
LINK=$(HUIJIAN_DATA=$T/data HUIJIAN_ADMIN_ADDR=127.0.0.1:18791 ./bin/huijian admin-link | tail -1)
J3=$T/cookies3
chk "命令行一次性链接登录" "$(curl -s -c $J3 -o /dev/null -w '%{redirect_url}' "$LINK" | grep -c 'f=')" 1
chk "链接登录后可访问" "$(curl -s -b $J3 -o /dev/null -w '%{http_code}' $ADM/)" 200
chk "链接不能重复使用" "$(curl -s -o /dev/null -w '%{redirect_url}' "$LINK" | grep -c 'e=link')" 1
CODE2=$(curl -s -b $J2 -o /dev/null -w '%{redirect_url}' -H "Origin: $ADM" -d can_admin=1 $ADM/pair | sed -E 's/.*code=([0-9]+).*/\1/')
R2=$(curl -s -X POST $PUB/v1/pair -H 'Content-Type: application/json' -d "{\"code\":\"$CODE2\",\"name\":\"admin-mac\",\"platform\":\"macos\"}")
DT2=$(echo "$R2" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])'); DID2=$(echo "$R2" | python3 -c 'import sys,json;print(json.load(sys.stdin)["device_id"])')
chk "/v1/me 返回 can_admin=true" "$(curl -s -H "Authorization: Bearer $DT2" $PUB/v1/me | python3 -c 'import sys,json;print(json.load(sys.stdin)["can_admin"])')" True
ALINK=$(curl -s -X POST -H "Authorization: Bearer $DT2" $PUB/v1/admin/link | python3 -c 'import sys,json;print(json.load(sys.stdin)["url"])')
[[ $ALINK == http://127.0.0.1:18791/auth/link?t=L_* ]] && ok "有权限设备换取登录链接" || ng "换取失败: $ALINK"
J4=$T/cookies4; curl -s -c $J4 -o /dev/null "$ALINK"
chk "App 链接登录后可访问" "$(curl -s -b $J4 -o /dev/null -w '%{http_code}' $ADM/)" 200
curl -s -b $J2 -o /dev/null -H "Origin: $ADM" -d on=0 $ADM/devices/$DID2/admin
chk "关闭权限后换取链接 403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $DT2" $PUB/v1/admin/link)" 403
# 精确注销 J4 的会话（列表按 last_seen 排序，同一秒内顺序不确定，不能取第一条）
H4=$(awk '$6=="huijian_admin"{print $7}' $J4 | tail -1 | tr -d '\n' | shasum -a 256 | cut -d' ' -f1)
chk "设置页列出 J4 的会话" "$(curl -s -b $J2 $ADM/settings | grep -c "/sessions/$H4/revoke")" 1
curl -s -b $J2 -o /dev/null -H "Origin: $ADM" -X POST "$ADM/sessions/$H4/revoke"
N_OK=0; for j in $J2 $J3 $J4; do [ "$(curl -s -b $j -o /dev/null -w '%{http_code}' $ADM/)" = 200 ] && N_OK=$((N_OK+1)); done
chk "注销一个会话后剩 2 个有效" "$N_OK" 2
chk "被注销的是 J4" "$(curl -s -b $J4 -o /dev/null -w '%{http_code}' $ADM/)" 303

echo "[9] 客户端应用内更新"
chk "release-pubkey 与生成时一致" "$(./bin/huijian release-pubkey $RKEY)" "$RPUB"
./bin/huijian release-key $RKEY >/dev/null 2>&1 && ng "release-key 覆盖了已有私钥" || ok "release-key 不覆盖已有私钥"
head -c 300000 /dev/urandom > $T/pkg10.zip; PSHA=$(shasum -a 256 $T/pkg10.zip | cut -d' ' -f1)
chk "无令牌发布 401" "$(curl -s -o /dev/null -w '%{http_code}' -F platform=macos -F version=1 -F build=1 -F file=@$T/pkg10.zip $ADM/api/releases)" 401
chk "Cookie 会话不能调用发布 API" "$(curl -s -b $J2 -o /dev/null -w '%{http_code}' -F platform=macos -F file=@$T/pkg10.zip $ADM/api/releases)" 401
export HUIJIAN_ADMIN_URL=$ADM HUIJIAN_ADMIN_TOKEN=$TOK
./bin/huijian release -key $RKEY -version 0.9.0 -build 10 -notes "第一版" $T/pkg10.zip > $T/rel.out 2>&1 && ok "huijian release 上传成功" || ng "上传失败：$(cat $T/rel.out)"
SIG10=$(./bin/huijian release -dry -key $RKEY -version 0.9.0 -build 10 -notes "第一版" $T/pkg10.zip | awk '/^signature/{print $2}')
U=$(curl -s -H "Authorization: Bearer $DT2" "$PUB/v1/update?build=9")
chk "旧版本查到更新 build 10" "$(echo "$U" | python3 -c 'import sys,json;print(json.load(sys.stdin)["update"]["build"])')" 10
chk "返回的签名与发布签名一致" "$(echo "$U" | python3 -c 'import sys,json;print(json.load(sys.stdin)["update"]["signature"])')" "$SIG10"
chk "已是最新时 update 为 null" "$(curl -s -H "Authorization: Bearer $DT2" "$PUB/v1/update?build=10")" '{"update":null}'
chk "未带 token 查询 401" "$(curl -s -o /dev/null -w '%{http_code}' "$PUB/v1/update?build=1")" 401
UURL=$(echo "$U" | python3 -c 'import sys,json;print(json.load(sys.stdin)["update"]["url"])')
chk "下载更新包 sha256 一致" "$(curl -s -H "Authorization: Bearer $DT2" "$PUB$UURL" | shasum -a 256 | cut -d' ' -f1)" "$PSHA"
chk "更新包支持 Range" "$(curl -s -o /dev/null -w '%{http_code}' -H 'Range: bytes=100-199' -H "Authorization: Bearer $DT2" "$PUB$UURL")" 206
chk "长轮询响应带最新构建号" "$(curl -s -D - -o /dev/null -H "Authorization: Bearer $DT2" "$PUB/v1/messages?since=999999&limit=1" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-huijian-latest-build"{print $2}')" 10
CODE3=$(curl -s -b $J2 -o /dev/null -w '%{redirect_url}' -H "Origin: $ADM" -X POST $ADM/pair | sed -E 's/.*code=([0-9]+).*/\1/')
DT3=$(curl -s -X POST $PUB/v1/pair -H 'Content-Type: application/json' -d "{\"code\":\"$CODE3\",\"name\":\"phone\",\"platform\":\"ios\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
chk "其他平台查不到 macOS 更新" "$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/update?build=0")" '{"update":null}'
chk "其他平台不能下载 macOS 更新包" "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $DT3" "$PUB$UURL")" 404
# iPhone：GBox 软件源和安装包（不需要登录）
chk "还没有 iOS 版本时软件源 404" "$(curl -s -o /dev/null -w '%{http_code}' $PUB/ios/gbox.appsrc)" 404
head -c 3000 /dev/urandom > $T/ios3.ipa; ISHA=$(shasum -a 256 $T/ios3.ipa | cut -d' ' -f1)
./bin/huijian release -key $RKEY -platform ios -version 0.1.0 -build 3 -notes "iPhone 第一版" $T/ios3.ipa >/dev/null 2>&1 && ok "发布 iOS 版本" || ng "发布 iOS 版本失败"
SRC=$(curl -s $PUB/ios/gbox.appsrc)
chk "软件源列出最新 iOS 版本" "$(echo "$SRC" | python3 -c 'import sys,json;a=json.load(sys.stdin)["appRepositories"][0];print(a["appType"],a["appVersion"],a["appPackage"].rsplit("/",1)[1])')" "SELF_SIGN 0.1.0 Huijian-0.1.0-3.ipa"
IPA=$(echo "$SRC" | python3 -c 'import sys,json;print(json.load(sys.stdin)["appRepositories"][0]["appPackage"])')
chk "安装包可直接下载且 sha256 一致" "$(curl -s "$IPA" | shasum -a 256 | cut -d' ' -f1)" "$ISHA"
chk "不存在的构建号 404" "$(curl -s -o /dev/null -w '%{http_code}' $PUB/ios/Huijian-0.1.0-99.ipa)" 404
chk "路径穿越被拒绝" "$(curl -s -o /dev/null -w '%{http_code}' "$PUB/ios/..%2F..%2Fhuijian.db")" 404
chk "macOS 版本不能当 iOS 安装包下载" "$(curl -s -o /dev/null -w '%{http_code}' $PUB/ios/Huijian-0.9.0-10.ipa)" 404
chk "iPhone 查到 iOS 更新" "$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/update?build=1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["update"]["build"])')" 3
chk "公开图标" "$(curl -s -o /dev/null -w '%{http_code} %{content_type}' $PUB/icon.png)" "200 image/png"
# Bark 转发设置
BK(){ curl -s -o /dev/null -w '%{http_code}' -X PUT -H "Authorization: Bearer $DT3" -H 'Content-Type: application/json' -d "$1" $PUB/v1/bark; }
chk "Bark 地址格式错误 400" "$(BK '{"url":"api.day.app/abc"}')" 400
chk "加密密钥长度不对 400" "$(BK '{"url":"https://api.day.app/AbCd123","cipher_key":"short","cipher_iv":"abcdef9876543210"}')" 400
chk "保存 Bark 地址（加密）" "$(BK '{"url":"https://api.day.app/AbCd123/这里改成你自己的推送内容","cipher_key":"0123456789abcdef0123456789abcdef","cipher_iv":"abcdef9876543210"}')" 200
chk "/v1/me 返回规范化的 Bark 地址" "$(curl -s -H "Authorization: Bearer $DT3" $PUB/v1/me | python3 -c 'import sys,json;b=json.load(sys.stdin)["bark"];print(b["url"],b["encrypted"])')" "https://api.day.app/AbCd123 True"
chk "/v1/me 不返回加密密钥" "$(curl -s -H "Authorization: Bearer $DT3" $PUB/v1/me | grep -c 0123456789abcdef)" 0
BK '{"url":"http://127.0.0.1:9/KeyXyz1"}' >/dev/null
chk "Bark 连不上时测试返回 502" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $DT3" $PUB/v1/bark/test)" 502
chk "关闭 Bark 转发" "$(BK '{"url":""}')$(curl -s -H "Authorization: Bearer $DT3" $PUB/v1/me | python3 -c 'import sys,json;print(json.load(sys.stdin)["bark"])')" "200None"
chk "未配置时测试 400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $DT3" $PUB/v1/bark/test)" 400
./bin/huijian release -key $RKEY -version 0.9.0 -build 10 $T/pkg10.zip >/dev/null 2>&1 && ng "重复 build 被接受" || ok "重复 build 被拒绝"
./bin/huijian release -key $RKEY -version 0.8.0 -build 9 $T/pkg10.zip > $T/rel.out 2>&1 && ng "降级 build 被接受" || { grep -q 409 $T/rel.out && ok "降级 build 被拒绝（409）" || ng "降级返回异常：$(cat $T/rel.out)"; }
OKEY=$T/other.key; ./bin/huijian release-key $OKEY >/dev/null
./bin/huijian release -key $OKEY -version 1.0.0 -build 11 $T/pkg10.zip > $T/rel.out 2>&1 && ng "错误私钥签名被接受" || { grep -q "签名校验失败" $T/rel.out && ok "错误私钥签名被拒绝" || ng "异常：$(cat $T/rel.out)"; }
chk "sha256 不符被拒绝" "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOK" -F platform=macos -F version=1.0.0 -F build=12 -F sha256=$(printf '0%.0s' {1..64}) -F signature=$SIG10 -F file=@$T/pkg10.zip $ADM/api/releases)" 400
for b in 11 12 13 14 15; do head -c 1000 /dev/urandom > $T/pkg$b.zip; ./bin/huijian release -key $RKEY -version 0.9.$b -build $b $T/pkg$b.zip >/dev/null 2>&1 || ng "发布 build $b 失败"; done
chk "每个平台只保留最近 5 个版本的文件（macOS 5 个 + iOS 1 个）" "$(ls $T/data/releases | wc -l | tr -d ' ')" 6
curl -s -o /dev/null -H "Authorization: Bearer $DT2" -H "X-Huijian-Client: macos 0.9.15 (15)" "$PUB/v1/me"
chk "设备页显示客户端版本" "$(curl -s -b $J2 $ADM/devices | grep -c 'macos 0.9.15 (15)')" 1
chk "设置页列出 6 个版本" "$(curl -s -b $J2 $ADM/settings | grep -oE '/releases/[0-9]+/delete' | wc -l | tr -d ' ')" 6
RID=$(curl -s -H "Authorization: Bearer $DT2" "$PUB/v1/update?build=1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["update"]["id"])')
curl -s -b $J2 -o /dev/null -H "Origin: $ADM" -X POST $ADM/releases/$RID/delete
chk "删除最新版后回退到 build 14" "$(curl -s -H "Authorization: Bearer $DT2" "$PUB/v1/update?build=1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["update"]["build"])')" 14
grep -q "模板渲染失败" $T/hub.log && ng "日志中有模板错误" || ok "更新相关页面无模板错误"

echo "[10] 无域名部署：地址自动推导、登录限速"
chk "未授权设备经公网 IP 申请链接返回 403" "$(curl -s -X POST -H 'Host: 1.2.3.4:18790' -H "Authorization: Bearer $DT2" $PUB/v1/admin/link -o /dev/null -w '%{http_code}')" 403
curl -s -b $J2 -o /dev/null -H "Origin: $ADM" -d on=1 $ADM/devices/$DID2/admin
chk "管理后台只监听本机时，链接指向监听地址（不被请求 Host 改写）" "$(curl -s -X POST -H 'Host: 1.2.3.4:18790' -H "Authorization: Bearer $DT2" $PUB/v1/admin/link | python3 -c 'import sys,json;print(json.load(sys.stdin)["url"].split("/auth")[0])')" "http://127.0.0.1:18791"
CK=$(awk '/huijian_admin/{print $7}' $J2 | tail -1)
chk "设置页公网地址以明确的监听地址为准（不被 Host 改写）" "$(curl -s -H "Cookie: huijian_admin=$CK" -H 'Host: 5.6.7.8:18791' $ADM/settings | grep -c 'http://5.6.7.8:18790')" 0
unset HUIJIAN_ADMIN_URL
chk "命令行 admin-link 无法推导时给出占位提示" "$(HUIJIAN_DATA=$T/data HUIJIAN_ADMIN_ADDR=0.0.0.0:18791 ./bin/huijian admin-link | grep -c '<服务器IP>:18791')" 1
chk "配置 PUBLIC_URL 后 admin-link 自动填好主机" "$(HUIJIAN_DATA=$T/data HUIJIAN_ADMIN_ADDR=0.0.0.0:18791 HUIJIAN_PUBLIC_URL=http://9.9.9.9:18790 ./bin/huijian admin-link | grep -c 'http://9.9.9.9:18791/auth/link')" 1
R=""; for i in $(seq 1 8); do R="$R $(curl -s -o /dev/null -w '%{redirect_url}' -d token=wrong $ADM/login)"; done
chk "连续错误登录触发限速" "$(echo "$R" | grep -c 'e=rate')" 1
chk "限速提示渲染" "$(curl -s "$ADM/login?e=rate" | grep -c '尝试太频繁')" 1
chk "已登录会话不受限速影响" "$(curl -s -b $J2 -o /dev/null -w '%{http_code}' $ADM/)" 200
VLINK=$(curl -s -X POST -H "Authorization: Bearer $DT2" $PUB/v1/admin/link | python3 -c 'import sys,json;print(json.load(sys.stdin)["url"])')
J5=$T/cookies5; curl -s -c $J5 -o /dev/null "$VLINK"
chk "限速期间有效的一次性链接仍能登录（Mac 一键登录不会被别人锁住）" "$(curl -s -b $J5 -o /dev/null -w '%{http_code}' $ADM/)" 200
for i in 1 2 3; do RB=$(curl -s -o /dev/null -w '%{redirect_url}' "$ADM/auth/link?t=L_bogus"); done   # 前面的步骤耗时可能回补了令牌，多试几次
chk "限速期间无效链接被限速" "$(echo "$RB" | grep -c 'e=rate')" 1

echo "[11] 设备自助管理：改名、pushkey、时间戳设备 ID、搜索"
[[ $DID2 =~ ^d_[0-9]{14}_[0-9a-f]{4}$ ]] && ok "新设备 ID 为时间戳格式（${DID2}）" || ng "设备 ID 格式不对：${DID2}"
AU=(-H "Authorization: Bearer $DT2" -H 'Content-Type: application/json')
chk "设备给自己改名" "$(curl -s -X PATCH "${AU[@]}" -d '{"name":"  我的 MacBook Pro \n"}' $PUB/v1/me | python3 -c 'import sys,json;print(json.load(sys.stdin)["name"])')" "我的 MacBook Pro"
chk "空名称被拒绝" "$(curl -s -o /dev/null -w '%{http_code}' -X PATCH "${AU[@]}" -d '{"name":"  "}' $PUB/v1/me)" 400
NK=$(curl -s "${AU[@]}" $PUB/v1/keys | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["keys"]))')
[ "$NK" -ge 1 ] && ok "设备列出 pushkey（${NK} 把）" || ng "列出 pushkey 失败"
CK1="my-custom-key-$(date +%s)"
R=$(curl -s "${AU[@]}" -d "{\"name\":\"脚本 A\",\"key\":\"$CK1\"}" $PUB/v1/keys); KID=$(echo "$R" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
chk "设备新建自定义 key" "$(echo "$R" | python3 -c 'import sys,json;print(json.load(sys.stdin)["key"])')" "$CK1"
chk "自定义 key 可以发送" "$(curl -s -o /dev/null -w '%{http_code}' "$PUB/message/push?pushkey=$CK1&text=custom")" 200
chk "太短的 key 被拒绝" "$(curl -s -o /dev/null -w '%{http_code}' "${AU[@]}" -d '{"name":"x","key":"short"}' $PUB/v1/keys)" 400
DUP=$(printf '{"name":"x","key":"%s"}' "$CK1")
chk "重复的 key 被拒绝（409）" "$(curl -s -o /dev/null -w '%{http_code}' "${AU[@]}" -d "$DUP" $PUB/v1/keys)" 409
CK2="renamed-key-$(date +%s)-xyz"
UPD=$(printf '{"name":"脚本 A2","key":"%s"}' "$CK2")
UPR=$(curl -s -X PATCH "${AU[@]}" -d "$UPD" $PUB/v1/keys/$KID)
chk "设备改名并更换 key（返回更新后的这一把）" "$(echo "$UPR" | python3 -c 'import sys,json;k=json.load(sys.stdin);print(k["name"],k["key"])')" "脚本 A2 $CK2"
chk "旧 key 立即失效" "$(curl -s -o /dev/null -w '%{http_code}' "$PUB/message/push?pushkey=$CK1&text=old")" 403
chk "新 key 可以发送" "$(curl -s -o /dev/null -w '%{http_code}' "$PUB/message/push?pushkey=$CK2&text=new")" 200
curl -s -o /dev/null -X POST "${AU[@]}" $PUB/v1/keys/$KID/revoke
chk "设备吊销后不能再发送" "$(curl -s -o /dev/null -w '%{http_code}' "$PUB/message/push?pushkey=$CK2&text=x")" 403
chk "已吊销的不能再修改" "$(curl -s -o /dev/null -w '%{http_code}' -X PATCH "${AU[@]}" -d '{"name":"y"}' $PUB/v1/keys/$KID)" 400
chk "不能改别人的 / 不存在的 key" "$(curl -s -o /dev/null -w '%{http_code}' -X PATCH "${AU[@]}" -d '{"name":"y"}' $PUB/v1/keys/999999)" 404
chk "未带 token 不能列出 key" "$(curl -s -o /dev/null -w '%{http_code}' $PUB/v1/keys)" 401
chk "0.5.0 起本账号的设备都能管理 key（不需要允许管理）" "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $DT3" $PUB/v1/keys)" 200
chk "没有管理权限的设备不能查看服务器存储（403）" "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $DT3" $PUB/v1/storage)" 403
chk "没有管理权限的设备仍可给自己改名" "$(curl -s -X PATCH -H "Authorization: Bearer $DT3" -H 'Content-Type: application/json' -d '{"name":"手机"}' $PUB/v1/me | python3 -c 'import sys,json;print(json.load(sys.stdin)["name"])')" "手机"
chk "吊销不存在的 key 返回 404" "$(curl -s -o /dev/null -w '%{http_code}' -X POST "${AU[@]}" $PUB/v1/keys/999999/revoke)" 404
chk "给不存在的设备改名不会误报成功" "$(curl -s -b $J2 -o /dev/null -w '%{redirect_url}' -H "Origin: $ADM" --data-urlencode "name=x" $ADM/devices/d_nope/rename | python3 -c 'import sys,urllib.parse as u;print(u.unquote(sys.stdin.read()))' | grep -c '不存在')" 1
LONG=$(python3 -c 'print("鸿"*40)')
LCODE=$(curl -s -b $J2 -o /dev/null -w '%{redirect_url}' -H "Origin: $ADM" -X POST $ADM/pair | sed -E 's/.*code=([0-9]+).*/\1/')
chk "配对时超长中文名按字符截断（不产生非法 UTF-8）" "$(curl -s -X POST $PUB/v1/pair -H 'Content-Type: application/json' -d "{\"code\":\"$LCODE\",\"name\":\"$LONG\",\"platform\":\"macos\"}" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["name"]))')" 40
chk "添加设备时默认不勾选「允许管理」（按设备在设备页打开）" "$(curl -s -b $J2 $ADM/devices | grep -c 'name="can_admin" value="1" checked')" 0
chk "管理页按设备 ID 搜索" "$(curl -s -b $J2 "$ADM/devices?q=$DID2" | grep -c 'data-copy="'$DID2'"')" 1
chk "管理页按名称搜索只返回匹配的设备" "$(curl -s -b $J2 "$ADM/devices?q=MacBook%20Pro" | grep -o 'class="copyid" data-copy="[^"]*"' | tr '\n' ' ')" "class=\"copyid\" data-copy=\"$DID2\" "
chk "搜不到时给出提示" "$(curl -s -b $J2 "$ADM/devices?q=nothing-here" | grep -c '没有匹配')" 1
curl -s -b $J2 -o /dev/null -H "Origin: $ADM" --data-urlencode "name=后台改名" $ADM/devices/$DID2/rename
chk "管理页给设备改名" "$(curl -s -H "Authorization: Bearer $DT2" $PUB/v1/me | python3 -c 'import sys,json;print(json.load(sys.stdin)["name"])')" "后台改名"
CK3="admin-custom-key-$(date +%s)"
curl -s -b $J2 -o /dev/null -H "Origin: $ADM" --data-urlencode "name=后台自定义" --data-urlencode "key=$CK3" $ADM/keys
chk "管理页新建自定义 key" "$(curl -s -o /dev/null -w '%{http_code}' "$PUB/message/push?pushkey=$CK3&text=adm")" 200
grep -q "模板渲染失败" $T/hub.log && ng "日志中有模板错误" || ok "自助管理相关页面无模板错误"

echo "[12] 0.5.0：版本协商 / 账号 / 设备身份 / 接收规则 / 在用设备 / 存储备份"
J=(-H 'Content-Type: application/json')
INFO=$(curl -s $PUB/v1/info)
chk "/v1/info 返回版本和功能清单" "$(echo "$INFO" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["name"], "account" in [f["id"] for f in d["features"]], d["register_open"])')" "huijian True False"
chk "响应头带 X-Huijian-Server" "$(curl -sI $PUB/healthz | grep -ci '^x-huijian-server: ')" 1
chk "不存在的接口返回非 JSON 404（客户端据此判断服务端较旧）" "$(curl -s $PUB/v1/no-such | head -c 9)" "not found"
# 第一个账号设置用户名密码（任何本账号设备都可以，因为还没有密码）
CRED=$(printf '{"username":"%s","password":"%s"}' "owner1" "pass-owner-1")
chk "没有服务器管理权限的设备不能设置初始密码" "$(curl -s -o /dev/null -w '%{http_code}' "${J[@]}" -H "Authorization: Bearer $DT3" -d "$CRED" $PUB/v1/account/credentials)" 403
curl -s -b $J2 -o /dev/null -H "Origin: $ADM" -d on=1 $ADM/devices/$DID2/admin
chk "允许管理的设备为还没有密码的账号设置用户名密码" "$(curl -s "${J[@]}" -H "Authorization: Bearer $DT2" -d "$CRED" $PUB/v1/account/credentials | python3 -c 'import sys,json;a=json.load(sys.stdin)["account"];print(a["username"],a["has_password"])')" "owner1 True"
CRED2=$(printf '{"username":"owner1","password":"another-pass","current_password":"wrong-pass"}')
chk "已有密码时修改需要当前密码" "$(curl -s -o /dev/null -w '%{http_code}' "${J[@]}" -H "Authorization: Bearer $DT3" -d "$CRED2" $PUB/v1/account/credentials)" 403
FP=$(python3 -c 'import hashlib;print(hashlib.sha256(b"e2e-mac-1").hexdigest())')
LOGIN=$(printf '{"username":"OWNER1","password":"pass-owner-1","name":"笔记本","platform":"macos","fingerprint":"%s"}' "$FP")
R1=$(curl -s "${J[@]}" -d "$LOGIN" $PUB/v1/login)
LID=$(echo "$R1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["device_id"])'); LT1=$(echo "$R1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
chk "用户名不区分大小写登录，得到设备 token" "$(echo "$R1" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["token"][:3], d["reused"])')" "DT_ False"
R2=$(curl -s "${J[@]}" -d "$LOGIN" $PUB/v1/login)
LT2=$(echo "$R2" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
chk "同一台设备再次登录：沿用原设备记录" "$(echo "$R2" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["device_id"], d["reused"])')" "$LID True"
chk "旧 token 作废" "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $LT1" $PUB/v1/me)" 401
# 冒用有管理权限设备的指纹：用密码登录不能继承它的管理权限
FP2=$(python3 -c 'import hashlib;print(hashlib.sha256(b"e2e-admin-mac").hexdigest())')
ACODE=$(curl -s -b $J2 -o /dev/null -w '%{redirect_url}' -H "Origin: $ADM" -d can_admin=1 -X POST $ADM/pair | sed -E 's/.*code=([0-9]+).*/\1/')
APAIR=$(printf '{"code":"%s","name":"管理员的 Mac","platform":"macos","fingerprint":"%s"}' "$ACODE" "$FP2")
AT=$(curl -s "${J[@]}" -d "$APAIR" $PUB/v1/pair | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
chk "允许管理的配对码：设备有管理权限" "$(curl -s -H "Authorization: Bearer $AT" $PUB/v1/me | python3 -c 'import sys,json;print(json.load(sys.stdin)["can_admin"])')" True
SPOOF=$(printf '{"username":"owner1","password":"pass-owner-1","name":"x","platform":"macos","fingerprint":"%s"}' "$FP2")
ST2=$(curl -s "${J[@]}" -d "$SPOOF" $PUB/v1/login | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
chk "用密码 + 别人的指纹登录：沿用记录但不继承管理权限" "$(curl -s -H "Authorization: Bearer $ST2" $PUB/v1/me | python3 -c 'import sys,json;print(json.load(sys.stdin)["can_admin"])') $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ST2" $PUB/v1/storage)" "False 403"
LCODE2=$(curl -s -b $J2 -o /dev/null -w '%{redirect_url}' -H "Origin: $ADM" -X POST $ADM/pair | sed -E 's/.*code=([0-9]+).*/\1/')
PAIRB=$(printf '{"code":"%s","name":"另一个名字","platform":"macos","fingerprint":"%s"}' "$LCODE2" "$FP")
R3=$(curl -s "${J[@]}" -d "$PAIRB" $PUB/v1/pair)
LT3=$(echo "$R3" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
chk "用配对码重新配对同一台设备：仍是同一条记录，名称不变" "$(curl -s -H "Authorization: Bearer $LT3" $PUB/v1/me | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["device_id"], d["name"])')" "$LID 笔记本"
ACC=$(curl -s -H "Authorization: Bearer $LT3" $PUB/v1/account)
chk "/v1/account 列出配对记录（密码 2 次 + 配对码 1 次）" "$(echo "$ACC" | python3 -c 'import sys,json;d=[x for x in json.load(sys.stdin)["devices"] if x["current"]][0];print(d["pair_count"], [p["method"] for p in d["pairings"]])')" "3 ['code', 'password', 'password']"
chk "密码错误被拒绝" "$(curl -s -o /dev/null -w '%{http_code}' "${J[@]}" -d '{"username":"owner1","password":"nope-nope"}' $PUB/v1/login)" 403
chk "未开放注册时注册被拒绝" "$(curl -s -o /dev/null -w '%{http_code}' "${J[@]}" -d '{"username":"new1","password":"pass-new-1"}' $PUB/v1/register)" 403
# 管理后台：新建账号、开放注册
curl -s -b $J2 -o /dev/null -H "Origin: $ADM" --data-urlencode "username=家人" --data-urlencode "password=family-pass-1" $ADM/accounts
FAM=$(printf '{"username":"家人","password":"family-pass-1","name":"家人的 Mac","platform":"macos"}')
RF=$(curl -s "${J[@]}" -d "$FAM" $PUB/v1/login); FT=$(echo "$RF" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])'); FID=$(echo "$RF" | python3 -c 'import sys,json;print(json.load(sys.stdin)["device_id"])')
FK=$(curl -s -H "Authorization: Bearer $FT" $PUB/v1/keys)
chk "管理员新建的账号不预置 pushkey，也看不到别人的 key" "$(echo "$FK" | python3 -c 'import sys,json;print(json.load(sys.stdin)["keys"])')" "[]"
FKEY=$(curl -s "${J[@]}" -H "Authorization: Bearer $FT" -d '{"name":"default"}' $PUB/v1/keys | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("key") or d["keys"][0]["key"])')
curl -s -o /dev/null "$PUB/message/push?pushkey=$FKEY&text=给家人"
chk "消息只投递给所属账号" "$(curl -s -H "Authorization: Bearer $FT" "$PUB/v1/messages?since=0" | python3 -c 'import sys,json;print([m["text"] for m in json.load(sys.stdin)["messages"]])')" "['给家人']"
# 删除 pushkey：必须先吊销；删除后历史消息保留
FK2=$(curl -s "${J[@]}" -H "Authorization: Bearer $FT" -d '{"name":"临时"}' $PUB/v1/keys | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("id") or d["keys"][0]["id"], d.get("key") or d["keys"][0]["key"])')
read FK2ID FK2KEY <<< "$FK2"
curl -s -o /dev/null "$PUB/message/push?pushkey=$FK2KEY&text=删除前发的"
chk "未吊销的 pushkey 不能删除" "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer $FT" $PUB/v1/keys/$FK2ID)" 409
curl -s -o /dev/null -X POST -H "Authorization: Bearer $FT" $PUB/v1/keys/$FK2ID/revoke
chk "吊销后可以删除，列表里不再出现" "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer $FT" $PUB/v1/keys/$FK2ID) $(curl -s -H "Authorization: Bearer $FT" $PUB/v1/keys | python3 -c 'import sys,json;print([k["name"] for k in json.load(sys.stdin)["keys"]])')" "204 ['default']"
chk "删除 pushkey 后历史消息保留" "$(curl -s -H "Authorization: Bearer $FT" "$PUB/v1/messages?since=0" | python3 -c 'import sys,json;print("删除前发的" in [m["text"] for m in json.load(sys.stdin)["messages"]])')" True
chk "不能删除别的账号的 pushkey" "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer $FT" $PUB/v1/keys/1)" 404
chk "其他账号收不到" "$(curl -s -H "Authorization: Bearer $LT3" "$PUB/v1/messages?since=0" | python3 -c 'import sys,json;print("给家人" in [m["text"] for m in json.load(sys.stdin)["messages"]])')" "False"
chk "后台按设备 ID 跨账号搜索并标出账号" "$(curl -s -b $J2 "$ADM/devices?q=$FID" | grep -c '家人</span>')" 1
# 管理后台：在另一个标签页切换了账号后，旧页面提交的写操作被拒绝
OWNER_ID=$(curl -s -b $J2 $ADM/accounts | grep -oE 'switch\?u=[0-9]+' | head -1 | grep -oE '[0-9]+')
curl -s -b $J2 -c $J2 -o /dev/null "$ADM/switch?u=$OWNER_ID&back=/"
FAMID=$(curl -s -b $J2 $ADM/accounts | grep -oE 'action="/accounts/[0-9]+/disable"' | head -1 | grep -oE '[0-9]+')
chk "表单里的账号和当前账号不一致时拒绝写入" "$(curl -s -b $J2 -o /dev/null -w '%{redirect_url}' -H "Origin: $ADM" -d u=$FAMID -X POST $ADM/pair | grep -c 'code=')" 0
curl -s -b $J2 -o /dev/null -H "Origin: $ADM" --data-urlencode "username=  Alex   Chen " -d password=space-pass-1 $ADM/accounts
chk "用户名中间可以有空格；登录时不区分大小写、空格数量" "$(curl -s "${J[@]}" -d '{"username":"alex chen","password":"space-pass-1","name":"x","platform":"test"}' $PUB/v1/login | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("account",{}).get("username") or ("token" in d))')" True
curl -s -b $J2 -o /dev/null -H "Origin: $ADM" --data-urlencode "username=bad/name" -d password=space-pass-1 $ADM/accounts
chk "用户名不能有其它符号；空格合并后保存" "$(P=$(curl -s -b $J2 $ADM/accounts); echo "$P" | grep -c 'bad/name'; echo "$P" | grep -c '<b>Alex Chen</b>')" "$(printf '0\n1')"
chk "账号页列出账号" "$(curl -s -b $J2 $ADM/accounts | grep -c '<b>家人</b>')" 1
curl -s -b $J2 -o /dev/null -H "Origin: $ADM" -d on=1 $ADM/accounts/register
REG=$(printf '{"username":"自助用户","password":"self-pass-1","name":"x","platform":"macos"}')
chk "开放注册后可以注册" "$(curl -s "${J[@]}" -d "$REG" $PUB/v1/register | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"][:3])')" "DT_"
chk "用户名重复返回 409" "$(curl -s -o /dev/null -w '%{http_code}' "${J[@]}" -d "$REG" $PUB/v1/register)" 409
# 只发一次（登录 / 注册按 IP 限速每分钟 20 次，多发会让后面的登录被限速）
chk "注册时用户名不合法返回 400（不是 500）" "$(curl -s -o /dev/null -w '%{http_code}' "${J[@]}" -d '{"username":"a/b","password":"pass-new-1"}' $PUB/v1/register)" 400
curl -s -b $J2 -o /dev/null -H "Origin: $ADM" -d on=0 $ADM/accounts/register
FUID=$(curl -s -b $J2 $ADM/accounts | grep -oE 'action="/accounts/[0-9]+/disable"' | head -1 | grep -oE '[0-9]+')   # 第一个账号没有停用按钮，第一条就是「家人」
curl -s -b $J2 -o /dev/null -H "Origin: $ADM" -d on=1 $ADM/accounts/$FUID/disable
chk "停用账号后设备被拒绝" "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $FT" $PUB/v1/me)" 403
chk "停用账号后 pushkey 不能发送" "$(curl -s -o /dev/null -w '%{http_code}' "$PUB/message/push?pushkey=$FKEY&text=x")" 403
curl -s -b $J2 -o /dev/null -H "Origin: $ADM" -d on=0 $ADM/accounts/$FUID/disable
chk "重新启用后恢复" "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $FT" $PUB/v1/me)" 200
# 按设备接收规则（用户主账号：LT3 = 笔记本，DT3 = 手机）
KA=$(curl -s "${J[@]}" -H "Authorization: Bearer $LT3" -d '{"name":"告警"}' $PUB/v1/keys); KAID=$(echo "$KA" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])'); KAKEY=$(echo "$KA" | python3 -c 'import sys,json;print(json.load(sys.stdin)["key"])')
KB=$(curl -s "${J[@]}" -H "Authorization: Bearer $LT3" -d '{"name":"日常"}' $PUB/v1/keys); KBID=$(echo "$KB" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])'); KBKEY=$(echo "$KB" | python3 -c 'import sys,json;print(json.load(sys.stdin)["key"])')
curl -s -o /dev/null -X PUT "${J[@]}" -H "Authorization: Bearer $LT3" -d '{"mode":"off"}' $PUB/v1/subscriptions/$KAID
curl -s -o /dev/null -X PUT "${J[@]}" -H "Authorization: Bearer $LT3" -d '{"mode":"silent"}' $PUB/v1/subscriptions/$KBID
chk "非法 mode 被拒绝" "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "${J[@]}" -H "Authorization: Bearer $LT3" -d '{"mode":"loud"}' $PUB/v1/subscriptions/$KBID)" 400
chk "不能设置别的账号的 key" "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "${J[@]}" -H "Authorization: Bearer $FT" -d '{"mode":"off"}' $PUB/v1/subscriptions/$KBID)" 404
MAXL=$(curl -s -H "Authorization: Bearer $LT3" "$PUB/v1/messages?since=-1&limit=1" | python3 -c 'import sys,json;m=json.load(sys.stdin)["messages"];print(m[-1]["id"] if m else 0)')
MAXP=$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=-1&limit=1" | python3 -c 'import sys,json;m=json.load(sys.stdin)["messages"];print(m[-1]["id"] if m else 0)')
curl -s -o /dev/null "$PUB/message/push?pushkey=$KAKEY&text=告警消息&priority=4"
curl -s -o /dev/null "$PUB/message/push?pushkey=$KBKEY&text=日常消息"
curl -s -o /dev/null "$PUB/message/push?pushkey=$KBKEY&text=日常紧急&priority=5"
chk "笔记本：不接收告警，日常静默，紧急照常提醒" "$(curl -s -H "Authorization: Bearer $LT3" "$PUB/v1/messages?since=$MAXL" | python3 -c 'import sys,json;print([(m["text"],m.get("silent",False)) for m in json.load(sys.stdin)["messages"]])')" "[('日常消息', True), ('日常紧急', False)]"
chk "手机（默认规则）三条都收到且提醒" "$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=$MAXP" | python3 -c 'import sys,json;print([(m["text"],m.get("silent",False),m["pushkey_id"]>0) for m in json.load(sys.stdin)["messages"]])')" "[('告警消息', False, True), ('日常消息', False, True), ('日常紧急', False, True)]"
chk "/v1/subscriptions 返回本机规则" "$(curl -s -H "Authorization: Bearer $LT3" $PUB/v1/subscriptions | python3 -c 'import sys,json;d=json.load(sys.stdin);print(sorted((s["name"],s["mode"]) for s in d["subscriptions"] if s["name"] in ("告警","日常")), d["away_silent"])')" "[('告警', 'off'), ('日常', 'silent')] True"
# 长轮询：不接收的 key 发来的消息不会让笔记本提前返回
MAXL=$(curl -s -H "Authorization: Bearer $LT3" "$PUB/v1/messages?since=-1&limit=1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["messages"][-1]["id"])')
( sleep 1; curl -s -o /dev/null "$PUB/message/push?pushkey=$KAKEY&text=告警2" ) &
T0=$(date +%s); LP=$(curl -s -H "Authorization: Bearer $LT3" "$PUB/v1/messages?since=$MAXL&wait=3"); T1=$(date +%s)
chk "长轮询：不接收的消息不唤醒，等到超时返回空" "$(echo "$LP" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["messages"]))') $(( T1-T0 >= 3 ))" "0 1"
chk "返回 next_since：不接收的消息也算扫过，游标照样前进" "$(echo "$LP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["next_since"] > '"$MAXL"')')" True
# 在用设备优先：笔记本有人在用 → 手机的非紧急消息静默
MAXP=$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=-1&limit=1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["messages"][-1]["id"])')
chk "上报在用" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $LT3" $PUB/v1/presence)" 204
curl -s -o /dev/null "$PUB/message/push?pushkey=$KBKEY&text=在用时普通"
curl -s -o /dev/null "$PUB/message/push?pushkey=$KBKEY&text=在用时紧急&priority=5"
chk "笔记本在用：手机普通消息静默、紧急照常" "$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=$MAXP" | python3 -c 'import sys,json;print([(m["text"],m.get("silent_reason","")) for m in json.load(sys.stdin)["messages"]])')" "[('在用时普通', 'active_elsewhere'), ('在用时紧急', '')]"
curl -s -o /dev/null -X POST -H "Authorization: Bearer $DT3" $PUB/v1/presence
chk "两台都在用：手机照常提醒（不会两边都不响）" "$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=$MAXP" | python3 -c 'import sys,json;print([m.get("silent",False) for m in json.load(sys.stdin)["messages"]])')" "[False, False]"
curl -s -o /dev/null -X PATCH "${J[@]}" -H "Authorization: Bearer $DT3" -d '{"away_silent":false}' $PUB/v1/me
chk "手机关掉「在用设备优先」后照常提醒" "$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=$MAXP" | python3 -c 'import sys,json;print([m.get("silent",False) for m in json.load(sys.stdin)["messages"]])')" "[False, False]"
# 删除 / 归档消息：从账号删除，附件文件一起删；同账号其他设备通过长轮询立即同步
MK=$(curl -s "${J[@]}" -H "Authorization: Bearer $LT3" -d '{"name":"消息管理测试"}' $PUB/v1/keys | python3 -c 'import sys,json;print(json.load(sys.stdin)["key"])')
CS=$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=-1&limit=1&changes_since=-1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["changes_next"])')
TOPM=$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=-1&limit=1" | python3 -c 'import sys,json;m=json.load(sys.stdin)["messages"];print(m[-1]["id"] if m else 0)')
echo "附件内容" > $T/del.txt
./bin/huijian push -u $PUB -k $MK -f $T/del.txt "要删的带附件" >/dev/null
curl -s -o /dev/null "$PUB/message/push?pushkey=$MK&text=要归档的"
curl -s -o /dev/null "$PUB/message/push?pushkey=$MK&text=后台删的"
MM=$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=$TOPM")
MID() { echo "$MM" | python3 -c 'import sys,json;print([m["id"] for m in json.load(sys.stdin)["messages"] if m["text"]==sys.argv[1]][0])' "$1"; }
DEL=$(MID 要删的带附件); ARC=$(MID 要归档的); ADEL=$(MID 后台删的)
DATT=$(echo "$MM" | python3 -c 'import sys,json;print([m for m in json.load(sys.stdin)["messages"] if m["text"]=="要删的带附件"][0]["attachments"][0]["id"])')
DPATH=$(find $T/data -name del.txt | head -1)
# 手机（DT3）在长轮询等待，笔记本（LT3）删除：手机应在 3 秒内收到删除
TOPM2=$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=-1&limit=1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["messages"][-1]["id"])')
( T0=$(date +%s); R=$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=$TOPM2&wait=20&changes_since=$CS"); echo "$(( $(date +%s)-T0 )) $R" > $T/lp_changes.txt ) &
LPC=$!; sleep 1
# 请求体先放进变量：JSON 的引号嵌在 "$( … )" 里时，bash 会把 {…,…} 当成花括号展开拆成两个请求
# 「家人」账号的消息（家人账号此时已停用，直接查数据库拿 id）
OTHER=$(python3 -c 'import sqlite3,sys;c=sqlite3.connect("file:"+sys.argv[1]+"?mode=ro",uri=True);print(c.execute("select id from messages where text=?",("给家人",)).fetchone()[0])' $T/data/huijian.db)
BDEL=$(printf '{"ids":[%s,%s]}' "$DEL" "$OTHER"); BARC=$(printf '{"ids":[%s],"state":1}' "$ARC"); BBAD=$(printf '{"ids":[%s],"state":7}' "$ARC")
chk "删除消息（只删本账号的）" "$(curl -s "${J[@]}" -H "Authorization: Bearer $LT3" -d "$BDEL" $PUB/v1/messages/delete | python3 -c 'import sys,json;print(json.load(sys.stdin)["deleted"])')" 1
wait $LPC
chk "另一台设备的长轮询立即收到删除" "$(python3 -c 'import sys,json;t,r=open(sys.argv[1]).read().split(" ",1);d=json.loads(r);print(int(t)<=3, [(c["id"],c["kind"]) for c in d["changes"]]==[(int(sys.argv[2]),"delete")])' $T/lp_changes.txt $DEL)" "True True"
CS=$(python3 -c 'import sys,json;print(json.loads(open(sys.argv[1]).read().split(" ",1)[1])["changes_next"])' $T/lp_changes.txt)
chk "删除后附件文件和下载链接都没了" "$([ -f "$DPATH" ] && echo 存在 || echo 无) $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $DT3" $PUB/v1/att/$DATT)" "无 404"
chk "其他账号的消息不受影响" "$(python3 -c 'import sqlite3,sys;c=sqlite3.connect("file:"+sys.argv[1]+"?mode=ro",uri=True);print(c.execute("select count(*) from messages where id=?",(int(sys.argv[2]),)).fetchone()[0])' $T/data/huijian.db $OTHER)" 1
chk "归档" "$(curl -s "${J[@]}" -H "Authorization: Bearer $LT3" -d "$BARC" $PUB/v1/messages/archive | python3 -c 'import sys,json;print(json.load(sys.stdin)["updated"])')" 1
chk "其他设备拿到归档变更，消息本身也带归档状态" "$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=$TOPM&changes_since=$CS" | python3 -c 'import sys,json;d=json.load(sys.stdin);print([(c["id"],c["kind"],c["state"]) for c in d["changes"]]==[(int(sys.argv[1]),"archive",1)], [m.get("archive",0) for m in d["messages"] if m["id"]==int(sys.argv[1])])' $ARC)" "True [1]"
chk "归档状态不合法被拒绝" "$(curl -s -o /dev/null -w '%{http_code}' "${J[@]}" -H "Authorization: Bearer $LT3" -d "$BBAD" $PUB/v1/messages/archive)" 400
curl -s -b $J2 -o /dev/null -H "Origin: $ADM" -X POST $ADM/messages/$ADEL/delete
chk "管理后台删除消息" "$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=$TOPM" | python3 -c 'import sys,json;print(sorted(m["text"] for m in json.load(sys.stdin)["messages"]))')" "['要归档的']"
chk "对账接口：只有本账号的消息，带归档状态，游标与变更一致" "$(curl -s -H "Authorization: Bearer $DT3" $PUB/v1/messages/state | python3 -c 'import sys,json;d=json.load(sys.stdin);ids={i:a for i,a in d["items"]};print(int(sys.argv[1]) in ids, ids.get(int(sys.argv[2])), int(sys.argv[3]) in ids, int(sys.argv[4]) in ids, d["changes_next"]>0)' $DEL $ARC $OTHER $ADEL)" "False 1 False False True"
chk "没有带 changes_since 的旧客户端不受影响" "$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=$TOPM" | python3 -c 'import sys,json;print("changes" in json.load(sys.stdin))')" False

# 频道设置：改名、静音、隐藏、排序、删除频道（同账号所有设备共用）
CS2=$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=-1&limit=1&changes_since=-1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["changes_next"])')
BCH=$(printf '{"topic":"%s","alias":"%s","muted":true}' chtest "测试 频道"); BHID='{"topic":"chhide","hidden":true}'; BORD='{"topics":["chhide","chtest"]}'
chk "频道改名 + 静音" "$(curl -s -X PATCH "${J[@]}" -H "Authorization: Bearer $LT3" -d "$BCH" $PUB/v1/channels | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["alias"],d["muted"],d["hidden"])')" "测试 频道 True False"
curl -s -o /dev/null -X PATCH "${J[@]}" -H "Authorization: Bearer $LT3" -d "$BHID" $PUB/v1/channels
chk "频道排序" "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "${J[@]}" -H "Authorization: Bearer $LT3" -d "$BORD" $PUB/v1/channels/order)" 204
chk "其他设备拿到频道设置和变更通知" "$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=$TOPM&changes_since=$CS2" | python3 -c 'import sys,json;print(sorted({c["kind"] for c in json.load(sys.stdin)["changes"]}))') $(curl -s -H "Authorization: Bearer $DT3" $PUB/v1/channels | python3 -c 'import sys,json;print(sorted((c["topic"],c["sort"],c["hidden"]) for c in json.load(sys.stdin)["channels"]))')" "['channels'] [('chhide', 1, True), ('chtest', 2, False)]"
CHM=$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=-1&limit=1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["messages"][-1]["id"])')
for x in "chtest&priority=3" "chtest&priority=5" "chhide&priority=5"; do curl -s -o /dev/null "$PUB/message/push?pushkey=$MK&text=ch&topic=$x"; done
chk "静音频道普通消息静默、紧急照常；隐藏频道紧急也静默" "$(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=$CHM" | python3 -c 'import sys,json;print([(m["topic"],m["priority"],m.get("silent_reason","")) for m in json.load(sys.stdin)["messages"]])')" "[('chtest', 3, 'channel_muted'), ('chtest', 5, ''), ('chhide', 5, 'channel_hidden')]"
chk "删除频道：全部消息删除，设置清掉" "$(curl -s "${J[@]}" -H "Authorization: Bearer $LT3" -d '{"topic":"chtest"}' $PUB/v1/channels/delete | python3 -c 'import sys,json;print(json.load(sys.stdin)["deleted"])') $(curl -s -H "Authorization: Bearer $DT3" "$PUB/v1/messages?since=$CHM" | python3 -c 'import sys,json;print([m["topic"] for m in json.load(sys.stdin)["messages"]])') $(curl -s -H "Authorization: Bearer $DT3" $PUB/v1/channels | python3 -c 'import sys,json;print([c["topic"] for c in json.load(sys.stdin)["channels"]])')" "2 ['chhide'] ['chhide']"
chk "显示名太长被拒绝" "$(curl -s -o /dev/null -w '%{http_code}' -X PATCH "${J[@]}" -H "Authorization: Bearer $LT3" -d "{\"topic\":\"x\",\"alias\":\"$(python3 -c 'print("长"*33)')\"}" $PUB/v1/channels)" 400

# 账号配对码、移除设备、退出登录
# 配对接口按 IP 限速（每分钟 10 次、最多连发 5 次），前面刚配对过好几台，等额度恢复一些
sleep 7
PC=$(curl -s -X POST -H "Authorization: Bearer $LT3" $PUB/v1/pair-codes | python3 -c 'import sys,json;print(json.load(sys.stdin)["code"])')
PAIRC=$(printf '{"code":"%s","name":"新 iPad","platform":"ios"}' "$PC")
RC=$(curl -s "${J[@]}" -d "$PAIRC" $PUB/v1/pair); CT=$(echo "$RC" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])'); CID=$(echo "$RC" | python3 -c 'import sys,json;print(json.load(sys.stdin)["device_id"])')
chk "设备生成的配对码：新设备直接进入本账号、没有服务器管理权限" "$(curl -s -H "Authorization: Bearer $CT" $PUB/v1/me | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["account"]["username"], d["can_admin"])')" "owner1 False"
chk "没有管理权限的设备不能移除有管理权限的设备" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $DT3" $PUB/v1/devices/$DID2/revoke)" 403
chk "配对码有效期 3 分钟" "$(curl -s -X POST -H "Authorization: Bearer $DT3" $PUB/v1/pair-codes | python3 -c 'import sys,json;print(json.load(sys.stdin)["expires_in"])')" 180
chk "配对码状态：已被哪台设备使用" "$(curl -s -H "Authorization: Bearer $LT3" $PUB/v1/pair-codes/$PC | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["state"], d["used_by"])')" "used 新 iPad"
PCS=(); for i in 1 2 3; do PCS+=("$(curl -s -X POST -H "Authorization: Bearer $DT3" $PUB/v1/pair-codes | python3 -c 'import sys,json;print(json.load(sys.stdin).get("code",""))')"); done
chk "同一台设备重新生成：旧配对码立即作废，只有最新的有效" "$(curl -s -H "Authorization: Bearer $DT3" $PUB/v1/pair-codes/${PCS[0]} | python3 -c 'import sys,json;print(json.load(sys.stdin)["state"])') $(curl -s -H "Authorization: Bearer $DT3" $PUB/v1/pair-codes/${PCS[2]} | python3 -c 'import sys,json;print(json.load(sys.stdin)["state"])')" "expired waiting"
chk "查不到别的账号的配对码" "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $FT" $PUB/v1/pair-codes/${PCS[2]})" 404
chk "移除本账号的另一台设备" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $LT3" $PUB/v1/devices/$CID/revoke) $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $CT" $PUB/v1/me)" "200 401"
chk "不能移除别的账号的设备" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $FT" $PUB/v1/devices/$LID/revoke)" 404
chk "退出登录后 token 失效" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $LT3" $PUB/v1/logout) $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $LT3" $PUB/v1/me)" "200 401"
# 存储与备份
ST=$(curl -s -H "Authorization: Bearer $DT2" "$PUB/v1/storage?fresh=1")
chk "允许管理的设备查看存储状态" "$(echo "$ST" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["files_ok"], d["backup_enabled"], d["version"])')" "True True $(./bin/huijian version)"
chk "开始备份返回 202" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $DT2" $PUB/v1/storage/backup)" 202
for i in $(seq 1 30); do R=$(curl -s -H "Authorization: Bearer $DT2" $PUB/v1/storage | python3 -c 'import sys,json;print(json.load(sys.stdin)["running"])'); [ "$R" = False ] && break; sleep 0.2; done
chk "备份完成且成功" "$(curl -s -H "Authorization: Bearer $DT2" $PUB/v1/storage | python3 -c 'import sys,json;l=json.load(sys.stdin)["last"];print(l["ok"], l["db"][:8])')" "True huijian-"
chk "备份目录里有数据库快照" "$(ls $T/data/backups/db/ | grep -c '^huijian-.*\.db$')" 1
chk "设置页有存储与备份卡片" "$(curl -s -b $J2 $ADM/settings | grep -c '存储与备份')" 1
NEWATT=$(curl -s $PUB/message/push -F pushkey=$CK3 -F "text=附件/路径:测试" -F "file=@tests/e2e_local.sh;filename=../../逃逸.txt" | python3 -c 'import sys,json;print(json.load(sys.stdin)["code"])')
chk "带 ../ 的附件名安全落盘" "$NEWATT $(find $T/data/files -name '*逃逸.txt' | grep -c "/$(date +%Y)/")" "0 1"
grep -q "模板渲染失败" $T/hub.log && ng "日志中有模板错误" || ok "0.5.0 页面无模板错误"
chk "管理后台标签页图标" "$(curl -s -o /dev/null -w "%{http_code} %{content_type}" $ADM/favicon.png) $(curl -s $ADM/login | grep -c "rel=\"icon\"")" "200 image/png 1"

echo; echo "结果：通过 ${pass}，失败 ${fail}"
[ $fail -eq 0 ]
