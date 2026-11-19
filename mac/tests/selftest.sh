#!/usr/bin/env bash
# 起独立 hub（默认 127.0.0.1:28790/28791），准备 pushkey、配对码、历史消息，然后跑 Huijian --selftest。
# 使用仓库内 server/ 编译出的 huijian（若不存在会自动编译）。
# 用法: tests/selftest.sh [监听IP，默认 127.0.0.1]
set -u
cd "$(dirname "$0")/.."
# 二进制不存在、或 server 源码比它新时重新编译（避免拿旧服务端测新功能）
if [ ! -x ../server/bin/huijian ] || [ -n "$(find ../server -name '*.go' -newer ../server/bin/huijian | head -1)" ]; then
  (cd ../server && GOTOOLCHAIN=local go build -o bin/huijian .) || exit 1
fi
IP=${1:-127.0.0.1}
T=test-run.noindex; rm -rf $T test-run; mkdir -p $T/data   # .noindex：测试用的 App 副本不进 Spotlight
PUB=http://$IP:28790; ADM=http://127.0.0.1:28791
HUIJIAN_DATA=$T/data HUIJIAN_PUBLIC_ADDR=$IP:28790 HUIJIAN_ADMIN_ADDR=127.0.0.1:28791 \
  ../server/bin/huijian hub > $T/hub.log 2>&1 &
HUB=$!; trap 'kill $HUB 2>/dev/null' EXIT
for i in $(seq 1 30); do curl -sf $PUB/healthz >/dev/null && break; sleep 0.2; done
J=$T/cookies
curl -s -c $J -o /dev/null -d "token=$(cat $T/data/admin.token)" $ADM/login
LOC=$(curl -s -b $J -o /dev/null -w '%{redirect_url}' -H "Origin: $ADM" --data-urlencode "name=mac selftest" $ADM/pushkeys)
PK=$(python3 -c "import sys,urllib.parse as u;print(u.parse_qs(u.urlparse(sys.argv[1]).query)['key'][0])" "$LOC")
CODE=$(curl -s -b $J -o /dev/null -w '%{redirect_url}' -H "Origin: $ADM" -X POST $ADM/pair | sed -E 's/.*code=([0-9]+).*/\1/')
ACODE=$(curl -s -b $J -o /dev/null -w '%{redirect_url}' -H "Origin: $ADM" -d can_admin=on $ADM/pair | sed -E 's/.*code=([0-9]+).*/\1/')
KCODE=$(curl -s -b $J -o /dev/null -w '%{redirect_url}' -H "Origin: $ADM" -d can_admin=on $ADM/pair | sed -E 's/.*code=([0-9]+).*/\1/')
# 历史消息：一条纯文字，一条带 PNG + PDF
python3 - $T/loss.png $T/report.pdf <<'PY'
import sys,zlib,struct
w,h=320,200
def chunk(t,d): return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
rows=b''.join(b'\x00'+b''.join(bytes([x*255//w,y*255//h,160]) for x in range(w)) for y in range(h))
open(sys.argv[1],'wb').write(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b''))
pdf=b"""%PDF-1.4
1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 200]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj
4 0 obj<</Length 44>>stream
BT /F1 24 Tf 40 100 Td (Weekly report) Tj ET
endstream endobj
5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj
trailer<</Root 1 0 R>>
%%EOF
"""
open(sys.argv[2],'wb').write(pdf)
PY
curl -s -o /dev/null "$PUB/message/push?pushkey=$PK&text=%E8%AE%AD%E7%BB%83%E5%BC%80%E5%A7%8B&priority=4&topic=train&thread=exp42"
../server/bin/huijian push -u $PUB -k $PK -p 3 -topic train -thread exp42 -d "val_loss **0.231**" -f $T/loss.png -f $T/report.pdf "exp42 评估图" >/dev/null
# 覆盖全部回笺 Markdown 语法的消息（服务端 0.6.0 解析成 doc），正文用 attachment: 引用图片和 PDF，huijian://message/1 指向第一条
../server/bin/huijian push -u $PUB -k $PK -p 3 -topic train -thread exp43 -d "$(sed 's/E42_ID/1/' tests/markdown_demo.md)" \
  -f $T/loss.png -f $T/report.pdf "exp43 训练报告" >/dev/null
echo "hub=$PUB pushkey=${PK:0:6}… code=$CODE"
# 应用内更新：用测试私钥签名一个 build+1 的包并发布；再准备一份当前 App 的副本作为安装目标
HY=../server/bin/huijian; PL=build/Huijian.app/Contents/Info.plist
UKEY=$T/update.key; UPUB=$($HY release-key $UKEY)
CUR=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' $PL); NEXT=$((CUR+1))
VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $PL)
mkdir -p $T/upd $T/inst && ditto build/Huijian.app $T/upd/Huijian.app && ditto build/Huijian.app $T/inst/Huijian.app
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT" $T/upd/Huijian.app/Contents/Info.plist
tools/codesign_app.sh $T/upd/Huijian.app
(cd $T/upd && ditto -c -k --keepParent Huijian.app ../upd.zip)
HUIJIAN_ADMIN_URL=$ADM HUIJIAN_ADMIN_TOKEN=$(cat $T/data/admin.token) $HY release -key $UKEY -version $VER -build $NEXT -notes "selftest" $T/upd.zip >/dev/null \
  || { echo "发布测试更新包失败"; exit 1; }
# GitHub 更新源与代理：另一把测试私钥签名清单，本地模拟 GitHub API 和 HTTP 代理
GKEY=$T/gh.key; GPUB=$($HY release-key $GKEY); mkdir -p $T/gh
GNOTES="github channel selftest"
cp $T/upd.zip $T/gh/Huijian-$VER-$NEXT.zip
python3 tools/make_manifest.py $HY $GKEY $VER $NEXT "$GNOTES" $T/gh/Huijian-$VER-$NEXT.zip > $T/gh/update-macos.json
: > $T/mock.log
python3 tests/mock_net.py 28795 28796 $T/gh $T/mock.log & MOCK=$!
trap 'kill $HUB $MOCK 2>/dev/null' EXIT
for i in $(seq 1 20); do curl -sf http://127.0.0.1:28795/zen >/dev/null && break; sleep 0.2; done
TARGET="$PWD/$T/inst/Huijian.app"
build/Huijian.app/Contents/MacOS/Huijian --selftest $PUB $CODE $PK --admin-code $ACODE --workdir $T/selftest \
  --update-pub $UPUB --install-target "$TARGET" --keys-code $KCODE \
  --mock-gh-port 28795 --mock-proxy-port 28796 --mock-log $T/mock.log --gh-pub $GPUB --gh-build $NEXT
RC=$?
echo "[15 替换脚本（自检进程退出后）]"
GOT=""
for i in $(seq 1 50); do
  GOT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TARGET/Contents/Info.plist" 2>/dev/null)
  [ "$GOT" = "$NEXT" ] && break; sleep 0.2
done
F2=0
if [ "$GOT" = "$NEXT" ]; then echo "  ✅ 安装目标已替换为 build $NEXT"; else echo "  ❌ 安装目标仍是 build ${GOT:-?}"; F2=1; fi
if codesign --verify --strict "$TARGET" 2>/dev/null; then echo "  ✅ 替换后的 App 签名有效"; else echo "  ❌ 替换后的 App 签名无效"; F2=1; fi
if ls -a $T/inst | grep -q '\.old-'; then echo "  ❌ 残留旧版本目录"; F2=1; else echo "  ✅ 没有残留旧版本"; fi
grep -q "替换完成" $T/selftest/update/install.log 2>/dev/null && echo "  ✅ 替换日志正常" || { echo "  ❌ 替换日志：$(cat $T/selftest/update/install.log 2>/dev/null)"; F2=1; }
# 测试用的 App 副本从 LaunchServices 注销，huijian:// 链接和「打开方式」只指向真正安装的那个
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
find $T -name Huijian.app -type d -prune 2>/dev/null | while read -r a; do $LSR -u "$a" 2>/dev/null; done
[ $RC -eq 0 ] && [ $F2 -eq 0 ]
