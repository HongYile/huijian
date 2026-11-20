// 配对码带钥匙（e2ee-client.md §12）
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use base64::Engine;
use huijian_core::api::call;
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

#[test]
fn key_roundtrip_and_tamper() {
    let sk = ok(json!({"op": "keypair"}))["sk"].as_str().unwrap().to_string();
    let n = ok(json!({"op": "pair_key_new", "sk": sk}));
    let (secret, wrap) = (n["secret"].as_str().unwrap(), n["wrap"].as_str().unwrap());
    assert!(wrap.starts_with("hjc1."));
    assert_eq!(secret.len(), 30); // 26 位 + 4 个短横线
    assert_eq!(ok(json!({"op": "pair_key_open", "secret": secret, "wrap": wrap}))["data"], sk);
    // 小写、去掉短横线也能用
    let loose = secret.replace('-', "").to_lowercase();
    assert_eq!(ok(json!({"op": "pair_key_open", "secret": loose, "wrap": wrap}))["data"], sk);
    // 换一把钥匙、改一个字节、换前缀都解不开
    let other = ok(json!({"op": "pair_key_new", "sk": sk}));
    err(json!({"op": "pair_key_open", "secret": other["secret"], "wrap": wrap}), "format");
    let mut raw = B64.decode(&wrap[5..]).unwrap();
    raw[20] ^= 1;
    err(json!({"op": "pair_key_open", "secret": secret, "wrap": format!("hjc1.{}", B64.encode(&raw))}), "format");
    err(json!({"op": "pair_key_open", "secret": secret, "wrap": wrap.replacen("hjc1", "hjp1", 1)}), "format");
    err(json!({"op": "pair_key_open", "secret": "ABC", "wrap": wrap}), "format");
    // 同一私钥每次生成的 S 和密文都不同
    assert_ne!(other["secret"], n["secret"]);
    assert_ne!(other["wrap"], n["wrap"]);
}

#[test]
fn fixed_vector() {
    // 固定向量：S = 00..0f，私钥 = 20..3f，nonce = 40..4b（各端若自己实现可用它核对）
    use huijian_core::crypto;
    let secret: Vec<u8> = (0u8..16).collect();
    let sk: Vec<u8> = (0x20u8..0x40).collect();
    let nonce: [u8; 12] = std::array::from_fn(|i| 0x40 + i as u8);
    let w = crypto::wrap("hjc1", &crypto::pair_key(&secret), &sk, Some(nonce)).unwrap();
    let f = crypto::format_recovery(&secret);
    assert_eq!(f, "000G4-0R40M-30E20-9185G-R38E1W");
    assert_eq!(ok(json!({"op": "pair_key_open", "secret": f, "wrap": w}))["data"], B64.encode(&sk));
    assert_eq!(w, "hjc1.QEFCQ0RFRkdISUpLeMFqsd22Y9NgakDGtkBNmt5ukdq7V-MoxMSTClBRUHvZbe_eR5xJEQTzopfcuNXr");
}

#[test]
fn format_and_parse() {
    let secret = "000G4-0R40M-30E20-9184G-AYR8JW";
    let f = ok(json!({"op": "pair_format", "server": "https://push.example.com:8443/hj", "code": "123456", "secret": secret}));
    assert_eq!(f["text"], format!("123456-{secret}"));
    assert_eq!(f["link"], format!("huijian://pair?server=https%3A%2F%2Fpush.example.com%3A8443%2Fhj&code=123456-{secret}"));

    // 链接
    let p = ok(json!({"op": "pair_parse", "input": f["link"]}));
    assert_eq!(p["code"], "123456");
    assert_eq!(p["secret"], secret);
    assert_eq!(p["server"], "https://push.example.com:8443/hj");
    // 长配对码：带空格、小写、O/I/L 混写
    let p = ok(json!({"op": "pair_parse", "input": "  123 456 - 000g4 0r40m 30e20 9184g ayr8jw "}));
    assert_eq!(p["code"], "123456");
    assert_eq!(p["secret"], secret);
    assert!(p.get("server").is_none());
    let p = ok(json!({"op": "pair_parse", "input": "123456OOOG4-ORYOM-3OE2O-9184G-AYR8JW".replace("ORYOM", "0R40M")}));
    assert_eq!(p["secret"], secret);
    // 只有 6 位
    let p = ok(json!({"op": "pair_parse", "input": " 654321 "}));
    assert_eq!(p["code"], "654321");
    assert!(p.get("secret").is_none());
    // 错误
    for bad in ["12345", "abcdef", "123456-XYZ", "huijian://pair", "huijian://pair?server=ftp%3A%2F%2Fx&code=123456", "huijian://pair?code=12%ZZ",
        "huijian://pair?server=https%3A%2F%2Fgood.com%40evil.com&code=123456", "huijian://pair?server=https%3A%2F%2Fgo%E2%80%8Bod.com&code=123456",
        "huijian://pair?server=https%3A%2F%2F%E4%BE%8B.com&code=123456"] {
        err(json!({"op": "pair_parse", "input": bad}), "format");
    }
    err(json!({"op": "pair_format", "server": "push.example.com", "code": "123456", "secret": secret}), "bad_request");
    err(json!({"op": "pair_format", "server": "https://x", "code": "12345a", "secret": secret}), "bad_request");
}

#[test]
fn qr_matrix() {
    let link = "huijian://pair?server=https%3A%2F%2Fpush.example.com&code=123456-000G4-0R40M-30E20-9184G-AYR8JW";
    let q = ok(json!({"op": "qr", "text": link}));
    let n = q["size"].as_u64().unwrap() as usize;
    let m = q["modules"].as_str().unwrap();
    assert_eq!(m.len(), n * n);
    assert!(m.bytes().all(|b| b == b'0' || b == b'1'));
    // 左上角定位图形：第一行前 7 格是黑的
    assert_eq!(&m[..7], "1111111");
    assert!(n >= 21 && n <= 57, "版本太大：{n}");
}
