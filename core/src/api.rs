//! JSON 调用层：各端只通过 `call(请求 JSON) -> 结果 JSON` 使用本库，绑定代码因此很薄（Swift 一个函数、JNI 一个函数）。
//!
//! 请求 `{"op": "<操作>", ...参数}`；成功返回 `{"ok": true, ...结果}`，失败返回 `{"ok": false, "error": "<代码>", "message": "<中文说明>"}`。
//! 二进制字段（钥匙、随机数、凭证）一律 base64url 无填充；盐是十六进制（与服务端 /v1/prelogin 一致）。
//! 错误代码：bad_request（参数缺失或格式不对）、format（密文格式不对或被篡改）、wrong_key（不是这把钥匙加密的）、
//! io（文件读写失败）、weak_params（服务器给的派生参数太弱，拒绝）。
use crate::{agent, crypto, md, password};
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use base64::Engine;
use serde_json::{json, Map, Value};
use std::fs::File;
use std::io::{BufReader, BufWriter, Write};

/// PBKDF2 最少轮数：服务器给的更少就拒绝（防止被攻破的服务器骗出容易破解的派生值）
pub const PBKDF2_MIN_ITER: u32 = 600_000;

struct Fail(&'static str, String);

type R = std::result::Result<Value, Fail>;

fn bad(msg: impl Into<String>) -> Fail {
    Fail("bad_request", msg.into())
}

fn from_crypto(e: crypto::Error) -> Fail {
    match e {
        crypto::Error::Format => Fail("format", "格式不对或已被篡改".into()),
        crypto::Error::WrongKey => Fail("wrong_key", "不是用这把钥匙加密的".into()),
        crypto::Error::Io(m) => Fail("io", m),
    }
}

/// 处理一个请求；任何情况下都返回一个 JSON 字符串
pub fn call(req: &[u8]) -> String {
    let out = match serde_json::from_slice::<Value>(req) {
        Ok(Value::Object(m)) => dispatch(&m),
        _ => Err(bad("请求不是 JSON 对象")),
    };
    match out {
        Ok(Value::Object(mut m)) => {
            m.insert("ok".into(), Value::Bool(true));
            Value::Object(m).to_string()
        }
        Ok(_) => json!({"ok": true}).to_string(),
        Err(Fail(code, msg)) => json!({"ok": false, "error": code, "message": msg}).to_string(),
    }
}

fn s<'a>(m: &'a Map<String, Value>, k: &str) -> std::result::Result<&'a str, Fail> {
    m.get(k).and_then(Value::as_str).ok_or_else(|| bad(format!("缺少参数 {k}")))
}

fn bytes(m: &Map<String, Value>, k: &str) -> std::result::Result<Vec<u8>, Fail> {
    B64.decode(s(m, k)?).map_err(|_| bad(format!("参数 {k} 不是 base64url")))
}

fn key32(m: &Map<String, Value>, k: &str) -> std::result::Result<[u8; 32], Fail> {
    bytes(m, k)?.try_into().map_err(|_| bad(format!("参数 {k} 应为 32 字节")))
}

fn hex_bytes(m: &Map<String, Value>, k: &str) -> std::result::Result<Vec<u8>, Fail> {
    let h = s(m, k)?;
    if h.len() % 2 != 0 {
        return Err(bad(format!("参数 {k} 不是十六进制")));
    }
    (0..h.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&h[i..i + 2], 16).map_err(|_| bad(format!("参数 {k} 不是十六进制"))))
        .collect()
}

fn b64(b: &[u8]) -> Value {
    Value::String(B64.encode(b))
}

fn wrap_prefix(m: &Map<String, Value>) -> std::result::Result<&str, Fail> {
    match s(m, "prefix")? {
        p @ ("hjp1" | "hjr1") => Ok(p),
        _ => Err(bad("prefix 只能是 hjp1 / hjr1")),
    }
}

fn dispatch(m: &Map<String, Value>) -> R {
    match s(m, "op")? {
        "version" => Ok(json!({"version": env!("CARGO_PKG_VERSION")})),

        // ---------- 登录凭证 ----------
        "password_keys" => {
            let salt = hex_bytes(m, "salt")?;
            if salt.len() < 16 {
                return Err(Fail("weak_params", "盐太短".into()));
            }
            let (auth, unlock) = crypto::password_keys(s(m, "password")?.as_bytes(), &salt).map_err(from_crypto)?;
            Ok(json!({"auth_key": b64(&auth), "unlock_key": b64(&unlock)}))
        }
        "pbkdf2" => {
            let iter = m.get("iterations").and_then(Value::as_u64).ok_or_else(|| bad("缺少参数 iterations"))?;
            if iter < PBKDF2_MIN_ITER as u64 || iter > 10_000_000 {
                return Err(Fail("weak_params", format!("服务器给的 PBKDF2 轮数 {iter} 不合要求")));
            }
            let salt = hex_bytes(m, "salt")?;
            let mut out = [0u8; 32];
            pbkdf2::pbkdf2_hmac::<sha2::Sha256>(s(m, "password")?.as_bytes(), &salt, iter as u32, &mut out);
            Ok(json!({"password_key": b64(&out)}))
        }
        "new_salt" => {
            let r = crypto::random32().map_err(from_crypto)?;
            Ok(json!({"salt": crypto::hex(&r[..16])}))
        }
        "check_password" => {
            let user = m.get("username").and_then(Value::as_str).unwrap_or("");
            match password::check(s(m, "password")?, user) {
                None => Ok(json!({"strong": true})),
                Some(reason) => Ok(json!({"strong": false, "reason": reason})),
            }
        }

        // ---------- 钥匙 ----------
        "keypair" => {
            let sk = crypto::random32().map_err(from_crypto)?;
            let pk = crypto::public_key(&sk);
            Ok(json!({"sk": b64(&sk), "pub": b64(&pk), "kid": crypto::kid(&pk)}))
        }
        "public_key" => {
            let pk = crypto::public_key(&key32(m, "sk")?);
            Ok(json!({"pub": b64(&pk), "kid": crypto::kid(&pk)}))
        }
        "random32" => Ok(json!({"value": b64(&crypto::random32().map_err(from_crypto)?)})),
        "wrap" => {
            let w = crypto::wrap(wrap_prefix(m)?, &key32(m, "key")?, &bytes(m, "data")?, None).map_err(from_crypto)?;
            Ok(json!({"wrap": w}))
        }
        "unwrap" => {
            let d = crypto::unwrap(wrap_prefix(m)?, &key32(m, "key")?, s(m, "wrap")?).map_err(from_crypto)?;
            Ok(json!({"data": b64(&d)}))
        }

        // ---------- 恢复码 ----------
        "recovery_new" => {
            let r = crypto::random32().map_err(from_crypto)?;
            let code = &r[..16];
            Ok(json!({"code": crypto::format_recovery(code), "key": b64(&crypto::recovery_key(code))}))
        }
        "recovery_key" => {
            let code = crypto::parse_recovery(s(m, "code")?).map_err(|_| Fail("format", "恢复码格式不对：应为 26 位字母和数字".into()))?;
            Ok(json!({"key": b64(&crypto::recovery_key(&code)), "code": crypto::format_recovery(&code)}))
        }

        // ---------- 配对码带钥匙（e2ee-client.md §12） ----------
        "pair_key_new" => {
            let sk = key32(m, "sk")?;
            let r = crypto::random32().map_err(from_crypto)?;
            let secret = &r[..16];
            let w = crypto::wrap("hjc1", &crypto::pair_key(secret), &sk, None).map_err(from_crypto)?;
            Ok(json!({"secret": crypto::format_recovery(secret), "wrap": w}))
        }
        "pair_key_open" => {
            let secret = crypto::parse_recovery(s(m, "secret")?).map_err(|_| Fail("format", "配对码里的钥匙格式不对".into()))?;
            let sk = crypto::unwrap("hjc1", &crypto::pair_key(&secret), s(m, "wrap")?)
                .map_err(|_| Fail("format", "配对码里的钥匙对不上".into()))?;
            if sk.len() != 32 {
                return Err(Fail("format", "配对码锁住的私钥长度不对".into()));
            }
            Ok(json!({"data": b64(&sk)}))
        }
        "pair_format" => {
            let code = s(m, "code")?;
            if code.len() != 6 || !code.bytes().all(|b| b.is_ascii_digit()) {
                return Err(bad("code 应为 6 位数字"));
            }
            let secret = crypto::parse_recovery(s(m, "secret")?).map_err(|_| bad("secret 格式不对"))?;
            let server = s(m, "server")?;
            if !(server.starts_with("http://") || server.starts_with("https://")) {
                return Err(bad("server 应以 http:// 或 https:// 开头"));
            }
            let text = format!("{code}-{}", crypto::format_recovery(&secret));
            Ok(json!({"text": text, "link": format!("huijian://pair?server={}&code={}", pct_encode(server), text)}))
        }
        "pair_parse" => pair_parse(s(m, "input")?),
        "qr" => {
            let q = qrcode::QrCode::with_error_correction_level(s(m, "text")?.as_bytes(), qrcode::EcLevel::M)
                .map_err(|_| bad("内容太长，生成不了二维码"))?;
            let modules: String = q.to_colors().iter().map(|c| if *c == qrcode::Color::Dark { '1' } else { '0' }).collect();
            Ok(json!({"size": q.width(), "modules": modules}))
        }

        // ---------- 设备批准 ----------
        "grant_seal" => {
            let (enc, ct) = crypto::hpke_seal(&key32(m, "pub")?, crypto::INFO_GRANT, b"hjg1", &key32(m, "sk")?, None).map_err(from_crypto)?;
            let mut raw = enc.to_vec();
            raw.extend_from_slice(&ct);
            Ok(json!({"grant": format!("hjg1.{}", B64.encode(raw))}))
        }
        "grant_open" => {
            let raw = s(m, "grant")?
                .strip_prefix("hjg1.")
                .and_then(|d| B64.decode(d).ok())
                .filter(|r| r.len() > 32)
                .ok_or_else(|| Fail("format", "转交副本格式不对".into()))?;
            let enc: [u8; 32] = raw[..32].try_into().unwrap();
            let sk = crypto::hpke_open(&key32(m, "sk")?, &enc, crypto::INFO_GRANT, b"hjg1", &raw[32..]).map_err(from_crypto)?;
            if sk.len() != 32 {
                return Err(Fail("format", "转交的私钥长度不对".into()));
            }
            Ok(json!({"data": b64(&sk)}))
        }
        "sas_commit" => Ok(json!({"commit": b64(&crypto::sas_commit(&key32(m, "pub")?, &key32(m, "account")?, &key32(m, "nonce")?))})),
        "sas_code" => Ok(json!({"code": crypto::sas_code(&key32(m, "pub")?, &key32(m, "account")?, &key32(m, "na")?, &key32(m, "nb")?)})),

        // ---------- agent 双向（docs/agent-mcp.md §11） ----------
        "agent_commit" => Ok(json!({"commit": b64(&agent::commit(&key32(m, "pub")?, &key32(m, "account")?, &key32(m, "nonce")?, s(m, "name")?))})),
        "agent_sas" => Ok(json!({"code": agent::sas(&key32(m, "pub")?, &key32(m, "account")?, &key32(m, "na")?, &key32(m, "nb")?)})),
        "agent_attest_seal" => {
            let a = Attest {
                session_id: s(m, "session_id")?.into(),
                pub_key: s(m, "pub")?.into(),
                name: s(m, "name")?.into(),
                approved_at: m.get("approved_at").and_then(Value::as_i64).ok_or_else(|| bad("缺少参数 approved_at"))?,
            };
            key32(m, "pub")?;
            let pt = serde_json::to_vec(&a).unwrap();
            let att = crypto::wrap(agent::ATTEST_PREFIX, &agent::attest_key(&key32(m, "sk")?), &pt, None).map_err(from_crypto)?;
            Ok(json!({"attest": att}))
        }
        // 核对会话证明：必须是这把账号私钥写的，且写的就是这个会话、这个公钥（服务器换不了会话公钥）
        "agent_attest_open" => {
            let pt = crypto::unwrap(agent::ATTEST_PREFIX, &agent::attest_key(&key32(m, "sk")?), s(m, "attest")?).map_err(from_crypto)?;
            let a: Attest = serde_json::from_slice(&pt).map_err(|_| Fail("format", "会话证明内容不对".into()))?;
            if a.session_id != s(m, "session_id")? || a.pub_key != s(m, "pub")? {
                return Err(Fail("format", "会话证明和会话对不上".into()));
            }
            Ok(json!({"name": a.name, "approved_at": a.approved_at}))
        }
        // 解开 agent 消息或回执：keys 是账号私钥（可多把，按 kid 选），session_pub 取自核对过的会话证明
        "agent_open" => {
            let env = s(m, "envelope")?;
            let sess_pub = key32(m, "session_pub")?;
            let want = s(m, "session_id")?;
            let keys = m.get("keys").and_then(Value::as_array).ok_or_else(|| bad("缺少参数 keys"))?;
            let mut last = crypto::Error::WrongKey;
            for k in keys {
                let sk: [u8; 32] = k
                    .as_str()
                    .and_then(|x| B64.decode(x).ok())
                    .and_then(|b| b.try_into().ok())
                    .ok_or_else(|| bad("keys 里的钥匙格式不对"))?;
                match agent::open(&sk, &sess_pub, env) {
                    Ok((sid, pt)) => {
                        if sid != want {
                            return Err(Fail("format", "消息不是这个会话发的".into()));
                        }
                        let payload: Value = serde_json::from_slice(&pt).map_err(|_| Fail("format", "解开的内容不是 JSON".into()))?;
                        return Ok(json!({"payload": payload, "kid": crypto::kid(&crypto::public_key(&sk))}));
                    }
                    Err(crypto::Error::WrongKey) => continue,
                    Err(e) => last = e,
                }
            }
            Err(from_crypto(last))
        }
        // 回复 agent：envelope 给会话（hjq1），copy 是给账号自己的副本（hje1，别的设备显示用）
        "agent_reply_seal" => {
            let sk = key32(m, "sk")?;
            let payload = s(m, "payload")?.as_bytes();
            let msg_id = m.get("msg_id").and_then(Value::as_i64).filter(|x| *x > 0).ok_or_else(|| bad("缺少参数 msg_id"))?;
            let env = agent::reply_seal(&key32(m, "session_pub")?, &sk, s(m, "session_id")?, msg_id, payload, None).map_err(from_crypto)?;
            let copy = crypto::seal_message(&crypto::public_key(&sk), payload).map_err(from_crypto)?;
            Ok(json!({"envelope": env, "copy": copy}))
        }

        // agent 一侧（测试、自检用；命令行在 Go 里实现）
        "agent_seal" => {
            let env = agent::seal(&key32(m, "account")?, &key32(m, "sk")?, s(m, "session_id")?, s(m, "payload")?.as_bytes(), None).map_err(from_crypto)?;
            Ok(json!({"envelope": env}))
        }
        "agent_reply_open" => {
            let msg_id = m.get("msg_id").and_then(Value::as_i64).ok_or_else(|| bad("缺少参数 msg_id"))?;
            let pt = agent::reply_open(&key32(m, "sk")?, &key32(m, "account")?, s(m, "envelope")?, msg_id).map_err(from_crypto)?;
            let payload: Value = serde_json::from_slice(&pt).map_err(|_| Fail("format", "解开的内容不是 JSON".into()))?;
            Ok(json!({"payload": payload}))
        }

        // ---------- 消息与附件 ----------
        "open_message" => {
            let env = s(m, "envelope")?;
            let keys = m.get("keys").and_then(Value::as_array).ok_or_else(|| bad("缺少参数 keys"))?;
            let mut last = crypto::Error::WrongKey;
            for k in keys {
                let sk: [u8; 32] = k
                    .as_str()
                    .and_then(|x| B64.decode(x).ok())
                    .and_then(|b| b.try_into().ok())
                    .ok_or_else(|| bad("keys 里的钥匙格式不对"))?;
                match crypto::open_message(&sk, env) {
                    Ok(pt) => {
                        let payload: Value = serde_json::from_slice(&pt).map_err(|_| Fail("format", "解开的内容不是 JSON".into()))?;
                        return Ok(json!({"payload": payload, "kid": crypto::kid(&crypto::public_key(&sk))}));
                    }
                    Err(crypto::Error::WrongKey) => continue,
                    Err(e) => last = e,
                }
            }
            Err(from_crypto(last))
        }
        "seal_message" => {
            let env = crypto::seal_message(&key32(m, "pub")?, s(m, "payload")?.as_bytes()).map_err(from_crypto)?;
            Ok(json!({"envelope": env}))
        }
        "decrypt_file" | "encrypt_file" => {
            let key = key32(m, "key")?;
            let (src, dst) = (s(m, "src")?, s(m, "dst")?);
            let tmp = format!("{dst}.hj-part");
            let res = (|| -> crypto::Result<()> {
                let io = |e: std::io::Error| crypto::Error::Io(e.to_string());
                let mut r = BufReader::with_capacity(crypto::CHUNK * 2, File::open(src).map_err(io)?);
                let mut w = BufWriter::with_capacity(crypto::CHUNK * 2, File::create(&tmp).map_err(io)?);
                if s(m, "op").ok() == Some("decrypt_file") {
                    crypto::decrypt_file(&key, &mut r, &mut w)?;
                } else {
                    crypto::encrypt_file(&key, &mut r, &mut w)?;
                }
                w.flush().map_err(io)?;
                drop(w);
                std::fs::rename(&tmp, dst).map_err(io)
            })();
            if let Err(e) = res {
                let _ = std::fs::remove_file(&tmp); // 失败不留半成品
                return Err(from_crypto(e));
            }
            Ok(json!({}))
        }
        "md_build" => {
            let atts: Vec<md::Att> = match m.get("atts") {
                Some(a) => serde_json::from_value(a.clone()).map_err(|_| bad("atts 格式不对"))?,
                None => vec![],
            };
            let text = m.get("text").and_then(Value::as_str).unwrap_or("");
            let desp = m.get("desp").and_then(Value::as_str).unwrap_or("");
            let (doc, preview) = md::build(text, desp, &atts);
            let doc: Value = serde_json::from_str(&md::to_json(&doc)).map_err(|_| bad("内部错误"))?;
            Ok(json!({"doc": doc, "preview": preview}))
        }
        op => Err(bad(format!("不认识的操作 {op}"))),
    }
}

/// 解析用户输入的配对码：6 位配对码、长配对码（6 位 + 26 位一次性钥匙）、配对链接 huijian://pair?server=…&code=…
fn pair_parse(input: &str) -> R {
    let bad_fmt = || Fail("format", "配对码格式不对：应为 6 位数字，或扫码 / 复制得到的长配对码".into());
    let input = input.trim();
    let (mut server, mut code_str) = (None::<String>, input.to_string());
    let lower = input.to_ascii_lowercase();
    if lower.starts_with("huijian://pair") {
        let query = input.split_once('?').map(|(_, q)| q).ok_or_else(bad_fmt)?;
        code_str = String::new();
        for kv in query.split('&') {
            let (k, v) = kv.split_once('=').unwrap_or((kv, ""));
            let v = pct_decode(v).ok_or_else(bad_fmt)?;
            match k {
                "server" => server = Some(v),
                "code" => code_str = v,
                _ => {}
            }
        }
        if let Some(sv) = &server {
            // 不接受带用户信息（https://good.com@evil.com 这种伪装）、空白、控制字符和不可见字符的地址
            let invisible = |c: char| c.is_whitespace() || c.is_control() || matches!(c, '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2060}'..='\u{2064}' | '\u{FEFF}');
            if !(sv.starts_with("http://") || sv.starts_with("https://")) || sv.contains('@') || sv.chars().any(invisible) || !sv.is_ascii() {
                return Err(bad_fmt());
            }
        }
    }
    let compact: String = code_str.chars().filter(|c| !c.is_whitespace()).collect();
    if compact.len() < 6 || !compact.as_bytes()[..6].iter().all(u8::is_ascii_digit) {
        return Err(bad_fmt());
    }
    let (code, rest) = compact.split_at(6);
    let mut out = json!({"code": code});
    let rest = rest.trim_start_matches('-');
    if !rest.is_empty() {
        let secret = crypto::parse_recovery(rest).map_err(|_| bad_fmt())?;
        out["secret"] = Value::String(crypto::format_recovery(&secret));
    }
    if let Some(sv) = server {
        out["server"] = Value::String(sv);
    }
    Ok(out)
}

fn pct_encode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

fn pct_decode(s: &str) -> Option<String> {
    let b = s.as_bytes();
    let (mut out, mut i) = (Vec::new(), 0);
    while i < b.len() {
        match b[i] {
            b'%' => {
                let h = std::str::from_utf8(b.get(i + 1..i + 3)?).ok()?;
                out.push(u8::from_str_radix(h, 16).ok()?);
                i += 3;
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    String::from_utf8(out).ok()
}

/// 会话证明 hja1 的明文（字段顺序与服务端 agentAttest 一致）
#[derive(serde::Serialize, serde::Deserialize)]
struct Attest {
    session_id: String,
    #[serde(rename = "pub")]
    pub_key: String,
    name: String,
    approved_at: i64,
}
