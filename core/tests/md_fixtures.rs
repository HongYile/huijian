// 逐条核对：Rust 解析结果要和服务端（server/testdata/md_fixtures.json）完全一致
use huijian_core::md::{build, to_json, Att};
use serde_json::Value;

#[test]
fn md_fixtures() {
    let raw = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../server/testdata/md_fixtures.json")).unwrap();
    let v: Value = serde_json::from_str(&raw).unwrap();
    let atts: Vec<Att> = v["atts"].as_array().unwrap().iter().map(|a| Att {
        id: a["id"].as_str().unwrap().into(), name: a["name"].as_str().unwrap().into(),
        mime: a["mime"].as_str().unwrap().into(), size: a["size"].as_i64().unwrap(),
    }).collect();
    let only = std::env::var("ONLY").unwrap_or_default();
    let (mut ok, mut bad) = (0, Vec::new());
    for c in v["cases"].as_array().unwrap() {
        let name = c["name"].as_str().unwrap();
        if !only.is_empty() && !name.contains(&only) { continue; }
        let (d, p) = build(c["title"].as_str().unwrap(), c["in"].as_str().unwrap(), &atts);
        let got: Value = serde_json::from_str(&to_json(&d)).unwrap();
        if got == c["doc"] && p == c["preview"].as_str().unwrap() {
            ok += 1;
        } else {
            let g = serde_json::to_string(&got).unwrap();
            let w = serde_json::to_string(&c["doc"]).unwrap();
            let cut = |s: &str| s.chars().take(700).collect::<String>();
            bad.push(format!("❌ {name}\n  期望 {}\n  实际 {}\n  预览期望 {:?}\n  预览实际 {:?}", cut(&w), cut(&g), c["preview"].as_str().unwrap(), p));
        }
    }
    for b in &bad { println!("{b}"); }
    println!("一致 {ok}，不一致 {}", bad.len());
    assert!(bad.is_empty());
}
