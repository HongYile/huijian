#!/usr/bin/env bash
# 在 iOS 模拟器上跑应用内自检（App 带 -selfTest 启动）：纯逻辑测试 + 连本地独立 hub 的集成测试
# （登录、首次同步、补拉、长轮询、附件校验、更新检查和应用内下载新版 IPA 的校验、Bark 设置 / 测试 / 转发、后台刷新、退出登录）。
# 用法：tests/selftest.sh            环境变量 SIM 指定模拟器名称（默认 iPhone 16 Pro）
set -u
cd "$(dirname "$0")/.."
. tests/update_key.sh
UPDATE_PUBKEY=$TEST_UPDATE_PUB ./build.sh sim > /dev/null || { echo "❌ 构建失败"; exit 1; }
. tests/hub.sh
# 用测试密钥发布一个假的新版本（build + 1），自检里下载、校验 sha256 和签名、篡改后拒绝
NEXT=$(( $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' build/sim/Huijian.app/Info.plist) + 1 ))
NEXT_VER=$(awk -F. '{printf "%d.%d.%d", $1, $2, $3 + 1}' VERSION)
head -c 300000 /dev/urandom > $T/fake.ipa
HUIJIAN_ADMIN_URL=$ADM HUIJIAN_ADMIN_TOKEN=$(cat /tmp/huijian-ios-test/data/admin.token) $B release -key "$TEST_UPDATE_KEY" -platform ios \
  -version $NEXT_VER -build $NEXT -notes $'- 自检用的新版本\n- 应用内下载测试' $T/fake.ipa > $T/release.log 2>&1 \
  || { echo "❌ 发布测试版本失败"; cat $T/release.log; exit 1; }
SIM="${SIM:-iPhone 16 Pro}"
UDID=$(xcrun simctl list devices available -j | python3 -c "
import sys,json
for rt,ds in json.load(sys.stdin)['devices'].items():
    for d in ds:
        if d['name']=='$SIM' and 'iOS' in rt: print(d['udid']); sys.exit()")
[ -n "$UDID" ] || { echo "❌ 找不到模拟器 $SIM"; exit 1; }
xcrun simctl boot "$UDID" 2>/dev/null; xcrun simctl bootstatus "$UDID" -b > /dev/null
BID=io.github.hongyile.huijian
xcrun simctl terminate "$UDID" $BID 2>/dev/null
xcrun simctl uninstall "$UDID" $BID 2>/dev/null
xcrun simctl install "$UDID" build/sim/Huijian.app
BKEY=HyTestKey0123456789abcdefABCDEF0; BIV=HyTestIV01234567
xcrun simctl launch --console-pty "$UDID" $BID -selfTest YES -demoServer $PUB -demoUser $DEMO_USER -demoPass $DEMO_PASS \
  -demoBarkURL $BARK_URL -demoBarkKey $BKEY -demoBarkIV $BIV -demoUpdateBuild $NEXT \
  -demoE2EUser $E2E_USER -demoE2EPass $E2E_PASS > $T/selftest.log 2>&1 &
L=$!
# 端到端加密的联网流程要做十几次 Argon2id（每次 0.1–0.4 秒），比原来多给两分钟
for i in $(seq 1 300); do kill -0 $L 2>/dev/null || break; sleep 1; done
kill $L 2>/dev/null
grep -E '^(✅|❌|—|SELFTEST|回笺|（|BARK_)' $T/selftest.log
grep -q 'SELFTEST PASS' $T/selftest.log; RESULT=$?
# ATS：只能有 NSAllowsArbitraryLoads（同时有 NSAllowsLocalNetworking 时前者被忽略，http://域名 会被拦）
if /usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity:NSAllowsLocalNetworking' build/sim/Huijian.app/Info.plist >/dev/null 2>&1; then
  echo "❌ Info.plist 里有 NSAllowsLocalNetworking"; RESULT=1
else echo "✅ Info.plist 的 ATS 只有 NSAllowsArbitraryLoads"; fi

# Bark 端到端：模拟 Bark 收到的请求（服务端转发 + 测试通知），用同样的 Key / IV 解密
echo "— 模拟 Bark 收到的请求（$T/bark.log）"
FID=$(sed -n 's/^BARK_FORWARDED_ID //p' $T/selftest.log | tr -d '\r')
python3 - "$T/bark.log" "$BKEY" "$BIV" "${FID:-0}" <<'PY' || RESULT=1
import json, subprocess, sys
log, key, iv, fid = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
rows = [json.loads(l) for l in open(log)] if fid != "0" else []
def dec(ct):
    out = subprocess.run(["openssl", "enc", "-d", "-aes-256-cbc", "-K", key.encode().hex(), "-iv", iv.encode().hex(), "-base64", "-A"],
                         input=ct.encode(), capture_output=True)
    return json.loads(out.stdout) if out.returncode == 0 else None
for r in rows:  # 加密时参数都在密文里：解开后合并，外面只应有 ciphertext 和 iv
    f = r["form"]
    r["outer"] = sorted(f)
    if "ciphertext" in f:
        r["form"] = {**f, **(dec(f["ciphertext"]) or {})}
ok = True
def check(name, cond, detail=""):
    global ok
    print(("✅ " if cond else "❌ ") + name + ("" if cond else "  " + str(detail)))
    ok = ok and cond
check("Bark 收到 key 不对的测试请求（返回 400）", any(r["key"] == "badkey" for r in rows))
good = [r for r in rows if r["key"] == "hyTestKey123"]
test = [r for r in good if r["form"].get("url") == "huijian://"]
check("Bark 收到加密的测试通知（外面只有 ciphertext、iv）", bool(test) and test[0]["outer"] == ["ciphertext", "iv"], test)
if test:
    p = dec(test[0]["form"]["ciphertext"])
    check("测试通知可用同样的 Key/IV 解密（AES256-CBC）：%s" % (p or {}).get("title"), bool(p) and p.get("title") == "回笺测试", p)
fwd = [r for r in good if r["form"].get("url") == "huijian://message/%s" % fid]
check("新消息 #%s 已转发到 Bark（url=huijian://message/%s）" % (fid, fid), bool(fwd), [r["form"].get("url") for r in good])
if fwd:
    f = fwd[0]["form"]; p = dec(f["ciphertext"])
    check("转发：外面只有 ciphertext、iv", fwd[0]["outer"] == ["ciphertext", "iv"], fwd[0]["outer"])
    check("转发：P4 → level=timeSensitive，group=test", f.get("level") == "timeSensitive" and f.get("group") == "test", f)
    check("转发：解密后标题是测试推送", bool(p) and p.get("title", "").startswith("测试推送"), p)
sys.exit(0 if ok else 1)
PY
if [ $RESULT -eq 0 ]; then echo "自检通过"; else echo "❌ 自检失败（完整日志 $T/selftest.log，hub 日志 $T/hub.log）"; fi
exit $RESULT
