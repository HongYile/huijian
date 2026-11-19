package main

import (
	"bytes"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"flag"
	"os"
	"strings"
	"testing"
)

var updateVectors = flag.Bool("update-e2e-vectors", false, "重新生成 testdata/e2e_vectors.json（跨平台测试向量）")

func unhex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// RFC 9180 官方测试向量：DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 / AES-256-GCM，base 模式
func TestHPKERFC9180Vector(t *testing.T) {
	raw, err := os.ReadFile("testdata/hpke_rfc9180_x25519_sha256_aes256gcm.json")
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		Info, IkmE, IkmR, SkEm, PkEm, SkRm, PkRm, Enc string
		SharedSecret                                  string `json:"shared_secret"`
		Key                                           string
		BaseNonce                                     string `json:"base_nonce"`
		Encryptions                                   []struct{ Aad, Ct, Nonce, Pt string }
	}
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	skE, err := e2eDeriveKeyPair(unhex(t, v.IkmE))
	if err != nil || !bytes.Equal(skE.Bytes(), unhex(t, v.SkEm)) {
		t.Fatalf("DeriveKeyPair(ikmE) 不对：%x", skE.Bytes())
	}
	skR, _ := e2eDeriveKeyPair(unhex(t, v.IkmR))
	if !bytes.Equal(skR.Bytes(), unhex(t, v.SkRm)) || !bytes.Equal(skR.PublicKey().Bytes(), unhex(t, v.PkRm)) {
		t.Fatal("DeriveKeyPair(ikmR) 不对")
	}
	e := v.Encryptions[0] // 回笺每个 HPKE 上下文只加密一条（序号 0）
	enc, ct, err := hpkeSeal(skR.PublicKey(), unhex(t, v.Info), unhex(t, e.Aad), unhex(t, e.Pt), skE)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(enc, unhex(t, v.Enc)) || !bytes.Equal(ct, unhex(t, e.Ct)) {
		t.Fatalf("加密结果和 RFC 向量不一致：enc=%x ct=%x", enc, ct)
	}
	pt, err := hpkeOpen(skR, enc, unhex(t, v.Info), unhex(t, e.Aad), ct)
	if err != nil || !bytes.Equal(pt, unhex(t, e.Pt)) {
		t.Fatal("解密 RFC 向量失败")
	}
	ct[0] ^= 1
	if _, err := hpkeOpen(skR, enc, unhex(t, v.Info), unhex(t, e.Aad), ct); err == nil {
		t.Fatal("篡改后的密文不应解开")
	}
}

func TestE2EMessageRoundTrip(t *testing.T) {
	sk, _ := ecdh.X25519().GenerateKey(rand.Reader)
	other, _ := ecdh.X25519().GenerateKey(rand.Reader)
	payload := []byte(`{"v":1,"text":"exp42 完成","desp":"val_loss **0.198**"}`)
	env, err := e2eSealMessage(sk.PublicKey(), payload)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(env, "hje1."+e2eKID(sk.PublicKey().Bytes())+".") {
		t.Fatalf("信封格式不对：%s", env[:30])
	}
	if strings.Contains(env, "exp42") {
		t.Fatal("信封里不应出现明文")
	}
	if pt, err := e2eOpenMessage(sk, env); err != nil || !bytes.Equal(pt, payload) {
		t.Fatalf("解密失败：%v", err)
	}
	if _, err := e2eOpenMessage(other, env); err == nil {
		t.Fatal("别的钥匙不应解开")
	}
	// 同一内容两次加密结果不同（一次性密钥）
	env2, _ := e2eSealMessage(sk.PublicKey(), payload)
	if env2 == env {
		t.Fatal("两次加密结果不应相同")
	}
	// 改动信封任何一处都解不开（包括把 kid 换成别的、截断）
	kid, body, _ := e2eParseEnvelope(env)
	body[len(body)-1] ^= 1
	if _, err := e2eOpenMessage(sk, "hje1."+kid+"."+b64.EncodeToString(body)); err == nil {
		t.Fatal("篡改后不应解开")
	}
	for _, bad := range []string{"", "hje1.", "hje1.zz.abc", "hye2." + env[5:], env[:40]} {
		if _, _, err := e2eParseEnvelope(bad); err == nil {
			t.Fatalf("格式错误的信封应被拒绝：%q", bad)
		}
	}
}

func TestE2EFileChunks(t *testing.T) {
	key := bytes.Repeat([]byte{7}, 32)
	for _, size := range []int{0, 1, e2eChunk - 1, e2eChunk, e2eChunk + 1, 3*e2eChunk + 123} {
		src := make([]byte, size)
		for i := range src {
			src[i] = byte(i * 31)
		}
		var ct bytes.Buffer
		if err := e2eEncryptFile(key, bytes.NewReader(src), &ct); err != nil {
			t.Fatal(err)
		}
		chunks := size/e2eChunk + 1
		if size > 0 && size%e2eChunk == 0 {
			chunks = size / e2eChunk
		}
		if want := e2eHdrLen + size + 16*chunks; ct.Len() != want {
			t.Fatalf("大小 %d：密文 %d 字节，期望 %d", size, ct.Len(), want)
		}
		var out bytes.Buffer
		if err := e2eDecryptFile(key, bytes.NewReader(ct.Bytes()), &out); err != nil || !bytes.Equal(out.Bytes(), src) {
			t.Fatalf("大小 %d：解密失败 %v", size, err)
		}
		c := ct.Bytes()
		blk := e2eChunk + 16
		if chunks >= 2 {
			// 截掉最后一块：倒数第二块没有末块标记，必须报错
			if e2eDecryptFile(key, bytes.NewReader(c[:e2eHdrLen+(chunks-1)*blk]), &bytes.Buffer{}) == nil {
				t.Fatalf("大小 %d：截断后不应解开", size)
			}
		}
		if chunks > 2 {
			// 交换前两块（都是满块）
			sw := append([]byte{}, c...)
			copy(sw[e2eHdrLen:], c[e2eHdrLen+blk:e2eHdrLen+2*blk])
			copy(sw[e2eHdrLen+blk:], c[e2eHdrLen:e2eHdrLen+blk])
			if e2eDecryptFile(key, bytes.NewReader(sw), &bytes.Buffer{}) == nil {
				t.Fatalf("大小 %d：换序后不应解开", size)
			}
		}
		bad := append([]byte{}, c...)
		bad[len(bad)-1] ^= 1
		if e2eDecryptFile(key, bytes.NewReader(bad), &bytes.Buffer{}) == nil {
			t.Fatalf("大小 %d：篡改后不应解开", size)
		}
	}
}

func TestE2EWrapAndRecovery(t *testing.T) {
	code := []byte("0123456789abcdef")
	s := e2eFormatRecovery(code)
	if len(strings.ReplaceAll(s, "-", "")) != 26 || strings.Count(s, "-") != 4 {
		t.Fatalf("恢复码格式不对：%s", s)
	}
	back, err := e2eParseRecovery(strings.ToLower(strings.ReplaceAll(s, "-", " ")))
	if err != nil || !bytes.Equal(back, code) {
		t.Fatalf("恢复码解析失败：%v", err)
	}
	if _, err := e2eParseRecovery(s[:len(s)-2]); err == nil {
		t.Fatal("太短的恢复码应被拒绝")
	}
	secret := []byte("account private key 32 bytes....")
	w, err := e2eWrap("hjr1", e2eRecoveryKey(code), secret)
	if err != nil {
		t.Fatal(err)
	}
	if pt, err := e2eUnwrap("hjr1", e2eRecoveryKey(code), w); err != nil || !bytes.Equal(pt, secret) {
		t.Fatal("恢复码解锁失败")
	}
	if _, err := e2eUnwrap("hjr1", e2eRecoveryKey([]byte("0123456789abcdeX")), w); err == nil {
		t.Fatal("错误的恢复码不应解开")
	}
	if _, err := e2eUnwrap("hjp1", e2eRecoveryKey(code), w); err == nil {
		t.Fatal("前缀不同不应解开（防止把一种副本当另一种用）")
	}
}

func TestE2EPasswordKeys(t *testing.T) {
	salt := []byte("0123456789abcdef")
	a1, u1 := e2ePasswordKeys("correct horse battery", salt)
	a2, u2 := e2ePasswordKeys("correct horse battery", salt)
	a3, _ := e2ePasswordKeys("correct horse batterz", salt)
	if !bytes.Equal(a1, a2) || !bytes.Equal(u1, u2) || bytes.Equal(a1, a3) || bytes.Equal(a1, u1) {
		t.Fatal("Argon2id 派生结果不对")
	}
}

func TestE2ESendKey(t *testing.T) {
	sk, _ := ecdh.X25519().GenerateKey(rand.Reader)
	s := "PK_abc123" + e2eSendKeySep + b64.EncodeToString(sk.PublicKey().Bytes())
	pk, pub, err := e2eSplitSendKey(s)
	if err != nil || pk != "PK_abc123" || !bytes.Equal(pub.Bytes(), sk.PublicKey().Bytes()) {
		t.Fatalf("解析加密发送密钥失败：%v", err)
	}
	if pk, pub, err := e2eSplitSendKey("PK_plain"); err != nil || pk != "PK_plain" || pub != nil {
		t.Fatal("普通 pushkey 应原样返回")
	}
	if _, _, err := e2eSplitSendKey("PK_x.e2e.short"); err == nil {
		t.Fatal("公钥格式不对应报错")
	}
}

// 跨平台测试向量：Swift / Kotlin / Rust 各端用同一份数据验证解密、附件、恢复码、密码派生的结果一致。
// 用 go test -run TestE2EVectors -update-e2e-vectors 重新生成；平时只校验文件内容和当前实现一致。
func TestE2EVectors(t *testing.T) {
	sk, _ := e2eDeriveKeyPair([]byte("huijian e2e test vector recipient"))
	eph, _ := e2eDeriveKeyPair([]byte("huijian e2e test vector ephemeral"))
	payload := `{"v":1,"text":"exp42 完成","desp":"> [!SUCCESS] val_loss **0.198**\n![曲线](attachment:1)","atts":[{"name":"loss.png","mime":"image/png","size":200000,"key":"BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc"}]}`
	kid := e2eKID(sk.PublicKey().Bytes())
	enc, ct, err := hpkeSeal(sk.PublicKey(), []byte(e2eInfoMessage), []byte(e2eMsgPrefix+kid), []byte(payload), eph)
	if err != nil {
		t.Fatal(err)
	}
	env := e2eMsgPrefix + kid + "." + b64.EncodeToString(append(enc, ct...))
	if pt, err := e2eOpenMessage(sk, env); err != nil || string(pt) != payload {
		t.Fatal("向量自检失败")
	}
	fileKey := bytes.Repeat([]byte{7}, 32)
	file := make([]byte, e2eChunk+100)
	for i := range file {
		file[i] = byte(i % 251)
	}
	var fct bytes.Buffer
	if err := e2eEncryptFile(fileKey, bytes.NewReader(file), &fct); err != nil {
		t.Fatal(err)
	}
	code := []byte("huijian-recovery")
	wrapNonce := []byte("fixed-nonce!")
	recWrap, _ := e2eWrapNonce("hjr1", e2eRecoveryKey(code), sk.Bytes(), wrapNonce)
	salt := []byte("huijian-pw-salt!")
	auth, unlock := e2ePasswordKeys("correct horse battery staple", salt)
	pwWrap, _ := e2eWrapNonce("hjp1", unlock, sk.Bytes(), wrapNonce)
	dev, _ := e2eDeriveKeyPair([]byte("huijian e2e test vector device"))
	gEnc, gCt, _ := hpkeSeal(dev.PublicKey(), []byte(e2eInfoGrant), []byte("hjg1"), sk.Bytes(), eph)
	sasNA, sasNB := bytes.Repeat([]byte{0xa1}, 32), bytes.Repeat([]byte{0xb2}, 32)

	vec := map[string]any{
		"note":                "回笺端到端加密跨平台测试向量（server/e2e_test.go 生成）。各端要能解开 envelope 得到 payload，解开 file_ct 得到 file_pt，派生结果一致。",
		"recipient_sk":        hex.EncodeToString(sk.Bytes()),
		"recipient_pk_b64url": b64.EncodeToString(sk.PublicKey().Bytes()),
		"kid":                 kid,
		"ephemeral_sk":        hex.EncodeToString(eph.Bytes()),
		"payload":             payload,
		"envelope":            env,
		"file_key":            hex.EncodeToString(fileKey),
		"file_pt_rule":        "长度 65636，第 i 字节 = i % 251",
		"file_ct_sha256":      sha256Hex(string(fct.Bytes())),
		"file_ct_len":         fct.Len(),
		"recovery_code_bytes": hex.EncodeToString(code),
		"recovery_code":       e2eFormatRecovery(code),
		"recovery_key":        hex.EncodeToString(e2eRecoveryKey(code)),
		"recovery_wrap":       recWrap,
		"wrap_nonce":          hex.EncodeToString(wrapNonce),
		"password":            "correct horse battery staple",
		"password_salt":       hex.EncodeToString(salt),
		"argon2id":            map[string]int{"time": e2eArgonTime, "memory_kib": e2eArgonMemKiB, "lanes": e2eArgonLanes, "len": 64},
		"password_auth_key":   hex.EncodeToString(auth),
		"password_unlock_key": hex.EncodeToString(unlock),
		"password_wrap":       pwWrap,
		"device_sk":           hex.EncodeToString(dev.Bytes()),
		"grant":               "hjg1." + b64.EncodeToString(append(gEnc, gCt...)),
		"grant_info":          e2eInfoGrant,
		"grant_aad":           "hjg1",
		"sas_nonce_a":         hex.EncodeToString(sasNA),
		"sas_nonce_b":         hex.EncodeToString(sasNB),
		"sas_commit":          hex.EncodeToString(e2eCommit(dev.PublicKey().Bytes(), sk.PublicKey().Bytes(), sasNB)),
		"sas_code":            e2eSAS(dev.PublicKey().Bytes(), sk.PublicKey().Bytes(), sasNA, sasNB),
		"sas_rule":            "commit = SHA-256(\"huijian e2e v1 commit\" ‖ device_pk ‖ account_pk ‖ nb)；code = SHA-256(\"huijian e2e v1 sas\" ‖ device_pk ‖ account_pk ‖ na ‖ nb) 前 4 字节大端 mod 1000000，补足 6 位",
	}
	got, _ := json.MarshalIndent(vec, "", " ")
	const path = "testdata/e2e_vectors.json"
	if *updateVectors {
		if err := os.WriteFile(path, append(got, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("缺少 %s：用 -update-e2e-vectors 生成", path)
	}
	if !bytes.Equal(bytes.TrimSpace(want), bytes.TrimSpace(got)) {
		t.Fatal("跨平台测试向量和当前实现不一致（格式改了？改格式要升级版本号，不能悄悄改）")
	}
}

// 解开其他平台生成的信封（跨平台互通检查）：E2E_EXTERNAL_ENVELOPE=文件 go test -run TestE2EOpenExternal
// 信封必须是加密给 testdata/e2e_vectors.json 里的 recipient 的，内容应为「你好」
func TestE2EOpenExternal(t *testing.T) {
	path := os.Getenv("E2E_EXTERNAL_ENVELOPE")
	if path == "" {
		t.Skip("没有指定外部信封")
	}
	env, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	sk, _ := e2eDeriveKeyPair([]byte("huijian e2e test vector recipient"))
	pt, err := e2eOpenMessage(sk, strings.TrimSpace(string(env)))
	if err != nil || string(pt) != "你好" {
		t.Fatalf("解不开外部信封：%v %q", err, pt)
	}
}
