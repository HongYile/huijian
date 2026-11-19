// 用 RFC 9180 官方向量和回笺跨平台向量（Go 生成）验证：两边逐字节一致
use huijian_core::crypto::*;
use serde_json::Value;

const DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../server/testdata");

fn load(name: &str) -> Value {
    serde_json::from_slice(&std::fs::read(format!("{DIR}/{name}")).unwrap()).unwrap()
}
fn unhex(s: &str) -> Vec<u8> {
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
}
fn arr(v: &Value) -> [u8; 32] {
    unhex(v.as_str().unwrap()).try_into().unwrap()
}

#[test]
fn rfc9180_first_encryption() {
    let v = load("hpke_rfc9180_x25519_sha256_aes256gcm.json");
    let e = &v["encryptions"][0];
    let (enc, ct) = hpke_seal(&arr(&v["pkRm"]), &unhex(v["info"].as_str().unwrap()), &unhex(e["aad"].as_str().unwrap()), &unhex(e["pt"].as_str().unwrap()), Some(arr(&v["skEm"]))).unwrap();
    assert_eq!(hex(&enc), v["enc"].as_str().unwrap());
    assert_eq!(hex(&ct), e["ct"].as_str().unwrap());
    let pt = hpke_open(&arr(&v["skRm"]), &enc, &unhex(v["info"].as_str().unwrap()), &unhex(e["aad"].as_str().unwrap()), &ct).unwrap();
    assert_eq!(hex(&pt), e["pt"].as_str().unwrap());
}

#[test]
fn huijian_vectors() {
    let v = load("e2e_vectors.json");
    let sk = arr(&v["recipient_sk"]);
    assert_eq!(kid(&public_key(&sk)), v["kid"].as_str().unwrap());
    // 消息信封：解开 Go 加密的；用同一个一次性密钥加密得到同样的信封
    let pt = open_message(&sk, v["envelope"].as_str().unwrap()).unwrap();
    assert_eq!(String::from_utf8(pt).unwrap(), v["payload"].as_str().unwrap());
    let k = kid(&public_key(&sk));
    let (enc, ct) = hpke_seal(&public_key(&sk), INFO_MESSAGE, format!("hje1.{k}").as_bytes(), v["payload"].as_str().unwrap().as_bytes(), Some(arr(&v["ephemeral_sk"]))).unwrap();
    use base64::Engine;
    let b64 = base64::engine::general_purpose::URL_SAFE_NO_PAD;
    assert_eq!(format!("hje1.{k}.{}", b64.encode([enc.as_slice(), &ct].concat())), v["envelope"].as_str().unwrap());
    // 换一把钥匙解不开；改一个字节解不开
    assert_eq!(open_message(&[9u8; 32], v["envelope"].as_str().unwrap()), Err(Error::WrongKey));
    let mut bad = v["envelope"].as_str().unwrap().to_string();
    let last = bad.pop().unwrap();
    bad.push(if last == 'A' { 'B' } else { 'A' });
    assert!(open_message(&sk, &bad).is_err());

    // 附件：加密结果和 Go 一致，解密还原
    let file: Vec<u8> = (0..65636usize).map(|i| (i % 251) as u8).collect();
    let key = arr(&v["file_key"]);
    let mut ct = Vec::new();
    encrypt_file(&key, &mut file.as_slice(), &mut ct).unwrap();
    assert_eq!(ct.len() as u64, v["file_ct_len"].as_u64().unwrap());
    use sha2::Digest;
    assert_eq!(hex(&sha2::Sha256::digest(&ct)), v["file_ct_sha256"].as_str().unwrap());
    let mut out = Vec::new();
    decrypt_file(&key, &mut ct.as_slice(), &mut out).unwrap();
    assert_eq!(out, file);
    // 截断（去掉最后一块）、改动都要报错
    assert!(decrypt_file(&key, &mut &ct[..8 + CHUNK + 16], &mut Vec::new()).is_err());
    let mut bad = ct.clone();
    bad[100] ^= 1;
    assert!(decrypt_file(&key, &mut bad.as_slice(), &mut Vec::new()).is_err());
    // 空文件、整块大小的文件
    for n in [0usize, CHUNK, 2 * CHUNK + 1] {
        let f = vec![7u8; n];
        let mut c = Vec::new();
        encrypt_file(&key, &mut f.as_slice(), &mut c).unwrap();
        let mut o = Vec::new();
        decrypt_file(&key, &mut c.as_slice(), &mut o).unwrap();
        assert_eq!(o, f);
    }

    // 恢复码
    let code = unhex(v["recovery_code_bytes"].as_str().unwrap());
    assert_eq!(format_recovery(&code), v["recovery_code"].as_str().unwrap());
    assert_eq!(parse_recovery(&v["recovery_code"].as_str().unwrap().to_lowercase().replace('0', "o")).unwrap(), code);
    assert_eq!(hex(&recovery_key(&code)), v["recovery_key"].as_str().unwrap());
    let nonce: [u8; 12] = unhex(v["wrap_nonce"].as_str().unwrap()).try_into().unwrap();
    assert_eq!(wrap("hjr1", &recovery_key(&code), &sk, Some(nonce)).unwrap(), v["recovery_wrap"].as_str().unwrap());
    assert_eq!(unwrap("hjr1", &recovery_key(&code), v["recovery_wrap"].as_str().unwrap()).unwrap(), sk);
    assert!(unwrap("hjp1", &recovery_key(&code), v["recovery_wrap"].as_str().unwrap()).is_err()); // 前缀不对

    // 密码（Argon2id）
    let (auth, unlock) = password_keys(v["password"].as_str().unwrap().as_bytes(), &unhex(v["password_salt"].as_str().unwrap())).unwrap();
    assert_eq!(hex(&auth), v["password_auth_key"].as_str().unwrap());
    assert_eq!(hex(&unlock), v["password_unlock_key"].as_str().unwrap());
    assert_eq!(unwrap("hjp1", &unlock, v["password_wrap"].as_str().unwrap()).unwrap(), sk);

    // 设备转交
    let dev = arr(&v["device_sk"]);
    let g = b64.decode(v["grant"].as_str().unwrap().strip_prefix("hjg1.").unwrap()).unwrap();
    assert_eq!(hpke_open(&dev, &g[..32].try_into().unwrap(), INFO_GRANT, b"hjg1", &g[32..]).unwrap(), sk);

    // 核对码
    let (na, nb) = (arr(&v["sas_nonce_a"]), arr(&v["sas_nonce_b"]));
    assert_eq!(hex(&sas_commit(&public_key(&dev), &nb)), v["sas_commit"].as_str().unwrap());
    assert_eq!(sas_code(&public_key(&dev), &na, &nb), v["sas_code"].as_str().unwrap());
}
