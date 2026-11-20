//! agent 双向的密码学格式（docs/agent-mcp.md §11.2），与 server/agent_crypto.go 逐字节一致（core/tests/agent.rs 用同一份向量核对）。
//! 设备一侧用到：登录承诺 / 核对码、会话证明 hja1、解开 agent 消息与回执 hje2、给 agent 的回复 hjq1。
use crate::crypto::{self, Error, Result};
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use base64::Engine;
use hkdf::Hkdf;
use sha2::{Digest, Sha256};

pub const MSG_PREFIX: &str = "hje2.";
pub const REPLY_PREFIX: &str = "hjq1.";
pub const ATTEST_PREFIX: &str = "hja1";
pub const INFO_MESSAGE: &[u8] = b"huijian agent v1 message";
pub const INFO_REPLY: &[u8] = b"huijian agent v1 reply";

/// 登录承诺：会话公钥、agent 看到的账号公钥、agent 的随机数 nb
pub fn commit(sess_pub: &[u8; 32], account: &[u8; 32], nb: &[u8; 32]) -> [u8; 32] {
    Sha256::new().chain_update(b"huijian agent v1 commit").chain_update(sess_pub).chain_update(account).chain_update(nb).finalize().into()
}

/// 6 位核对码
pub fn sas(sess_pub: &[u8; 32], account: &[u8; 32], na: &[u8; 32], nb: &[u8; 32]) -> String {
    let h = Sha256::new()
        .chain_update(b"huijian agent v1 sas")
        .chain_update(sess_pub)
        .chain_update(account)
        .chain_update(na)
        .chain_update(nb)
        .finalize();
    format!("{:06}", u32::from_be_bytes(h[..4].try_into().unwrap()) % 1_000_000)
}

/// 会话证明的钥匙：只有持有账号私钥的设备能写、能验
pub fn attest_key(account_sk: &[u8; 32]) -> [u8; 32] {
    let mut k = [0u8; 32];
    Hkdf::<Sha256>::new(Some(b"huijian agent v1 attest"), account_sk).expand(b"", &mut k).unwrap();
    k
}

fn valid_sid(sid: &str) -> bool {
    !sid.is_empty() && sid.len() <= 64 && sid.bytes().all(|c| c.is_ascii_alphanumeric())
}

/// hje2 信封拆成 (kid, 会话 id, enc‖ct)；格式不对返回 Format
pub fn envelope_parts(env: &str) -> Result<(&str, &str, Vec<u8>)> {
    let rest = env.strip_prefix(MSG_PREFIX).ok_or(Error::Format)?;
    let mut it = rest.splitn(3, '.');
    let (k, sid, data) = (it.next().ok_or(Error::Format)?, it.next().ok_or(Error::Format)?, it.next().ok_or(Error::Format)?);
    if k.len() != 16 || !k.bytes().all(|c| c.is_ascii_hexdigit()) || !valid_sid(sid) {
        return Err(Error::Format);
    }
    let raw = B64.decode(data).map_err(|_| Error::Format)?;
    if raw.len() < 32 + 16 {
        return Err(Error::Format);
    }
    Ok((k, sid, raw))
}

/// agent 一侧：会话私钥把载荷加密给账号公钥（测试和向量用；设备不发 hje2）
pub fn seal(account: &[u8; 32], sess_sk: &[u8; 32], sid: &str, pt: &[u8], eph: Option<[u8; 32]>) -> Result<String> {
    if !valid_sid(sid) {
        return Err(Error::Format);
    }
    let aad = format!("{MSG_PREFIX}{}.{sid}", crypto::kid(account));
    let (enc, ct) = crypto::hpke_auth_seal(account, sess_sk, INFO_MESSAGE, aad.as_bytes(), pt, eph)?;
    let mut raw = enc.to_vec();
    raw.extend_from_slice(&ct);
    Ok(format!("{aad}.{}", B64.encode(raw)))
}

/// 设备一侧：账号私钥解开 hje2，发送方必须是 sess_pub（取自核对过的会话证明）。kid 不是这把钥匙 → WrongKey
pub fn open(account_sk: &[u8; 32], sess_pub: &[u8; 32], env: &str) -> Result<(String, Vec<u8>)> {
    let (k, sid, raw) = envelope_parts(env)?;
    if k != crypto::kid(&crypto::public_key(account_sk)) {
        return Err(Error::WrongKey);
    }
    let enc: [u8; 32] = raw[..32].try_into().unwrap();
    let pt = crypto::hpke_auth_open(account_sk, sess_pub, &enc, INFO_MESSAGE, format!("{MSG_PREFIX}{k}.{sid}").as_bytes(), &raw[32..])?;
    Ok((sid.to_string(), pt))
}

/// 设备一侧：账号私钥把回复加密给会话公钥；附加数据带被回复的消息 id（服务器换不了「回的是哪条」）
pub fn reply_seal(sess_pub: &[u8; 32], account_sk: &[u8; 32], sid: &str, msg_id: i64, pt: &[u8], eph: Option<[u8; 32]>) -> Result<String> {
    if !valid_sid(sid) {
        return Err(Error::Format);
    }
    let pre = format!("{REPLY_PREFIX}{sid}");
    let (enc, ct) = crypto::hpke_auth_seal(sess_pub, account_sk, INFO_REPLY, format!("{pre}.{msg_id}").as_bytes(), pt, eph)?;
    let mut raw = enc.to_vec();
    raw.extend_from_slice(&ct);
    Ok(format!("{pre}.{}", B64.encode(raw)))
}

/// agent 一侧：会话私钥解开回复，发送方必须是账号公钥（测试和向量用）
pub fn reply_open(sess_sk: &[u8; 32], account: &[u8; 32], env: &str, msg_id: i64) -> Result<Vec<u8>> {
    let rest = env.strip_prefix(REPLY_PREFIX).ok_or(Error::Format)?;
    let (sid, data) = rest.split_once('.').ok_or(Error::Format)?;
    if !valid_sid(sid) {
        return Err(Error::Format);
    }
    let raw = B64.decode(data).map_err(|_| Error::Format)?;
    if raw.len() < 32 + 16 {
        return Err(Error::Format);
    }
    let enc: [u8; 32] = raw[..32].try_into().unwrap();
    crypto::hpke_auth_open(sess_sk, account, &enc, INFO_REPLY, format!("{REPLY_PREFIX}{sid}.{msg_id}").as_bytes(), &raw[32..])
}
