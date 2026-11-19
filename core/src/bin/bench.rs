// 基准：在目标设备上跑，测 Argon2id、信封解密、附件解密、Markdown 解析的耗时
use huijian_core::{crypto::*, md};
use std::time::Instant;

fn ms(t: Instant) -> f64 {
    t.elapsed().as_secs_f64() * 1000.0
}

fn main() {
    let sk = random32().unwrap();
    let pk = public_key(&sk);

    let t = Instant::now();
    password_keys(b"correct horse battery staple", b"huijian-pw-salt!").unwrap();
    println!("Argon2id（64 MiB、3 轮）：{:.0} ms", ms(t));

    let payload = r#"{"v":1,"text":"exp42 完成","desp":"val_loss **0.198**"}"#.as_bytes();
    let env = seal_message(&pk, payload).unwrap();
    let n = 2000;
    let t = Instant::now();
    for _ in 0..n {
        open_message(&sk, &env).unwrap();
    }
    println!("解一条消息：{:.1} µs", ms(t) * 1000.0 / n as f64);

    let size = 64 << 20;
    let file = vec![0x5au8; size];
    let key = random32().unwrap();
    let mut ct = Vec::with_capacity(size + size / 1000 + 64);
    encrypt_file(&key, &mut file.as_slice(), &mut ct).unwrap();
    let mut out = Vec::with_capacity(size);
    let t = Instant::now();
    decrypt_file(&key, &mut ct.as_slice(), &mut out).unwrap();
    let d = ms(t);
    println!("附件解密 64 MB：{:.0} ms（{:.0} MB/s）", d, 64.0 / (d / 1000.0));

    let src = "# 标题\n\n> [!WARNING] 磁盘 **95%**\n> 清理旧文件\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- [x] 完成\n- [ ] 待办\n\n```\ncode\n```\n".repeat(20);
    let t = Instant::now();
    for _ in 0..200 {
        md::build("", &src, &[]);
    }
    println!("Markdown 解析 {:.1} KB：{:.0} µs", src.len() as f64 / 1024.0, ms(t) * 1000.0 / 200.0);
}
