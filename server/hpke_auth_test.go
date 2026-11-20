package main

import (
	"bytes"
	"encoding/json"
	"os"
	"testing"
)

// RFC 9180 官方测试向量：DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 / AES-256-GCM，auth 模式（mode 2）
func TestHPKEAuthRFC9180Vector(t *testing.T) {
	raw, err := os.ReadFile("testdata/hpke_rfc9180_x25519_sha256_aes256gcm_auth.json")
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		Mode                                          int
		Info, IkmE, IkmR, IkmS, SkEm, SkRm, SkSm, Enc string
		PkSm                                          string
		Encryptions                                   []struct{ Aad, Ct, Pt string }
	}
	if err := json.Unmarshal(raw, &v); err != nil || v.Mode != 2 {
		t.Fatalf("向量文件不对：%v mode=%d", err, v.Mode)
	}
	skE, _ := e2eDeriveKeyPair(unhex(t, v.IkmE))
	skR, _ := e2eDeriveKeyPair(unhex(t, v.IkmR))
	skS, _ := e2eDeriveKeyPair(unhex(t, v.IkmS))
	if !bytes.Equal(skE.Bytes(), unhex(t, v.SkEm)) || !bytes.Equal(skR.Bytes(), unhex(t, v.SkRm)) || !bytes.Equal(skS.Bytes(), unhex(t, v.SkSm)) {
		t.Fatal("DeriveKeyPair 不对")
	}
	e := v.Encryptions[0]
	enc, ct, err := hpkeAuthSeal(skR.PublicKey(), skS, unhex(t, v.Info), unhex(t, e.Aad), unhex(t, e.Pt), skE)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(enc, unhex(t, v.Enc)) || !bytes.Equal(ct, unhex(t, e.Ct)) {
		t.Fatalf("加密结果和 RFC 向量不一致：enc=%x ct=%x", enc, ct)
	}
	pt, err := hpkeAuthOpen(skR, skS.PublicKey(), enc, unhex(t, v.Info), unhex(t, e.Aad), ct)
	if err != nil || !bytes.Equal(pt, unhex(t, e.Pt)) {
		t.Fatal("解密 RFC 向量失败")
	}
	// 换一个发送方公钥（冒充）、或者用 base 模式解：都解不开
	other, _ := e2eDeriveKeyPair([]byte("someone else"))
	if _, err := hpkeAuthOpen(skR, other.PublicKey(), enc, unhex(t, v.Info), unhex(t, e.Aad), ct); err == nil {
		t.Fatal("发送方公钥不对也解开了")
	}
	if _, err := hpkeOpen(skR, enc, unhex(t, v.Info), unhex(t, e.Aad), ct); err == nil {
		t.Fatal("auth 模式的密文被 base 模式解开了")
	}
}
