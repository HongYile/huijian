// JSON 调用层：用服务端生成的测试向量逐个操作核对（各端只通过这一层使用核心库）
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use base64::Engine;
use huijian_core::api::call;
use serde_json::{json, Value};

const DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../server/testdata");

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
    assert_eq!(r["ok"], false, "{req} 应失败");
    assert_eq!(r["error"], code, "{req} → {r}");
    assert!(r["message"].as_str().map_or(false, |m| !m.is_empty()));
}

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
}

fn hex_to_b64(s: &str) -> String {
    B64.encode(unhex(s))
}

#[test]
fn vectors_through_api() {
    let v: Value = serde_json::from_str(&std::fs::read_to_string(format!("{DIR}/e2e_vectors.json")).unwrap()).unwrap();
    let sk = hex_to_b64(v["recipient_sk"].as_str().unwrap());

    // 公钥与 kid
    let p = ok(json!({"op": "public_key", "sk": sk}));
    assert_eq!(p["pub"], v["recipient_pk_b64url"]);
    assert_eq!(p["kid"], v["kid"]);

    // 消息：先给一把不对的钥匙，再给对的
    let other = ok(json!({"op": "keypair"}));
    let m = ok(json!({"op": "open_message", "keys": [other["sk"], sk], "envelope": v["envelope"]}));
    let want: Value = serde_json::from_str(v["payload"].as_str().unwrap()).unwrap();
    assert_eq!(m["payload"], want);
    assert_eq!(m["kid"], v["kid"]);
    err(json!({"op": "open_message", "keys": [other["sk"]], "envelope": v["envelope"]}), "wrong_key");
    let mut bad_env = v["envelope"].as_str().unwrap().to_string();
    bad_env.push('A');
    err(json!({"op": "open_message", "keys": [sk], "envelope": bad_env}), "format");

    // 密码派生
    let pk = ok(json!({"op": "password_keys", "password": v["password"], "salt": v["password_salt"]}));
    assert_eq!(pk["auth_key"], hex_to_b64(v["password_auth_key"].as_str().unwrap()));
    assert_eq!(pk["unlock_key"], hex_to_b64(v["password_unlock_key"].as_str().unwrap()));
    let un = ok(json!({"op": "unwrap", "prefix": "hjp1", "key": pk["unlock_key"], "wrap": v["password_wrap"]}));
    assert_eq!(un["data"], sk);
    err(json!({"op": "unwrap", "prefix": "hjr1", "key": pk["unlock_key"], "wrap": v["password_wrap"]}), "format");
    err(json!({"op": "password_keys", "password": "x", "salt": "0011"}), "weak_params");

    // 恢复码
    let rk = ok(json!({"op": "recovery_key", "code": v["recovery_code"].as_str().unwrap().to_lowercase()}));
    assert_eq!(rk["key"], hex_to_b64(v["recovery_key"].as_str().unwrap()));
    assert_eq!(rk["code"], v["recovery_code"]);
    assert_eq!(ok(json!({"op": "unwrap", "prefix": "hjr1", "key": rk["key"], "wrap": v["recovery_wrap"]}))["data"], sk);
    err(json!({"op": "recovery_key", "code": "ABC"}), "format");

    // 设备转交（向量）+ 往返
    let dev = hex_to_b64(v["device_sk"].as_str().unwrap());
    assert_eq!(ok(json!({"op": "grant_open", "sk": dev, "grant": v["grant"]}))["data"], sk);
    let dev2 = ok(json!({"op": "keypair"}));
    let g = ok(json!({"op": "grant_seal", "sk": sk, "pub": dev2["pub"]}));
    assert!(g["grant"].as_str().unwrap().starts_with("hjg1."));
    assert_eq!(ok(json!({"op": "grant_open", "sk": dev2["sk"], "grant": g["grant"]}))["data"], sk);
    err(json!({"op": "grant_open", "sk": dev, "grant": g["grant"]}), "format");

    // 核对码
    let dev_pub = ok(json!({"op": "public_key", "sk": dev}))["pub"].clone();
    let acc = v["recipient_pk_b64url"].clone();
    let (na, nb) = (hex_to_b64(v["sas_nonce_a"].as_str().unwrap()), hex_to_b64(v["sas_nonce_b"].as_str().unwrap()));
    assert_eq!(ok(json!({"op": "sas_commit", "pub": dev_pub, "account": acc, "nonce": nb}))["commit"], hex_to_b64(v["sas_commit"].as_str().unwrap()));
    assert_eq!(ok(json!({"op": "sas_code", "pub": dev_pub, "account": acc, "na": na, "nb": nb}))["code"], v["sas_code"]);
    // 账号公钥不同，核对码和承诺都不同；缺 account 是请求错误
    assert_ne!(ok(json!({"op": "sas_code", "pub": dev_pub, "account": dev_pub, "na": na, "nb": nb}))["code"], v["sas_code"]);
    err(json!({"op": "sas_code", "pub": dev_pub, "na": na, "nb": nb}), "bad_request");
}

#[test]
fn roundtrips_and_errors() {
    // 新钥匙：锁住、解开；新恢复码可以解析回同一把钥匙
    let kp = ok(json!({"op": "keypair"}));
    let salt = ok(json!({"op": "new_salt"}))["salt"].as_str().unwrap().to_string();
    assert_eq!(salt.len(), 32);
    let pk = ok(json!({"op": "password_keys", "password": "correct horse battery", "salt": salt}));
    let w = ok(json!({"op": "wrap", "prefix": "hjp1", "key": pk["unlock_key"], "data": kp["sk"]}));
    assert_eq!(ok(json!({"op": "unwrap", "prefix": "hjp1", "key": pk["unlock_key"], "wrap": w["wrap"]}))["data"], kp["sk"]);
    let rn = ok(json!({"op": "recovery_new"}));
    assert_eq!(rn["code"].as_str().unwrap().len(), 26 + 4);
    assert_eq!(ok(json!({"op": "recovery_key", "code": rn["code"]}))["key"], rn["key"]);
    err(json!({"op": "wrap", "prefix": "hjg1", "key": pk["unlock_key"], "data": kp["sk"]}), "bad_request");

    // 消息往返
    let env = ok(json!({"op": "seal_message", "pub": kp["pub"], "payload": "{\"v\":1,\"text\":\"你好 🔒\"}"}));
    let m = ok(json!({"op": "open_message", "keys": [kp["sk"]], "envelope": env["envelope"]}));
    assert_eq!(m["payload"]["text"], "你好 🔒");

    // 附件往返：失败时不留半成品
    let dir = std::env::temp_dir().join(format!("hj-api-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let (src, enc, dec) = (dir.join("a.bin"), dir.join("a.enc"), dir.join("a.out"));
    let data: Vec<u8> = (0..200_000u32).map(|i| (i * 7 % 251) as u8).collect();
    std::fs::write(&src, &data).unwrap();
    let key = ok(json!({"op": "random32"}))["value"].clone();
    ok(json!({"op": "encrypt_file", "key": key, "src": src, "dst": enc}));
    ok(json!({"op": "decrypt_file", "key": key, "src": enc, "dst": dec}));
    assert_eq!(std::fs::read(&dec).unwrap(), data);
    let other = ok(json!({"op": "random32"}))["value"].clone();
    let bad_out = dir.join("b.out");
    err(json!({"op": "decrypt_file", "key": other, "src": enc, "dst": bad_out}), "format");
    assert!(!bad_out.exists() && !dir.join("b.out.hj-part").exists());
    err(json!({"op": "decrypt_file", "key": key, "src": dir.join("missing"), "dst": bad_out}), "io");
    std::fs::remove_dir_all(&dir).unwrap();

    // PBKDF2：和 Python hashlib 一致；轮数太少拒绝
    let p = ok(json!({"op": "pbkdf2", "password": "pass-回笺-123", "salt": "00112233445566778899aabbccddeeff", "iterations": 600000}));
    assert_eq!(p["password_key"], hex_to_b64("360a536542cf8b350c10d1bef65ec03906b5e8df471516ae9832571dd784d6df"));
    err(json!({"op": "pbkdf2", "password": "x", "salt": "00", "iterations": 1000}), "weak_params");

    // Markdown、密码检查
    let md = ok(json!({"op": "md_build", "text": "标题", "desp": "- [x] 完成", "atts": []}));
    assert_eq!(md["preview"], "☑ 完成");
    assert_eq!(md["doc"]["v"], 1);
    assert_eq!(ok(json!({"op": "check_password", "password": "password2024!"}))["strong"], false);
    assert_eq!(ok(json!({"op": "check_password", "password": "Tq7#mZ2!pL9x", "username": "alice"}))["strong"], true);

    // 请求本身有问题
    assert_eq!(serde_json::from_str::<Value>(&call(b"not json")).unwrap()["error"], "bad_request");
    err(json!({"op": "nope"}), "bad_request");
    err(json!({"op": "unwrap", "prefix": "hjp1", "key": "!!", "wrap": "x"}), "bad_request");
    err(json!({"noop": 1}), "bad_request");
}
