package main

// 端到端加密的格式（设计见 docs/e2ee.md）。服务端不解密任何东西：这里的加密函数给 `huijian push` 发送端、
// 测试和跨平台测试向量用；服务端只校验格式、存取密文。
//
// - 消息：HPKE（RFC 9180，base 模式）DHKEM(X25519, HKDF-SHA256) + HKDF-SHA256 + AES-256-GCM，
//   信封 "hje1.<kid>.<base64url(enc‖ct)>"，kid = 公钥 SHA-256 的前 8 字节（16 位十六进制），附加数据 "hje1.<kid>"。
// - 附件：每个附件一把随机 32 字节密钥，AES-256-GCM 分块（"HJF1" + 块大小），块序号和末块标记写进 nonce。
// - 私钥的「锁住的副本」：密码（Argon2id 派生）/ 恢复码（HKDF 派生）用 AES-256-GCM；转交给设备用 HPKE。

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"

	"golang.org/x/crypto/argon2"
)

const (
	hpkeKEM  = 0x0020 // DHKEM(X25519, HKDF-SHA256)
	hpkeKDF  = 0x0001 // HKDF-SHA256
	hpkeAEAD = 0x0002 // AES-256-GCM

	e2eMsgPrefix   = "hje1."
	e2eInfoMessage = "huijian e2e v1 message"
	e2eInfoGrant   = "huijian e2e v1 grant"
)

var errE2E = errors.New("加密数据格式不对或已被篡改")

var b64 = base64.RawURLEncoding

// ---------- HPKE（RFC 9180 base 模式，只实现回笺用的这一种组合） ----------

func i2osp2(v int) []byte { return []byte{byte(v >> 8), byte(v)} }

var (
	kemSuite  = append([]byte("KEM"), i2osp2(hpkeKEM)...)
	hpkeSuite = append(append(append([]byte("HPKE"), i2osp2(hpkeKEM)...), i2osp2(hpkeKDF)...), i2osp2(hpkeAEAD)...)
)

func labeledExtract(suite []byte, salt []byte, label string, ikm []byte) []byte {
	in := append(append(append([]byte("HPKE-v1"), suite...), label...), ikm...)
	prk, _ := hkdf.Extract(sha256.New, in, salt)
	return prk
}

func labeledExpand(suite []byte, prk []byte, label string, info []byte, n int) []byte {
	in := append(append(append(append(i2osp2(n), "HPKE-v1"...), suite...), label...), info...)
	out, err := hkdf.Expand(sha256.New, prk, string(in), n)
	if err != nil {
		panic(err) // 长度固定，不会出错
	}
	return out
}

// e2eDeriveKeyPair：RFC 9180 的 DeriveKeyPair（X25519），只用于测试向量
func e2eDeriveKeyPair(ikm []byte) (*ecdh.PrivateKey, error) {
	prk := labeledExtract(kemSuite, nil, "dkp_prk", ikm)
	return ecdh.X25519().NewPrivateKey(labeledExpand(kemSuite, prk, "sk", nil, 32))
}

// kemSharedSecret：kemContext = enc ‖ pkR（base 模式）或 enc ‖ pkR ‖ pkS（auth 模式）
func kemSharedSecret(dh []byte, kemContext ...[]byte) []byte {
	prk := labeledExtract(kemSuite, nil, "eae_prk", dh)
	return labeledExpand(kemSuite, prk, "shared_secret", bytes.Join(kemContext, nil), 32)
}

const (
	hpkeModeBase = 0x00
	hpkeModeAuth = 0x02
)

// hpkeContext：base 模式，返回 AES-256-GCM 和 base_nonce（每个密钥只加密一条，序号固定为 0）
func hpkeContext(shared, info []byte) (cipher.AEAD, []byte) {
	return hpkeContextMode(hpkeModeBase, shared, info)
}

func hpkeContextMode(mode byte, shared, info []byte) (cipher.AEAD, []byte) {
	pskIDHash := labeledExtract(hpkeSuite, nil, "psk_id_hash", nil)
	infoHash := labeledExtract(hpkeSuite, nil, "info_hash", info)
	ctx := append(append([]byte{mode}, pskIDHash...), infoHash...)
	secret := labeledExtract(hpkeSuite, shared, "secret", nil)
	key := labeledExpand(hpkeSuite, secret, "key", ctx, 32)
	nonce := labeledExpand(hpkeSuite, secret, "base_nonce", ctx, 12)
	blk, _ := aes.NewCipher(key)
	g, _ := cipher.NewGCM(blk)
	return g, nonce
}

// hpkeSeal：加密给 pkR。eph 为 nil 时随机生成一次性密钥（测试时传入固定值）。返回 enc（32 字节）和密文
func hpkeSeal(pkR *ecdh.PublicKey, info, aad, pt []byte, eph *ecdh.PrivateKey) (enc, ct []byte, err error) {
	if eph == nil {
		if eph, err = ecdh.X25519().GenerateKey(rand.Reader); err != nil {
			return nil, nil, err
		}
	}
	dh, err := eph.ECDH(pkR)
	if err != nil {
		return nil, nil, err
	}
	enc = eph.PublicKey().Bytes()
	g, nonce := hpkeContext(kemSharedSecret(dh, enc, pkR.Bytes()), info)
	return enc, g.Seal(nil, nonce, pt, aad), nil
}

func hpkeOpen(skR *ecdh.PrivateKey, enc, info, aad, ct []byte) ([]byte, error) {
	pkE, err := ecdh.X25519().NewPublicKey(enc)
	if err != nil {
		return nil, errE2E
	}
	dh, err := skR.ECDH(pkE)
	if err != nil {
		return nil, errE2E
	}
	g, nonce := hpkeContext(kemSharedSecret(dh, enc, skR.PublicKey().Bytes()), info)
	pt, err := g.Open(nil, nonce, ct, aad)
	if err != nil {
		return nil, errE2E
	}
	return pt, nil
}

// ---------- HPKE auth 模式（RFC 9180 mode_auth）：加密的同时证明发送方持有 skS（agent 双向，docs/agent-mcp.md §4.2） ----------

// hpkeAuthSeal：用发送方私钥 skS 加密给 pkR。eph 为 nil 时随机生成一次性密钥
func hpkeAuthSeal(pkR *ecdh.PublicKey, skS *ecdh.PrivateKey, info, aad, pt []byte, eph *ecdh.PrivateKey) (enc, ct []byte, err error) {
	if eph == nil {
		if eph, err = ecdh.X25519().GenerateKey(rand.Reader); err != nil {
			return nil, nil, err
		}
	}
	dh1, err := eph.ECDH(pkR)
	if err != nil {
		return nil, nil, err
	}
	dh2, err := skS.ECDH(pkR)
	if err != nil {
		return nil, nil, err
	}
	enc = eph.PublicKey().Bytes()
	shared := kemSharedSecret(append(dh1, dh2...), enc, pkR.Bytes(), skS.PublicKey().Bytes())
	g, nonce := hpkeContextMode(hpkeModeAuth, shared, info)
	return enc, g.Seal(nil, nonce, pt, aad), nil
}

// hpkeAuthOpen：只有发送方确实持有 pkS 对应的私钥时才能解开
func hpkeAuthOpen(skR *ecdh.PrivateKey, pkS *ecdh.PublicKey, enc, info, aad, ct []byte) ([]byte, error) {
	pkE, err := ecdh.X25519().NewPublicKey(enc)
	if err != nil {
		return nil, errE2E
	}
	dh1, err := skR.ECDH(pkE)
	if err != nil {
		return nil, errE2E
	}
	dh2, err := skR.ECDH(pkS)
	if err != nil {
		return nil, errE2E
	}
	shared := kemSharedSecret(append(dh1, dh2...), enc, skR.PublicKey().Bytes(), pkS.Bytes())
	g, nonce := hpkeContextMode(hpkeModeAuth, shared, info)
	pt, err := g.Open(nil, nonce, ct, aad)
	if err != nil {
		return nil, errE2E
	}
	return pt, nil
}

// ---------- 账号钥匙与消息信封 ----------

// e2eKID：公钥指纹（SHA-256 前 8 字节的十六进制），用来区分更换前后的钥匙
func e2eKID(pub []byte) string {
	s := sha256.Sum256(pub)
	return hex.EncodeToString(s[:8])
}

// e2eSealMessage：发送端把消息内容（JSON）加密成信封
func e2eSealMessage(pub *ecdh.PublicKey, payload []byte) (string, error) {
	kid := e2eKID(pub.Bytes())
	enc, ct, err := hpkeSeal(pub, []byte(e2eInfoMessage), []byte(e2eMsgPrefix+kid), payload, nil)
	if err != nil {
		return "", err
	}
	return e2eMsgPrefix + kid + "." + b64.EncodeToString(append(enc, ct...)), nil
}

// e2eParseEnvelope：只检查格式（服务端收消息时用），返回 kid
func e2eParseEnvelope(env string) (kid string, body []byte, err error) {
	rest, ok := strings.CutPrefix(env, e2eMsgPrefix)
	if !ok {
		return "", nil, errE2E
	}
	kid, data, ok := strings.Cut(rest, ".")
	if !ok || len(kid) != 16 {
		return "", nil, errE2E
	}
	if _, err := hex.DecodeString(kid); err != nil {
		return "", nil, errE2E
	}
	body, err = b64.DecodeString(data)
	if err != nil || len(body) < 32+16 {
		return "", nil, errE2E
	}
	return kid, body, nil
}

func e2eOpenMessage(sk *ecdh.PrivateKey, env string) ([]byte, error) {
	kid, body, err := e2eParseEnvelope(env)
	if err != nil {
		return nil, err
	}
	if kid != e2eKID(sk.PublicKey().Bytes()) {
		return nil, errors.New("这条消息是用另一把钥匙加密的")
	}
	return hpkeOpen(sk, body[:32], []byte(e2eInfoMessage), []byte(e2eMsgPrefix+kid), body[32:])
}

// e2eSendKey：「加密发送密钥」= pushkey + ".e2e." + 公钥（base64url，43 个字符）
const e2eSendKeySep = ".e2e."

func e2eSplitSendKey(s string) (pushkey string, pub *ecdh.PublicKey, err error) {
	pk, p, ok := strings.Cut(s, e2eSendKeySep)
	if !ok {
		return s, nil, nil
	}
	raw, err := b64.DecodeString(p)
	if err != nil || len(raw) != 32 {
		return pk, nil, errors.New("加密发送密钥里的公钥格式不对")
	}
	pub, err = ecdh.X25519().NewPublicKey(raw)
	return pk, pub, err
}

// e2ePayload：信封里的明文（JSON）。各端按这个结构解析，未知字段忽略。
// atts 和服务器上的附件按顺序一一对应：第 i 个附件的密文用 atts[i].key 解密，真实名字、类型、大小也在这里
type e2ePayload struct {
	V    int      `json:"v"`              // 1
	Text string   `json:"text,omitempty"` // 标题；为空时客户端用附件名代替
	Desp string   `json:"desp,omitempty"` // 正文（Markdown 原文，客户端本地解析）
	Type string   `json:"type,omitempty"` // markdown（默认）/ text / image
	Atts []e2eAtt `json:"atts,omitempty"`
}

type e2eAtt struct {
	Name string `json:"name"`
	Mime string `json:"mime"`
	Size int64  `json:"size"` // 明文大小
	Key  string `json:"key"`  // base64url，32 字节
}

// e2eSealPayload：把标题、正文、附件信息封进信封（huijian push -k 发送端和服务器代加密共用，SDK 的 _e2e_seal 规则相同）。
// 服务端看不到发送端加密的内容，没法像明文那样截断，所以在加密前截断：标题最多 2000 字、正文最多 64 KB；
// 信封超过 e2eMaxEnvelope 时逐步截短正文直到放得下
func e2eSealPayload(pub *ecdh.PublicKey, text, desp, typ string, atts []e2eAtt) (string, error) {
	if len(desp) > 64<<10 {
		desp = desp[:64<<10]
	}
	if r := []rune(text); len(r) > 2000 {
		text = string(r[:2000])
	}
	p := e2ePayload{V: 1, Text: text, Type: typ, Atts: atts}
	for {
		p.Desp = strings.ToValidUTF8(desp, "")
		var buf bytes.Buffer
		enc := json.NewEncoder(&buf)
		enc.SetEscapeHTML(false) // 不把 < > & 转成 \u003c，免得体积暴涨
		if err := enc.Encode(p); err != nil {
			return "", err
		}
		env, err := e2eSealMessage(pub, bytes.TrimSpace(buf.Bytes()))
		if err != nil || len(env) <= e2eMaxEnvelope {
			return env, err
		}
		if desp == "" {
			return "", errors.New("加密后的内容太长：标题或附件太多，请精简")
		}
		desp = desp[:len(desp)*4/5] // 引号、控制字符转义后会变长：逐步截短正文直到放得下
	}
}

// e2eMaxEnvelope：信封最长 120 KB（服务端 multipart 字段读到 128 KB 为止，留余量，超过就拒收而不是截断）
const e2eMaxEnvelope = 120 << 10

// e2eCipherSize：附件加密后的大小（文件头 + 每块 16 字节校验；空文件也有一块）
func e2eCipherSize(n int64) int64 {
	chunks := (n + e2eChunk - 1) / e2eChunk
	if chunks == 0 {
		chunks = 1
	}
	return e2eHdrLen + n + chunks*16
}

// ---------- 设备批准的核对码 ----------
//
// 只用「新设备公钥的哈希」算 6 位码不安全：被攻破的服务器可以生成大量自己的密钥对，几秒内挑出核对码相同的一个冒充新设备。
// 所以用「先承诺、后揭晓」（ZRTP / Signal 的做法）：
//  1. 新设备生成随机数 nb，只交出承诺 commit = SHA-256("huijian e2e v1 commit" ‖ 公钥 ‖ 账号公钥 ‖ nb)；
//  2. 批准设备看到承诺后，生成自己的随机数 na 交给对方（只用自己生成的这个 na，不用服务器给的）；
//  3. 新设备看到 na 后揭晓 nb（每个 nb 只揭晓一次：na 变了就整个请求重来）；
//  4. 两边都算 sas = SHA-256("huijian e2e v1 sas" ‖ 公钥 ‖ 账号公钥 ‖ na ‖ nb) 前 4 字节大端 mod 10⁶，补足 6 位。
// 中间人必须在看到 na 之前定下自己的 nb，没法反复试，每次冒充只有百万分之一的机会，而且失败会被用户看到。
// 「账号公钥」是新设备发请求时从服务器读到的账号公钥，批准设备用自己私钥算出的公钥核对：
// 服务器给新设备看假的账号公钥时，承诺对不上、批准设备自动拒绝；新设备只接受私钥和这把公钥配对的 grant，
// 这样服务器也没法伪造 grant 塞给新设备一把它自己的私钥（hjg1 谁都能加密给新设备）。
// 公钥、账号公钥、na、nb 都固定 32 字节。

func e2eCommit(pub, account, nb []byte) []byte {
	h := sha256.New()
	h.Write([]byte("huijian e2e v1 commit"))
	h.Write(pub)
	h.Write(account)
	h.Write(nb)
	return h.Sum(nil)
}

func e2eSAS(pub, account, na, nb []byte) string {
	h := sha256.New()
	h.Write([]byte("huijian e2e v1 sas"))
	h.Write(pub)
	h.Write(account)
	h.Write(na)
	h.Write(nb)
	return fmt.Sprintf("%06d", binary.BigEndian.Uint32(h.Sum(nil)[:4])%1000000)
}

// ---------- 附件分块加密 ----------

const (
	e2eFileMagic = "HJF1"
	e2eChunk     = 64 << 10
	e2eHdrLen    = 8
)

func e2eFileGCM(key []byte) (cipher.AEAD, error) {
	if len(key) != 32 {
		return nil, errors.New("附件密钥长度不对")
	}
	blk, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(blk)
}

func e2eChunkNonce(i uint64, last bool) []byte {
	n := make([]byte, 12)
	binary.BigEndian.PutUint64(n[3:11], i) // 前 11 字节是块序号（高 3 字节为 0），最后 1 字节是末块标记
	if last {
		n[11] = 1
	}
	return n
}

func e2eFileHeader() []byte {
	h := make([]byte, e2eHdrLen)
	copy(h, e2eFileMagic)
	binary.BigEndian.PutUint32(h[4:], e2eChunk)
	return h
}

// e2eEncryptFile：把 r 的内容加密写到 w。空文件也有一个（空的）末块
func e2eEncryptFile(key []byte, r io.Reader, w io.Writer) error {
	g, err := e2eFileGCM(key)
	if err != nil {
		return err
	}
	hdr := e2eFileHeader()
	if _, err := w.Write(hdr); err != nil {
		return err
	}
	cur := make([]byte, e2eChunk)
	n, err := io.ReadFull(r, cur)
	if err != nil && err != io.EOF && err != io.ErrUnexpectedEOF {
		return err
	}
	for i := uint64(0); ; i++ {
		next := make([]byte, e2eChunk)
		m := 0
		if n == e2eChunk { // 读满了一块：再读一块才知道这块是不是最后一块
			m, err = io.ReadFull(r, next)
			if err != nil && err != io.EOF && err != io.ErrUnexpectedEOF {
				return err
			}
		}
		last := m == 0
		if _, err := w.Write(g.Seal(nil, e2eChunkNonce(i, last), cur[:n], hdr)); err != nil {
			return err
		}
		if last {
			return nil
		}
		cur, n = next, m
	}
}

// e2eDecryptFile：解密并校验；被截断、换序、删块、改动都会报错
func e2eDecryptFile(key []byte, r io.Reader, w io.Writer) error {
	g, err := e2eFileGCM(key)
	if err != nil {
		return err
	}
	hdr := make([]byte, e2eHdrLen)
	if _, err := io.ReadFull(r, hdr); err != nil || !bytes.Equal(hdr, e2eFileHeader()) {
		return errE2E
	}
	size := e2eChunk + g.Overhead()
	cur := make([]byte, size)
	n, err := io.ReadFull(r, cur)
	if err != nil && err != io.ErrUnexpectedEOF {
		return errE2E
	}
	for i := uint64(0); ; i++ {
		next := make([]byte, size)
		m := 0
		if n == size {
			m, err = io.ReadFull(r, next)
			if err != nil && err != io.EOF && err != io.ErrUnexpectedEOF {
				return err
			}
		}
		last := m == 0
		pt, err := g.Open(nil, e2eChunkNonce(i, last), cur[:n], hdr)
		if err != nil {
			return errE2E
		}
		if _, err := w.Write(pt); err != nil {
			return err
		}
		if last {
			return nil
		}
		cur, n = next, m
	}
}

// ---------- 锁住私钥：密码 / 恢复码 ----------

// Argon2id 参数（RFC 9106 第二推荐组）：64 MiB、3 轮、1 线程，输出 64 字节：前 32 登录凭证，后 32 解锁钥匙
const (
	e2eArgonTime   = 3
	e2eArgonMemKiB = 64 * 1024
	e2eArgonLanes  = 1
)

func e2ePasswordKeys(password string, salt []byte) (authKey, unlockKey []byte) {
	out := argon2.IDKey([]byte(password), salt, e2eArgonTime, e2eArgonMemKiB, e2eArgonLanes, 64)
	return out[:32], out[32:]
}

// e2eRecoveryKey：恢复码（128 位随机数）派生 AES 密钥；恢复码熵足够高，不需要慢哈希
func e2eRecoveryKey(code []byte) []byte {
	k, _ := hkdf.Key(sha256.New, code, []byte("huijian e2e v1 recovery"), "", 32)
	return k
}

// e2eWrap / e2eUnwrap：用 32 字节密钥锁住数据，格式 "<前缀>.<base64url(nonce‖密文)>"，前缀进附加数据
func e2eWrap(prefix string, key, pt []byte) (string, error) {
	nonce := make([]byte, 12)
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	return e2eWrapNonce(prefix, key, pt, nonce)
}

func e2eWrapNonce(prefix string, key, pt, nonce []byte) (string, error) {
	g, err := e2eFileGCM(key)
	if err != nil {
		return "", err
	}
	return prefix + "." + b64.EncodeToString(append(append([]byte{}, nonce...), g.Seal(nil, nonce, pt, []byte(prefix))...)), nil
}

func e2eUnwrap(prefix string, key []byte, s string) ([]byte, error) {
	data, ok := strings.CutPrefix(s, prefix+".")
	if !ok {
		return nil, errE2E
	}
	raw, err := b64.DecodeString(data)
	if err != nil || len(raw) < 12+16 {
		return nil, errE2E
	}
	g, err := e2eFileGCM(key)
	if err != nil {
		return nil, err
	}
	pt, err := g.Open(nil, raw[:12], raw[12:], []byte(prefix))
	if err != nil {
		return nil, errE2E
	}
	return pt, nil
}

// e2eFormatRecovery：恢复码显示格式，26 位 Crockford Base32（不含 I L O U），分组 XXXXX-XXXXX-XXXXX-XXXXX-XXXXXX
const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

func e2eFormatRecovery(code []byte) string {
	var sb strings.Builder
	var acc uint32
	bits := 0
	n := 0
	for _, b := range code {
		acc = acc<<8 | uint32(b)
		bits += 8
		for bits >= 5 {
			bits -= 5
			sb.WriteByte(crockford[(acc>>bits)&31])
			if n++; n%5 == 0 && n < 25 {
				sb.WriteByte('-')
			}
		}
	}
	if bits > 0 {
		sb.WriteByte(crockford[(acc<<(5-bits))&31])
	}
	return sb.String()
}

func e2eParseRecovery(s string) ([]byte, error) {
	var out []byte
	var acc uint32
	bits := 0
	for _, c := range strings.ToUpper(s) {
		switch c {
		case '-', ' ':
			continue
		case 'O':
			c = '0'
		case 'I', 'L':
			c = '1'
		}
		v := strings.IndexRune(crockford, c)
		if v < 0 {
			return nil, fmt.Errorf("恢复码里有无效字符 %q", c)
		}
		acc = acc<<5 | uint32(v)
		bits += 5
		if bits >= 8 {
			bits -= 8
			out = append(out, byte(acc>>bits))
		}
	}
	if len(out) != 16 {
		return nil, errors.New("恢复码长度不对")
	}
	return out, nil
}
