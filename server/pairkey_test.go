package main

// 0.10.0 配对码带钥匙（docs/e2ee-client.md §12）：服务器只暂存 hjc1 密文，配对时交给新设备并清空；重置加密时作废

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/sha256"
	"strings"
	"testing"
)

// 和 core/tests/pair.rs 的固定向量一致：S = 00..0f，私钥 = 20..3f，nonce = 40..4b
func TestPairKeyVector(t *testing.T) {
	secret, sk, nonce := make([]byte, 16), make([]byte, 32), make([]byte, 12)
	for i := range secret {
		secret[i] = byte(i)
	}
	for i := range sk {
		sk[i] = byte(0x20 + i)
	}
	for i := range nonce {
		nonce[i] = byte(0x40 + i)
	}
	key, err := hkdf.Key(sha256.New, secret, []byte("huijian pair v1"), "", 32)
	if err != nil {
		t.Fatal(err)
	}
	blk, _ := aes.NewCipher(key)
	gcm, _ := cipher.NewGCM(blk)
	got := "hjc1." + b64of(append(append([]byte{}, nonce...), gcm.Seal(nil, nonce, sk, []byte("hjc1"))...))
	const want = "hjc1.QEFCQ0RFRkdISUpLeMFqsd22Y9NgakDGtkBNmt5ukdq7V-MoxMSTClBRUHvZbe_eR5xJEQTzopfcuNXr"
	if got != want {
		t.Fatalf("向量不一致：\n%s\n%s", got, want)
	}
	if !validPairKeyWrap(want) {
		t.Fatal("合法的 key_wrap 被拒")
	}
	for _, bad := range []string{"", "hjp1." + want[5:], "hjc1.", "hjc1.***", "hjc1." + want[5:len(want)-4], want + strings.Repeat("A", 300)} {
		if validPairKeyWrap(bad) {
			t.Fatalf("不合法的 key_wrap 被接受：%q", bad)
		}
	}
}

func TestPairKeyFlow(t *testing.T) {
	e := newE2EEnv(t)
	const pw = "erin-pass-0001"
	u, _ := e.h.st.CreateAccount("erin", pw)
	_, tokA, _, _ := e.h.st.LoginDevice(pairReq{UserID: u.ID, Name: "mac", Platform: "macos", Fingerprint: "fp-pk-000001"})
	sk := newKey(t)
	body, auth1, _ := keyBody(t, sk, pw)
	body["current_password"] = pw
	e.must(200, "POST", "/v1/e2e/setup", tokA, body)

	if !hasFeature("pair.key") {
		t.Fatal("功能清单里应有 pair.key")
	}
	const wrap = "hjc1.QEFCQ0RFRkdISUpLeMFqsd22Y9NgakDGtkBNmt5ukdq7V-MoxMSTClBRUHvZbe_eR5xJEQTzopfcuNXr"
	// 格式不对的 key_wrap：400，不生成配对码
	e.must(400, "POST", "/v1/pair-codes", tokA, map[string]any{"key_wrap": "hjp1.abc"})
	e.must(400, "POST", "/v1/pair-codes", tokA, map[string]any{"key_wrap": 123})
	if n := e.h.st.ActivePairCodes(u.ID); n != 0 {
		t.Fatalf("被拒的请求不应生成配对码：%d", n)
	}

	// 带钥匙的配对码：配对响应带 key_wrap，随即从数据库清空
	code := e.must(200, "POST", "/v1/pair-codes", tokA, map[string]any{"key_wrap": wrap})["code"].(string)
	var stored string
	e.h.st.db.QueryRow(`SELECT key_wrap FROM pair_codes WHERE code=?`, code).Scan(&stored)
	if stored != wrap {
		t.Fatalf("服务器应暂存 key_wrap：%q", stored)
	}
	out := e.must(200, "POST", "/v1/pair", "", map[string]any{"code": code, "name": "iPhone", "platform": "ios", "fingerprint": "fp-pk-000002"})
	if out["key_wrap"] != wrap || out["token"] == nil {
		t.Fatalf("配对响应应带 key_wrap：%v", out)
	}
	e.h.st.db.QueryRow(`SELECT key_wrap FROM pair_codes WHERE code=?`, code).Scan(&stored)
	if stored != "" {
		t.Fatal("用掉后 key_wrap 应清空")
	}
	e.must(403, "POST", "/v1/pair", "", map[string]any{"code": code, "name": "x", "platform": "ios"})

	// 不带请求体（旧客户端）、空 JSON：照常生成，配对响应没有 key_wrap
	for _, b := range []any{nil, map[string]any{}} {
		c := e.must(200, "POST", "/v1/pair-codes", tokA, b)["code"].(string)
		out = e.must(200, "POST", "/v1/pair", "", map[string]any{"code": c, "name": "安卓", "platform": "android", "fingerprint": "fp-pk-000003"})
		if _, has := out["key_wrap"]; has {
			t.Fatalf("不带钥匙的配对码不应返回 key_wrap：%v", out)
		}
	}

	// 过期的带钥匙配对码：下次生成时清空
	old := e.must(200, "POST", "/v1/pair-codes", tokA, map[string]any{"key_wrap": wrap})["code"].(string)
	e.h.st.db.Exec(`UPDATE pair_codes SET expires_at=? WHERE code=?`, now()-10, old)
	_, tokC, _, _ := e.h.st.LoginDevice(pairReq{UserID: u.ID, Name: "pc", Platform: "windows", Fingerprint: "fp-pk-000004"})
	plain := e.must(200, "POST", "/v1/pair-codes", tokC, nil)["code"].(string)
	e.h.st.db.QueryRow(`SELECT key_wrap FROM pair_codes WHERE code=?`, old).Scan(&stored)
	if stored != "" {
		t.Fatal("过期的配对码 key_wrap 应清空")
	}

	// 重置加密：带钥匙、没用掉的配对码作废；不带钥匙的照常可用
	keyed := e.must(200, "POST", "/v1/pair-codes", tokA, map[string]any{"key_wrap": wrap})["code"].(string)
	reset, _, _ := keyBody(t, newKey(t), pw)
	reset["current_auth_key"] = b64of(auth1)
	e.must(200, "POST", "/v1/e2e/reset", tokA, reset)
	e.must(403, "POST", "/v1/pair", "", map[string]any{"code": keyed, "name": "y", "platform": "ios"})
	e.h.st.db.QueryRow(`SELECT key_wrap FROM pair_codes WHERE code=?`, keyed).Scan(&stored)
	if stored != "" {
		t.Fatal("重置加密后 key_wrap 应清空")
	}
	if s, _, _, _, _ := e.h.st.PairCodeStatus(u.ID, keyed); s != "expired" {
		t.Fatalf("重置后带钥匙的配对码应显示已作废：%s", s)
	}
	e.must(200, "POST", "/v1/pair", "", map[string]any{"code": plain, "name": "z", "platform": "ios", "fingerprint": "fp-pk-000005"})
}

func hasFeature(id string) bool {
	for _, f := range serverFeatures {
		if f.ID == id {
			return true
		}
	}
	return false
}
