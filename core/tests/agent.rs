// agent 双向（docs/agent-mcp.md §11）：与服务端 server/testdata/agent_vectors.json 逐字节核对
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use base64::Engine;
use huijian_core::api::call;
use huijian_core::{agent, crypto};
use serde_json::{json, Value};

fn c(req: Value) -> Value {
    serde_json::from_str(&call(req.to_string().as_bytes())).unwrap()
}
fn ok(req: Value) -> Value {
    let r = c(req.clone());
    assert_eq!(r["ok"], true, "{req} → {r}");
    r
}
fn err(req: Value, code: &str) {
    let r = c(req.clone());
    assert_eq!(r["ok"], false, "{req} 应失败：{r}");
    assert_eq!(r["error"], code, "{req} → {r}");
}

fn vec() -> Value {
    serde_json::from_str(&std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../server/testdata/agent_vectors.json")).unwrap()).unwrap()
}
fn k(v: &Value, name: &str) -> [u8; 32] {
    B64.decode(v[name].as_str().unwrap()).unwrap().try_into().unwrap()
}
fn st<'a>(v: &'a Value, name: &str) -> &'a str {
    v[name].as_str().unwrap()
}

#[test]
fn vectors_match_server() {
    let v = vec();
    let (acct_sk, acct_pub, sess_sk, sess_pub) = (k(&v, "account_sk"), k(&v, "account_pub"), k(&v, "session_sk"), k(&v, "session_pub"));
    assert_eq!(crypto::public_key(&acct_sk), acct_pub);
    assert_eq!(crypto::public_key(&sess_sk), sess_pub);
    let (na, nb) = (k(&v, "na"), k(&v, "nb"));
    assert_eq!(B64.encode(agent::commit(&sess_pub, &acct_pub, &nb, st(&v, "name"))), st(&v, "commit"));
    assert_ne!(B64.encode(agent::commit(&sess_pub, &acct_pub, &nb, "别的名字")), st(&v, "commit"));
    assert_eq!(agent::sas(&sess_pub, &acct_pub, &na, &nb), st(&v, "sas"));
    let sid = st(&v, "session_id");
    // 加密结果逐字节一致
    assert_eq!(agent::seal(&acct_pub, &sess_sk, sid, st(&v, "message").as_bytes(), Some(k(&v, "eph1_sk"))).unwrap(), st(&v, "message_envelope"));
    assert_eq!(agent::reply_seal(&sess_pub, &acct_sk, sid, 42, st(&v, "reply").as_bytes(), Some(k(&v, "eph2_sk"))).unwrap(), st(&v, "reply_envelope"));
    assert_eq!(crypto::wrap(agent::ATTEST_PREFIX, &agent::attest_key(&acct_sk), st(&v, "attest_plain").as_bytes(), Some([0x0c; 12])).unwrap(), st(&v, "attest"));
    // 解开
    let (s2, pt) = agent::open(&acct_sk, &sess_pub, st(&v, "message_envelope")).unwrap();
    assert_eq!((s2.as_str(), pt.as_slice()), (sid, st(&v, "message").as_bytes()));
    assert_eq!(agent::reply_open(&sess_sk, &acct_pub, st(&v, "reply_envelope"), 42).unwrap(), st(&v, "reply").as_bytes());
    // 被回复的消息 id 换了解不开
    assert!(agent::reply_open(&sess_sk, &acct_pub, st(&v, "reply_envelope"), 43).is_err());
}

#[test]
fn api_ops() {
    let v = vec();
    let (acct_sk, acct_pub, sess_pub, sid) = (st(&v, "account_sk"), st(&v, "account_pub"), st(&v, "session_pub"), st(&v, "session_id"));
    assert_eq!(ok(json!({"op": "agent_commit", "pub": sess_pub, "account": acct_pub, "nonce": v["nb"], "name": v["name"]}))["commit"], v["commit"]);
    assert_eq!(ok(json!({"op": "agent_sas", "pub": sess_pub, "account": acct_pub, "na": v["na"], "nb": v["nb"]}))["code"], v["sas"]);

    // 会话证明：服务端写的能核对；会话 id 或公钥对不上、换了账号钥匙都不行
    let r = ok(json!({"op": "agent_attest_open", "sk": acct_sk, "attest": v["attest"], "session_id": sid, "pub": sess_pub}));
    assert_eq!((r["name"].as_str().unwrap(), r["approved_at"].as_i64().unwrap()), ("家里 Claude Code", 1763600000));
    err(json!({"op": "agent_attest_open", "sk": acct_sk, "attest": v["attest"], "session_id": "as0000000000000000", "pub": sess_pub}), "format");
    err(json!({"op": "agent_attest_open", "sk": acct_sk, "attest": v["attest"], "session_id": sid, "pub": acct_pub}), "format");
    let other = ok(json!({"op": "keypair"}))["sk"].clone();
    err(json!({"op": "agent_attest_open", "sk": other, "attest": v["attest"], "session_id": sid, "pub": sess_pub}), "format");
    // 自己写、自己核对
    let att = ok(json!({"op": "agent_attest_seal", "sk": acct_sk, "session_id": sid, "pub": sess_pub, "name": "笔记本 <Codex>", "approved_at": 1}))["attest"].clone();
    assert_eq!(ok(json!({"op": "agent_attest_open", "sk": acct_sk, "attest": att, "session_id": sid, "pub": sess_pub}))["name"], "笔记本 <Codex>");
    err(json!({"op": "agent_attest_seal", "sk": acct_sk, "session_id": sid, "pub": "abc", "name": "x", "approved_at": 1}), "bad_request");

    // 解开 agent 消息：多把钥匙按 kid 选；会话公钥不对、会话 id 不对都不行
    let r = ok(json!({"op": "agent_open", "keys": [other, acct_sk], "session_pub": sess_pub, "session_id": sid, "envelope": v["message_envelope"]}));
    assert_eq!(r["payload"]["choices"], json!(["删", "保留"]));
    err(json!({"op": "agent_open", "keys": [acct_sk], "session_pub": acct_pub, "session_id": sid, "envelope": v["message_envelope"]}), "format");
    err(json!({"op": "agent_open", "keys": [acct_sk], "session_pub": sess_pub, "session_id": "as1", "envelope": v["message_envelope"]}), "format");
    err(json!({"op": "agent_open", "keys": [other], "session_pub": sess_pub, "session_id": sid, "envelope": v["message_envelope"]}), "wrong_key");
    err(json!({"op": "agent_open", "keys": [acct_sk], "session_pub": sess_pub, "session_id": sid, "envelope": "hje1.x"}), "format");

    // 回复：agent 用会话私钥能解开；副本账号自己能解开
    let payload = r#"{"v":1,"re_seq":1,"text":"保留","n":"AAAAAAAAAAAAAAAAAAAAAA","sent_at":1,"device":"mac"}"#;
    let r = ok(json!({"op": "agent_reply_seal", "sk": acct_sk, "session_pub": sess_pub, "session_id": sid, "msg_id": 7, "payload": payload}));
    let env = r["envelope"].as_str().unwrap();
    assert!(env.starts_with(&format!("hjq1.{sid}.")));
    assert_eq!(agent::reply_open(&k(&v, "session_sk"), &k(&v, "account_pub"), env, 7).unwrap(), payload.as_bytes());
    assert_eq!(ok(json!({"op": "open_message", "keys": [acct_sk], "envelope": r["copy"]}))["payload"]["text"], "保留");
    err(json!({"op": "agent_reply_seal", "sk": acct_sk, "session_pub": sess_pub, "session_id": sid, "msg_id": 0, "payload": payload}), "bad_request");
    err(json!({"op": "agent_reply_seal", "sk": acct_sk, "session_pub": sess_pub, "session_id": "a.b", "msg_id": 7, "payload": payload}), "format");

    // agent 一侧：发消息、解开回复
    let e = ok(json!({"op": "agent_seal", "account": acct_pub, "sk": v["session_sk"], "session_id": sid, "payload": r#"{"v":1,"kind":"receipt","reply_id":3,"n":"x","received_at":1}"#}))["envelope"].clone();
    assert_eq!(ok(json!({"op": "agent_open", "keys": [acct_sk], "session_pub": sess_pub, "session_id": sid, "envelope": e}))["payload"]["kind"], "receipt");
    assert_eq!(ok(json!({"op": "agent_reply_open", "sk": v["session_sk"], "account": acct_pub, "envelope": env, "msg_id": 7}))["payload"]["text"], "保留");
    err(json!({"op": "agent_reply_open", "sk": v["session_sk"], "account": acct_pub, "envelope": env, "msg_id": 8}), "format");
}
