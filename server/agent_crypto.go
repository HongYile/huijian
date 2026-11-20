package main

// agent 双向的密码学格式（docs/agent-mcp.md §11.2）。服务端不解密任何东西：这里的函数给 `huijian agent` 命令行（agent 一侧）、
// 测试和跨平台测试向量用；设备一侧（证明、回复、解开 agent 消息）在共用核心 core/src/agent.rs 里，两边用同一份向量核对。
//
// - 登录承诺 / 核对码：同设备批准，前缀换成 "huijian agent v1 commit" / "huijian agent v1 sas"
// - 会话证明 hja1：AES-256-GCM，钥匙 HKDF-SHA256(salt="huijian agent v1 attest", ikm=账号私钥)，附加数据 "hja1"
// - agent → 账号 hje2.<kid>.<session_id>.<b64(enc‖ct)>：HPKE auth（会话私钥 → 账号公钥）
// - 设备 → agent hjq1.<session_id>.<b64(enc‖ct)>：HPKE auth（账号私钥 → 会话公钥），附加数据带被回复的消息 id

import (
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

const (
	agentInfoMessage = "huijian agent v1 message"
	agentInfoReply   = "huijian agent v1 reply"
	agentMsgPrefix   = "hje2."
	agentReplyPrefix = "hjq1."
	agentAttestPfx   = "hja1"
)

// agentCommit：登录承诺（会话公钥、agent 看到的账号公钥、agent 的随机数 nb、会话名称的 SHA-256）。
// 名称也在承诺里：服务器改不了设备上显示、写进会话证明的名称
func agentCommit(sessPub, account, nb []byte, name string) []byte {
	nh := sha256.Sum256([]byte(name))
	h := sha256.New()
	h.Write([]byte("huijian agent v1 commit"))
	h.Write(sessPub)
	h.Write(account)
	h.Write(nb)
	h.Write(nh[:])
	return h.Sum(nil)
}

// agentSAS：6 位核对码
func agentSAS(sessPub, account, na, nb []byte) string {
	h := sha256.New()
	h.Write([]byte("huijian agent v1 sas"))
	h.Write(sessPub)
	h.Write(account)
	h.Write(na)
	h.Write(nb)
	return fmt.Sprintf("%06d", binary.BigEndian.Uint32(h.Sum(nil)[:4])%1000000)
}

// agentAttest：会话证明的明文
type agentAttest struct {
	SessionID  string `json:"session_id"`
	Pub        string `json:"pub"`
	Name       string `json:"name"`
	ApprovedAt int64  `json:"approved_at"`
}

func agentAttestKey(accountSK []byte) []byte {
	k, err := hkdf.Key(sha256.New, accountSK, []byte("huijian agent v1 attest"), "", 32)
	if err != nil {
		panic(err)
	}
	return k
}

// agentAttestSeal：批准设备用账号私钥写会话证明（测试用；客户端在共用核心里写）
func agentAttestSeal(accountSK []byte, a agentAttest) (string, error) {
	b, _ := json.Marshal(a)
	return e2eWrap(agentAttestPfx, agentAttestKey(accountSK), b)
}

func agentAttestOpen(accountSK []byte, s string) (agentAttest, error) {
	var a agentAttest
	pt, err := e2eUnwrap(agentAttestPfx, agentAttestKey(accountSK), s)
	if err != nil {
		return a, err
	}
	if json.Unmarshal(pt, &a) != nil {
		return a, errE2E
	}
	return a, nil
}

// agentPayload：hje2 的明文（消息或回执）
type agentPayload struct {
	V          int      `json:"v"`
	Kind       string   `json:"kind"` // message / receipt
	Text       string   `json:"text,omitempty"`
	Desp       string   `json:"desp,omitempty"`
	Ask        bool     `json:"ask,omitempty"`
	Choices    []string `json:"choices,omitempty"`
	Seq        int64    `json:"seq,omitempty"`
	SentAt     int64    `json:"sent_at,omitempty"`
	ReplyID    int64    `json:"reply_id,omitempty"`
	N          string   `json:"n,omitempty"`
	ReceivedAt int64    `json:"received_at,omitempty"`
}

// agentSeal：agent 用会话私钥把载荷加密给账号公钥 → hje2 信封。eph 为 nil 时随机（测试向量才指定）
func agentSeal(account *ecdh.PublicKey, sessSK *ecdh.PrivateKey, sessionID string, payload []byte, eph *ecdh.PrivateKey) (string, error) {
	kid := e2eKID(account.Bytes())
	aad := agentMsgPrefix + kid + "." + sessionID
	enc, ct, err := hpkeAuthSeal(account, sessSK, []byte(agentInfoMessage), []byte(aad), payload, eph)
	if err != nil {
		return "", err
	}
	return aad + "." + b64.EncodeToString(append(enc, ct...)), nil
}

// agentEnvelopeParts：hje2 信封的 kid 和会话 id（服务端校验路由用，不解密）
func agentEnvelopeParts(env string) (kid, sessionID string, ok bool) {
	rest, ok := strings.CutPrefix(env, agentMsgPrefix)
	if !ok {
		return "", "", false
	}
	p := strings.SplitN(rest, ".", 3)
	if len(p) != 3 || len(p[0]) != 16 || p[1] == "" || len(p[2]) < 43 {
		return "", "", false
	}
	if _, err := b64.DecodeString(p[2]); err != nil {
		return "", "", false
	}
	return p[0], p[1], true
}

// agentOpen：账号私钥解开 hje2（发送方必须是 sessPub）
func agentOpen(accountSK *ecdh.PrivateKey, sessPub *ecdh.PublicKey, env string) ([]byte, error) {
	kid, sid, ok := agentEnvelopeParts(env)
	if !ok || kid != e2eKID(accountSK.PublicKey().Bytes()) {
		return nil, errE2E
	}
	raw, _ := b64.DecodeString(env[strings.LastIndexByte(env, '.')+1:])
	if len(raw) < 32+16 {
		return nil, errE2E
	}
	return hpkeAuthOpen(accountSK, sessPub, raw[:32], []byte(agentInfoMessage), []byte(agentMsgPrefix+kid+"."+sid), raw[32:])
}

// agentReply：hjq1 的明文
type agentReply struct {
	V      int    `json:"v"`
	ReSeq  int64  `json:"re_seq"` // 被回复的消息在载荷里的 seq（agent 自己定的序号，服务器换不了「回的是哪个问题」）
	Text   string `json:"text"`
	N      string `json:"n"`
	SentAt int64  `json:"sent_at"`
	Device string `json:"device,omitempty"`
}

// agentReplySeal：设备用账号私钥把回复加密给会话公钥（测试用；客户端在共用核心里做）
func agentReplySeal(sessPub *ecdh.PublicKey, accountSK *ecdh.PrivateKey, sessionID string, msgID int64, payload []byte, eph *ecdh.PrivateKey) (string, error) {
	pre := agentReplyPrefix + sessionID
	enc, ct, err := hpkeAuthSeal(sessPub, accountSK, []byte(agentInfoReply), []byte(pre+"."+strconv.FormatInt(msgID, 10)), payload, eph)
	if err != nil {
		return "", err
	}
	return pre + "." + b64.EncodeToString(append(enc, ct...)), nil
}

// agentReplySession：hjq1 信封里的会话 id（服务端校验路由用）
func agentReplySession(env string) (string, bool) {
	rest, ok := strings.CutPrefix(env, agentReplyPrefix)
	if !ok {
		return "", false
	}
	sid, data, ok := strings.Cut(rest, ".")
	if !ok || sid == "" || len(data) < 43 {
		return "", false
	}
	if _, err := b64.DecodeString(data); err != nil {
		return "", false
	}
	return sid, true
}

// agentReplyOpen：agent 用会话私钥解开回复，发送方必须是钉住的账号公钥；msgID 是服务器说的被回复消息 id（错了解不开）
func agentReplyOpen(sessSK *ecdh.PrivateKey, account *ecdh.PublicKey, env string, msgID int64) (agentReply, error) {
	var r agentReply
	sid, ok := agentReplySession(env)
	if !ok {
		return r, errE2E
	}
	raw, _ := b64.DecodeString(env[len(agentReplyPrefix)+len(sid)+1:])
	if len(raw) < 32+16 {
		return r, errE2E
	}
	pt, err := hpkeAuthOpen(sessSK, account, raw[:32], []byte(agentInfoReply), []byte(agentReplyPrefix+sid+"."+strconv.FormatInt(msgID, 10)), raw[32:])
	if err != nil {
		return r, err
	}
	if json.Unmarshal(pt, &r) != nil || r.N == "" {
		return r, errE2E
	}
	return r, nil
}
