// 病态输入（服务端 TestMDLimits 同一组）：每条都要在 300ms 内解析完；附件引用放大要退回纯文本
use huijian_core::md::{build, parse, to_json, Att};
use std::time::Instant;

#[test]
fn md_limits() {
    let evil = [
        ("提示框标题递归", "> [!NOTE] ".repeat(6500)),
        ("深层强调", "*a ".repeat(10000) + "x" + &" a*".repeat(10000)),
        ("深层下划线强调", "_a ".repeat(10000) + "x" + &" a_".repeat(10000)),
        ("深层引用", ">".repeat(65000)),
        ("深层列表", "- ".repeat(30000) + "x"),
        ("大量链接", "[a](https://b) ".repeat(20000)),
        ("大量反引号", "`".repeat(50000)),
        ("大量方括号", "[".repeat(50000) + &"]".repeat(50000)),
        ("超长表格", "| a | b |\n|---|---|\n".to_string() + &"| 1 | 2 |\n".repeat(20000)),
    ];
    for (name, src) in evil {
        let t = Instant::now();
        parse(&src, &[]);
        let ms = t.elapsed().as_millis();
        println!("{name}：{ms} ms");
        assert!(ms < 300, "{name} 用了 {ms} ms");
    }
    let att = vec![Att { id: format!("a_{}", "x".repeat(60)), name: format!("{}.png", "长".repeat(60)), mime: "image/png".into(), size: 0 }];
    let (d, _) = build("", &"![](attachment:1)".repeat(3800), &att);
    assert!(to_json(&d).len() <= 256 << 10, "doc 体积应受限");
    let d = parse(&"- **a** `b` [c](https://d)\n".repeat(6000), &[]);
    assert_eq!(d.blocks.as_ref().unwrap().len(), 1);
}
