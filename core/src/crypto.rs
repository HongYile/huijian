use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use base64::Engine;
use hkdf::Hkdf;
use sha2::{Digest, Sha256};
use std::io::{Read, Write};
use x25519_dalek::{PublicKey, StaticSecret};

#[derive(Debug, PartialEq)]
pub enum Error {
    Format,     // 格式不对或被篡改
    WrongKey,   // 用另一把钥匙加密的
    Io(String), // 读写失败
}
pub type Result<T> = std::result::Result<T, Error>;

pub const MSG_PREFIX: &str = "hje1.";
pub const INFO_MESSAGE: &[u8] = b"huijian e2e v1 message";
pub const INFO_GRANT: &[u8] = b"huijian e2e v1 grant";
pub const CHUNK: usize = 64 << 10;
const TAG: usize = 16;

// ---------- HPKE（RFC 9180 base 模式：DHKEM(X25519, HKDF-SHA256) + HKDF-SHA256 + AES-256-GCM） ----------

const KEM_SUITE: &[u8] = b"KEM\x00\x20";
const HPKE_SUITE: &[u8] = b"HPKE\x00\x20\x00\x01\x00\x02";

fn labeled_extract(suite: &[u8], salt: &[u8], label: &[u8], ikm: &[u8]) -> [u8; 32] {
    let mut m = Vec::with_capacity(7 + suite.len() + label.len() + ikm.len());
    m.extend_from_slice(b"HPKE-v1");
    m.extend_from_slice(suite);
    m.extend_from_slice(label);
    m.extend_from_slice(ikm);
    let (prk, _) = Hkdf::<Sha256>::extract(Some(salt), &m);
    prk.into()
}

fn labeled_expand(suite: &[u8], prk: &[u8; 32], label: &[u8], info: &[u8], out: &mut [u8]) {
    let mut m = Vec::with_capacity(9 + suite.len() + label.len() + info.len());
    m.extend_from_slice(&(out.len() as u16).to_be_bytes());
    m.extend_from_slice(b"HPKE-v1");
    m.extend_from_slice(suite);
    m.extend_from_slice(label);
    m.extend_from_slice(info);
    Hkdf::<Sha256>::from_prk(prk).expect("prk 长度固定").expand(&m, out).expect("长度合法");
}

fn kem_shared(dh: &[u8; 32], enc: &[u8; 32], pk_r: &[u8; 32]) -> [u8; 32] {
    let mut ctx = [0u8; 64];
    ctx[..32].copy_from_slice(enc);
    ctx[32..].copy_from_slice(pk_r);
    kem_extract_expand(dh, &ctx)
}

/// ExtractAndExpand：dh 是一段（base 模式 32 字节）或两段（auth 模式 64 字节），ctx 是 kem_context
fn kem_extract_expand(dh: &[u8], ctx: &[u8]) -> [u8; 32] {
    let prk = labeled_extract(KEM_SUITE, b"", b"eae_prk", dh);
    let mut out = [0u8; 32];
    labeled_expand(KEM_SUITE, &prk, b"shared_secret", ctx, &mut out);
    out
}

const MODE_BASE: u8 = 0x00;
const MODE_AUTH: u8 = 0x02;

fn key_schedule(shared: &[u8; 32], info: &[u8]) -> (Aes256Gcm, [u8; 12]) {
    key_schedule_mode(MODE_BASE, shared, info)
}

fn key_schedule_mode(mode: u8, shared: &[u8; 32], info: &[u8]) -> (Aes256Gcm, [u8; 12]) {
    let psk_id_hash = labeled_extract(HPKE_SUITE, b"", b"psk_id_hash", b"");
    let info_hash = labeled_extract(HPKE_SUITE, b"", b"info_hash", info);
    let mut ctx = [0u8; 65];
    ctx[0] = mode;
    ctx[1..33].copy_from_slice(&psk_id_hash);
    ctx[33..].copy_from_slice(&info_hash);
    let secret = labeled_extract(HPKE_SUITE, shared, b"secret", b"");
    let mut key = [0u8; 32];
    let mut nonce = [0u8; 12];
    labeled_expand(HPKE_SUITE, &secret, b"key", &ctx, &mut key);
    labeled_expand(HPKE_SUITE, &secret, b"base_nonce", &ctx, &mut nonce);
    (Aes256Gcm::new(&key.into()), nonce)
}

fn dh(sk: &StaticSecret, pk: &PublicKey) -> Result<[u8; 32]> {
    let s = sk.diffie_hellman(pk);
    if !s.was_contributory() {
        return Err(Error::Format); // 对方公钥是小阶点：拒绝（和 Go crypto/ecdh 一致）
    }
    Ok(s.to_bytes())
}

/// 加密：eph 为 None 时随机生成一次性密钥（测试向量才指定）
pub fn hpke_seal(pk_r: &[u8; 32], info: &[u8], aad: &[u8], pt: &[u8], eph: Option<[u8; 32]>) -> Result<([u8; 32], Vec<u8>)> {
    let sk_e = StaticSecret::from(match eph {
        Some(e) => e,
        None => random32()?,
    });
    let enc = PublicKey::from(&sk_e).to_bytes();
    let pk = PublicKey::from(*pk_r);
    let shared = kem_shared(&dh(&sk_e, &pk)?, &enc, pk_r);
    let (aead, nonce) = key_schedule(&shared, info);
    let ct = aead.encrypt(Nonce::from_slice(&nonce), Payload { msg: pt, aad }).map_err(|_| Error::Format)?;
    Ok((enc, ct))
}

pub fn hpke_open(sk_r: &[u8; 32], enc: &[u8; 32], info: &[u8], aad: &[u8], ct: &[u8]) -> Result<Vec<u8>> {
    hpke_open_pk(sk_r, &public_key(sk_r), enc, info, aad, ct)
}

/// 已知自己公钥时用这个（省一次标量乘法）
pub fn hpke_open_pk(sk_r: &[u8; 32], pk_r: &[u8; 32], enc: &[u8; 32], info: &[u8], aad: &[u8], ct: &[u8]) -> Result<Vec<u8>> {
    let sk = StaticSecret::from(*sk_r);
    let pk_r = *pk_r;
    let shared = kem_shared(&dh(&sk, &PublicKey::from(*enc))?, enc, &pk_r);
    let (aead, nonce) = key_schedule(&shared, info);
    aead.decrypt(Nonce::from_slice(&nonce), Payload { msg: ct, aad }).map_err(|_| Error::Format)
}

/// HPKE auth 模式（RFC 9180 mode_auth）：用发送方私钥 sk_s 加密给 pk_r，接收方能确认是 sk_s 的持有者发的（docs/agent-mcp.md §4.2）
pub fn hpke_auth_seal(pk_r: &[u8; 32], sk_s: &[u8; 32], info: &[u8], aad: &[u8], pt: &[u8], eph: Option<[u8; 32]>) -> Result<([u8; 32], Vec<u8>)> {
    let sk_e = StaticSecret::from(match eph {
        Some(e) => e,
        None => random32()?,
    });
    let enc = PublicKey::from(&sk_e).to_bytes();
    let pk = PublicKey::from(*pk_r);
    let mut dhs = [0u8; 64];
    dhs[..32].copy_from_slice(&dh(&sk_e, &pk)?);
    dhs[32..].copy_from_slice(&dh(&StaticSecret::from(*sk_s), &pk)?);
    let mut ctx = [0u8; 96];
    ctx[..32].copy_from_slice(&enc);
    ctx[32..64].copy_from_slice(pk_r);
    ctx[64..].copy_from_slice(&public_key(sk_s));
    let (aead, nonce) = key_schedule_mode(MODE_AUTH, &kem_extract_expand(&dhs, &ctx), info);
    let ct = aead.encrypt(Nonce::from_slice(&nonce), Payload { msg: pt, aad }).map_err(|_| Error::Format)?;
    Ok((enc, ct))
}

/// 只有发送方确实持有 pk_s 对应的私钥时才能解开；否则 Format
pub fn hpke_auth_open(sk_r: &[u8; 32], pk_s: &[u8; 32], enc: &[u8; 32], info: &[u8], aad: &[u8], ct: &[u8]) -> Result<Vec<u8>> {
    let sk = StaticSecret::from(*sk_r);
    let mut dhs = [0u8; 64];
    dhs[..32].copy_from_slice(&dh(&sk, &PublicKey::from(*enc))?);
    dhs[32..].copy_from_slice(&dh(&sk, &PublicKey::from(*pk_s))?);
    let mut ctx = [0u8; 96];
    ctx[..32].copy_from_slice(enc);
    ctx[32..64].copy_from_slice(&public_key(sk_r));
    ctx[64..].copy_from_slice(pk_s);
    let (aead, nonce) = key_schedule_mode(MODE_AUTH, &kem_extract_expand(&dhs, &ctx), info);
    aead.decrypt(Nonce::from_slice(&nonce), Payload { msg: ct, aad }).map_err(|_| Error::Format)
}

pub fn random32() -> Result<[u8; 32]> {
    let mut b = [0u8; 32];
    getrandom::getrandom(&mut b).map_err(|e| Error::Io(e.to_string()))?;
    Ok(b)
}

pub fn public_key(sk: &[u8; 32]) -> [u8; 32] {
    PublicKey::from(&StaticSecret::from(*sk)).to_bytes()
}

pub fn kid(pub_key: &[u8; 32]) -> String {
    hex(&Sha256::digest(pub_key)[..8])
}

pub fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

// ---------- 消息信封 hje1.<kid>.<b64url(enc‖ct)> ----------

pub fn seal_message(pub_key: &[u8; 32], payload: &[u8]) -> Result<String> {
    let k = kid(pub_key);
    let aad = format!("{MSG_PREFIX}{k}");
    let (enc, ct) = hpke_seal(pub_key, INFO_MESSAGE, aad.as_bytes(), payload, None)?;
    let mut body = enc.to_vec();
    body.extend_from_slice(&ct);
    Ok(format!("{aad}.{}", B64.encode(body)))
}

pub fn open_message(sk: &[u8; 32], env: &str) -> Result<Vec<u8>> {
    let rest = env.strip_prefix(MSG_PREFIX).ok_or(Error::Format)?;
    let (k, data) = rest.split_once('.').ok_or(Error::Format)?;
    if k.len() != 16 || !k.bytes().all(|c| c.is_ascii_hexdigit()) {
        return Err(Error::Format);
    }
    let pk = public_key(sk);
    if k != kid(&pk) {
        return Err(Error::WrongKey);
    }
    let body = B64.decode(data).map_err(|_| Error::Format)?;
    if body.len() < 32 + TAG {
        return Err(Error::Format);
    }
    let enc: [u8; 32] = body[..32].try_into().unwrap();
    hpke_open_pk(sk, &pk, &enc, INFO_MESSAGE, format!("{MSG_PREFIX}{k}").as_bytes(), &body[32..])
}

// ---------- 附件：AES-256-GCM 分块 ----------

fn file_header() -> [u8; 8] {
    let mut h = [0u8; 8];
    h[..4].copy_from_slice(b"HJF1");
    h[4..].copy_from_slice(&(CHUNK as u32).to_be_bytes());
    h
}

fn chunk_nonce(i: u64, last: bool) -> [u8; 12] {
    let mut n = [0u8; 12];
    n[3..11].copy_from_slice(&i.to_be_bytes());
    n[11] = last as u8;
    n
}

fn read_full(r: &mut impl Read, buf: &mut [u8]) -> Result<usize> {
    let mut n = 0;
    while n < buf.len() {
        match r.read(&mut buf[n..]) {
            Ok(0) => break,
            Ok(k) => n += k,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) => return Err(Error::Io(e.to_string())),
        }
    }
    Ok(n)
}

/// 边读边加密（发送端用）
pub fn encrypt_file(key: &[u8; 32], r: &mut impl Read, w: &mut impl Write) -> Result<()> {
    let g = Aes256Gcm::new(key.into());
    let hdr = file_header();
    w.write_all(&hdr).map_err(|e| Error::Io(e.to_string()))?;
    let (mut cur, mut next) = (vec![0u8; CHUNK], vec![0u8; CHUNK]);
    let mut n = read_full(r, &mut cur)?;
    for i in 0u64.. {
        let m = if n == CHUNK { read_full(r, &mut next)? } else { 0 };
        let last = m == 0;
        let ct = g.encrypt(Nonce::from_slice(&chunk_nonce(i, last)), Payload { msg: &cur[..n], aad: &hdr }).map_err(|_| Error::Format)?;
        w.write_all(&ct).map_err(|e| Error::Io(e.to_string()))?;
        if last {
            break;
        }
        std::mem::swap(&mut cur, &mut next);
        n = m;
    }
    Ok(())
}

/// 边读边解密并校验：截断、换序、删块、改动都会返回 Err（已经写出的部分由调用方丢弃）
pub fn decrypt_file(key: &[u8; 32], r: &mut impl Read, w: &mut impl Write) -> Result<()> {
    let g = Aes256Gcm::new(key.into());
    let mut hdr = [0u8; 8];
    if read_full(r, &mut hdr)? != 8 || hdr != file_header() {
        return Err(Error::Format);
    }
    let size = CHUNK + TAG;
    let (mut cur, mut next) = (vec![0u8; size], vec![0u8; size]);
    let mut n = read_full(r, &mut cur)?;
    for i in 0u64.. {
        let m = if n == size { read_full(r, &mut next)? } else { 0 };
        let last = m == 0;
        let pt = g.decrypt(Nonce::from_slice(&chunk_nonce(i, last)), Payload { msg: &cur[..n], aad: &hdr }).map_err(|_| Error::Format)?;
        w.write_all(&pt).map_err(|e| Error::Io(e.to_string()))?;
        if last {
            break;
        }
        std::mem::swap(&mut cur, &mut next);
        n = m;
    }
    Ok(())
}

// ---------- 密码、恢复码、锁住的副本、核对码 ----------

/// Argon2id（3 轮、64 MiB、1 线程）→ (登录凭证, 解锁钥匙)
pub fn password_keys(password: &[u8], salt: &[u8]) -> Result<([u8; 32], [u8; 32])> {
    let params = argon2::Params::new(64 * 1024, 3, 1, Some(64)).map_err(|_| Error::Format)?;
    let a = argon2::Argon2::new(argon2::Algorithm::Argon2id, argon2::Version::V0x13, params);
    let mut out = [0u8; 64];
    a.hash_password_into(password, salt, &mut out).map_err(|_| Error::Format)?;
    Ok((out[..32].try_into().unwrap(), out[32..].try_into().unwrap()))
}

pub fn recovery_key(code: &[u8]) -> [u8; 32] {
    let mut k = [0u8; 32];
    Hkdf::<Sha256>::new(Some(b"huijian e2e v1 recovery"), code).expand(b"", &mut k).unwrap();
    k
}

/// 配对码带钥匙（e2ee-client.md §12）：一次性钥匙 S（16 字节）派生锁住私钥的 AES 钥匙
pub fn pair_key(secret: &[u8]) -> [u8; 32] {
    let mut k = [0u8; 32];
    Hkdf::<Sha256>::new(Some(b"huijian pair v1"), secret).expand(b"", &mut k).unwrap();
    k
}

pub fn wrap(prefix: &str, key: &[u8; 32], pt: &[u8], nonce: Option<[u8; 12]>) -> Result<String> {
    let nonce = match nonce {
        Some(n) => n,
        None => random32()?[..12].try_into().unwrap(),
    };
    let ct = Aes256Gcm::new(key.into())
        .encrypt(Nonce::from_slice(&nonce), Payload { msg: pt, aad: prefix.as_bytes() })
        .map_err(|_| Error::Format)?;
    let mut raw = nonce.to_vec();
    raw.extend_from_slice(&ct);
    Ok(format!("{prefix}.{}", B64.encode(raw)))
}

pub fn unwrap(prefix: &str, key: &[u8; 32], s: &str) -> Result<Vec<u8>> {
    let data = s.strip_prefix(prefix).and_then(|r| r.strip_prefix('.')).ok_or(Error::Format)?;
    let raw = B64.decode(data).map_err(|_| Error::Format)?;
    if raw.len() < 12 + TAG {
        return Err(Error::Format);
    }
    Aes256Gcm::new(key.into())
        .decrypt(Nonce::from_slice(&raw[..12]), Payload { msg: &raw[12..], aad: prefix.as_bytes() })
        .map_err(|_| Error::Format)
}

const CROCKFORD: &[u8] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

pub fn format_recovery(code: &[u8]) -> String {
    let (mut s, mut acc, mut bits, mut n) = (String::new(), 0u32, 0, 0);
    for &b in code {
        acc = acc << 8 | b as u32;
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            s.push(CROCKFORD[((acc >> bits) & 31) as usize] as char);
            n += 1;
            if n % 5 == 0 && n < 25 {
                s.push('-');
            }
        }
    }
    if bits > 0 {
        s.push(CROCKFORD[((acc << (5 - bits)) & 31) as usize] as char);
    }
    s
}

pub fn parse_recovery(s: &str) -> Result<Vec<u8>> {
    let (mut out, mut acc, mut bits) = (Vec::new(), 0u32, 0);
    for c in s.to_ascii_uppercase().bytes() {
        let c = match c {
            b'-' | b' ' => continue,
            b'O' => b'0',
            b'I' | b'L' => b'1',
            c => c,
        };
        let v = CROCKFORD.iter().position(|&x| x == c).ok_or(Error::Format)?;
        acc = acc << 5 | v as u32;
        bits += 5;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    if out.len() != 16 {
        return Err(Error::Format);
    }
    Ok(out)
}

/// 核对码的承诺：pub 是新设备公钥，account 是新设备看到的账号公钥（见 server/e2e.go 的说明）
pub fn sas_commit(pub_key: &[u8; 32], account: &[u8; 32], nb: &[u8; 32]) -> [u8; 32] {
    Sha256::new().chain_update(b"huijian e2e v1 commit").chain_update(pub_key).chain_update(account).chain_update(nb).finalize().into()
}

pub fn sas_code(pub_key: &[u8; 32], account: &[u8; 32], na: &[u8; 32], nb: &[u8; 32]) -> String {
    let h = Sha256::new()
        .chain_update(b"huijian e2e v1 sas")
        .chain_update(pub_key)
        .chain_update(account)
        .chain_update(na)
        .chain_update(nb)
        .finalize();
    format!("{:06}", u32::from_be_bytes(h[..4].try_into().unwrap()) % 1_000_000)
}
