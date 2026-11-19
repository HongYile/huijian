//! 回笺 Markdown → doc（和服务端 server/md.go 输出一致，用 server/testdata/md_fixtures.json 逐条核对）。
//! 解析器用 comrak（cmark-gfm 的 Rust 实现）；服务端 md.go 里的正则在这里手写匹配，不引入 regex 库。
use comrak::nodes::{ListType, Node, NodeValue, TableAlignment};
use comrak::{parse_document, Arena, Options};
use serde::{Deserialize, Serialize, Serializer};
use std::collections::HashMap;
use unicode_properties::{GeneralCategoryGroup, UnicodeGeneralCategory};

const MD_VERSION: i64 = 1;
const MAX_NODES: usize = 20000;
const MAX_DEPTH: usize = 12;
const MAX_INLINE_DEPTH: usize = 24;
const MAX_QUOTE_MARKS: usize = 16;
const MAX_INDENT: usize = 64;
const DOC_MAX_BYTES: usize = 256 << 10;

fn no(b: &bool) -> bool {
    !*b
}
fn zero(n: &i64) -> bool {
    *n == 0
}

#[derive(Serialize, Clone, Default, Debug, PartialEq)]
pub struct Run {
    pub text: String,
    #[serde(skip_serializing_if = "no")]
    pub b: bool,
    #[serde(skip_serializing_if = "no")]
    pub i: bool,
    #[serde(skip_serializing_if = "no")]
    pub s: bool,
    #[serde(skip_serializing_if = "no")]
    pub code: bool,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub href: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub att: String,
    #[serde(rename = "fn", skip_serializing_if = "zero")]
    pub fn_: i64,
}

#[derive(Serialize, Clone, Default, Debug)]
pub struct Item {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub check: Option<bool>,
    #[serde(skip_serializing_if = "zero")]
    pub n: i64,
    pub blocks: Option<Vec<Block>>, // None → null（和服务端一致）
}

// 表格单元格：没有内容时输出 null（和服务端一致）
fn cells<S: Serializer>(v: &Vec<Vec<Run>>, s: S) -> Result<S::Ok, S::Error> {
    let x: Vec<Option<&Vec<Run>>> = v.iter().map(|c| if c.is_empty() { None } else { Some(c) }).collect();
    x.serialize(s)
}
fn rows<S: Serializer>(v: &Vec<Vec<Vec<Run>>>, s: S) -> Result<S::Ok, S::Error> {
    let x: Vec<Vec<Option<&Vec<Run>>>> =
        v.iter().map(|r| r.iter().map(|c| if c.is_empty() { None } else { Some(c) }).collect()).collect();
    x.serialize(s)
}

// 数字写法和服务端一致：整数不带 .0
fn num<S: Serializer>(v: &Option<f64>, s: S) -> Result<S::Ok, S::Error> {
    match v {
        Some(x) if x.fract() == 0.0 && x.abs() < 1e15 => s.serialize_i64(*x as i64),
        Some(x) => s.serialize_f64(*x),
        None => s.serialize_none(),
    }
}

#[derive(Serialize, Clone, Default, Debug)]
pub struct Block {
    #[serde(rename = "type")]
    pub kind_: String,
    #[serde(skip_serializing_if = "zero")]
    pub level: i64,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub runs: Vec<Run>,
    #[serde(skip_serializing_if = "no")]
    pub ordered: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start: Option<i64>,
    #[serde(skip_serializing_if = "no")]
    pub tight: bool,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub items: Vec<Item>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub blocks: Vec<Block>,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub kind: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub title: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub fold: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub lang: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub text: String,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub align: Vec<String>,
    #[serde(skip_serializing_if = "Vec::is_empty", serialize_with = "cells")]
    pub head: Vec<Vec<Run>>,
    #[serde(skip_serializing_if = "Vec::is_empty", serialize_with = "rows")]
    pub rows: Vec<Vec<Vec<Run>>>,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub att: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub src: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub alt: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub name: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub mime: String,
    #[serde(skip_serializing_if = "zero")]
    pub size: i64,
    #[serde(skip_serializing_if = "Option::is_none", serialize_with = "num")]
    pub value: Option<f64>,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub label: String,
}

impl Block {
    fn new(t: &str) -> Block {
        Block { kind_: t.into(), ..Default::default() }
    }
    fn para(runs: Vec<Run>) -> Block {
        Block { kind_: "paragraph".into(), runs, ..Default::default() }
    }
}

#[derive(Serialize, Clone, Debug)]
pub struct Doc {
    pub v: i64,
    pub blocks: Option<Vec<Block>>,
}

#[derive(Deserialize, Clone, Default, Debug)]
pub struct Att {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub mime: String,
    #[serde(default)]
    pub size: i64,
}

fn plain_doc(s: &str) -> Doc {
    Doc { v: MD_VERSION, blocks: Some(vec![Block::para(vec![Run { text: s.into(), ..Default::default() }])]) }
}

/// 解析前粗查嵌套深度（和服务端 tooNested 逐字节一致）
fn too_nested(s: &str) -> bool {
    for line in s.split('\n') {
        let l = line.as_bytes();
        let (mut marks, mut indent, mut i) = (0usize, 0usize, 0usize);
        while i < l.len() {
            let ch = l[i];
            if ch == b'>' {
                marks += 1;
            } else if ch == b' ' {
                indent += 1;
            } else if ch == b'\t' {
                indent += 4;
            } else if (ch == b'-' || ch == b'*' || ch == b'+') && i + 1 < l.len() && (l[i + 1] == b' ' || l[i + 1] == b'\t') {
                marks += 1;
            } else if ch.is_ascii_digit() {
                let mut j = i;
                while j < l.len() && j - i < 9 && l[j].is_ascii_digit() {
                    j += 1;
                }
                if j + 1 < l.len() && (l[j] == b'.' || l[j] == b')') && l[j + 1] == b' ' {
                    marks += 1;
                    i = j;
                    continue;
                }
                break;
            } else {
                break;
            }
            i += 1;
        }
        if marks > MAX_QUOTE_MARKS || indent > MAX_INDENT {
            return true;
        }
    }
    false
}

#[derive(Clone)]
enum INode {
    Text(Run),
    Block(Block), // image / file / progress / paragraph（找不到附件的提示）
}

#[derive(Clone, Default)]
struct Style {
    b: bool,
    i: bool,
    s: bool,
    href: String,
    att: String,
}

struct Conv<'a> {
    atts: &'a [Att],
    nodes: usize,
    fn_ix: HashMap<String, i64>,
}

pub fn parse(desp: &str, atts: &[Att]) -> Doc {
    let desp = desp.replace('\0', "\u{FFFD}");
    if too_nested(&desp) {
        return plain_doc(&desp);
    }
    let arena = Arena::new();
    let mut o = Options::default();
    o.extension.table = true;
    o.extension.strikethrough = true;
    o.extension.autolink = true;
    o.extension.tasklist = true;
    o.extension.footnotes = true;
    let root = parse_document(&arena, &desp, &o);
    let mut c = Conv { atts, nodes: 0, fn_ix: HashMap::new() };
    for n in root.descendants() {
        if let NodeValue::FootnoteReference(r) = &n.data().value {
            c.fn_ix.entry(r.name.clone()).or_insert(r.ix as i64);
        }
    }
    let blocks = c.blocks(root, 0);
    if c.nodes > MAX_NODES {
        return plain_doc(&desp);
    }
    Doc { v: MD_VERSION, blocks }
}

fn some(v: Vec<Block>) -> Option<Vec<Block>> {
    if v.is_empty() {
        None
    } else {
        Some(v)
    }
}

impl<'a> Conv<'a> {
    fn blocks<'b>(&mut self, parent: Node<'b>, depth: usize) -> Option<Vec<Block>> {
        let mut out = Vec::new();
        let mut notes: Vec<Item> = Vec::new();
        for n in parent.children() {
            let is_def = matches!(n.data().value, NodeValue::FootnoteDefinition(_));
            if is_def {
                let (name, refs) = match &n.data().value {
                    NodeValue::FootnoteDefinition(d) => (d.name.clone(), d.total_references),
                    _ => unreachable!(),
                };
                if refs == 0 {
                    continue;
                }
                if notes.is_empty() {
                    self.nodes += 1; // 服务端的 FootnoteList 节点
                }
                let ix = *self.fn_ix.get(&name).unwrap_or(&0);
                notes.push(Item { n: ix, blocks: self.blocks(n, depth + 1), ..Default::default() });
                continue;
            }
            if !notes.is_empty() {
                notes.sort_by_key(|x| x.n);
                out.push(Block { kind_: "footnotes".into(), items: std::mem::take(&mut notes), ..Default::default() });
            }
            out.extend(self.block(n, depth));
        }
        if !notes.is_empty() {
            notes.sort_by_key(|x| x.n);
            out.push(Block { kind_: "footnotes".into(), items: notes, ..Default::default() });
        }
        some(out)
    }

    fn block<'b>(&mut self, n: Node<'b>, depth: usize) -> Vec<Block> {
        self.nodes += 1;
        if self.nodes > MAX_NODES {
            return vec![];
        }
        if depth > MAX_DEPTH {
            return vec![Block::para(vec![Run { text: plain_of(n), ..Default::default() }])];
        }
        let v = n.data().value.clone();
        match v {
            NodeValue::Heading(h) => vec![Block { kind_: "heading".into(), level: h.level as i64, runs: flatten(self.inl(n, false)), ..Default::default() }],
            NodeValue::Paragraph => split_paragraph(self.inl(n, true)),
            NodeValue::ThematicBreak(_) => vec![Block::new("rule")],
            NodeValue::CodeBlock(cb) => {
                let mut b = Block::new("code");
                if cb.fenced {
                    let info = cb.info.as_str();
                    let lang = match info.find(' ') {
                        Some(i) => &info[..i],
                        None => info,
                    };
                    b.lang = lang.trim().into();
                }
                b.text = cb.literal.trim_end_matches('\n').into();
                vec![b]
            }
            NodeValue::HtmlBlock(h) => vec![Block::para(vec![Run { text: h.literal.trim_end_matches('\n').into(), ..Default::default() }])],
            NodeValue::BlockQuote => {
                if let Some(b) = self.callout(n, depth) {
                    return vec![b];
                }
                vec![Block { kind_: "quote".into(), blocks: self.blocks(n, depth + 1).unwrap_or_default(), ..Default::default() }]
            }
            NodeValue::List(l) => {
                let mut b = Block::new("list");
                b.ordered = l.list_type == ListType::Ordered;
                b.tight = l.tight;
                if b.ordered {
                    b.start = Some(l.start as i64);
                }
                for it in n.children() {
                    let check = match &it.data().value {
                        NodeValue::TaskItem(t) => Some(t.symbol.is_some()),
                        _ => None,
                    };
                    let mut blocks = self.blocks(it, depth + 1);
                    if check.is_some() && blocks.is_none() {
                        blocks = Some(vec![]);
                    }
                    b.items.push(Item { check, blocks, ..Default::default() });
                }
                vec![b]
            }
            NodeValue::Table(t) => {
                let mut b = Block::new("table");
                for a in &t.alignments {
                    b.align.push(match a {
                        TableAlignment::Left => "left",
                        TableAlignment::Center => "center",
                        TableAlignment::Right => "right",
                        _ => "",
                    }.into());
                }
                for row in n.children() {
                    let head = matches!(&row.data().value, NodeValue::TableRow(r) if r.header);
                    let mut cs = Vec::new();
                    for cell in row.children() {
                        self.nodes += 1;
                        cs.push(flatten(self.inl(cell, false)));
                    }
                    if head {
                        b.head = cs;
                    } else {
                        b.rows.push(cs);
                    }
                }
                vec![b]
            }
            _ => {
                if n.first_child().is_some() {
                    self.blocks(n, depth + 1).unwrap_or_default()
                } else {
                    vec![]
                }
            }
        }
    }

    // ---------- 提示框 ----------
    fn callout<'b>(&mut self, q: Node<'b>, depth: usize) -> Option<Block> {
        let p = q.first_child()?;
        if !matches!(p.data().value, NodeValue::Paragraph) {
            return None;
        }
        let nodes = self.inl(p, true);
        let (first, rest) = split_first_line(&nodes);
        let (kind, fold) = callout_head(first.trim())?;
        let title = strip_callout_prefix(&first).trim().to_string();
        let mut b = Block { kind_: "callout".into(), kind: kind.into(), title, fold: fold.into(), ..Default::default() };
        if !rest.is_empty() {
            b.blocks.extend(split_paragraph(rest));
        }
        let mut n = p.next_sibling();
        while let Some(x) = n {
            b.blocks.extend(self.block(x, depth + 1));
            n = x.next_sibling();
        }
        Some(b)
    }

    // ---------- 行内 ----------
    fn inl<'b>(&mut self, parent: Node<'b>, allow_blocks: bool) -> Vec<INode> {
        let mut out = Vec::new();
        self.inlines(parent, &Style::default(), allow_blocks, 0, &mut out);
        out
    }

    fn inlines<'b>(&mut self, parent: Node<'b>, st: &Style, allow_blocks: bool, depth: usize, out: &mut Vec<INode>) {
        fn add(out: &mut Vec<INode>, t: &str, s: &Style, code: bool) {
            if t.is_empty() {
                return;
            }
            out.push(INode::Text(Run { text: t.into(), b: s.b, i: s.i, s: s.s, code, href: s.href.clone(), att: s.att.clone(), fn_: 0 }));
        }
        for n in parent.children() {
            let v = n.data().value.clone();
            if !matches!(v, NodeValue::SoftBreak | NodeValue::LineBreak) {
                self.nodes += 1; // 服务端的换行是文字节点上的标记，不单独计数
            }
            if self.nodes > MAX_NODES {
                return;
            }
            if depth > MAX_INLINE_DEPTH && n.first_child().is_some() {
                add(out, &plain_of(n), st, false);
                continue;
            }
            match v {
                NodeValue::Text(t) => add(out, &t, st, false),
                NodeValue::SoftBreak | NodeValue::LineBreak => add(out, "\n", st, false),
                NodeValue::Code(c) => add(out, &c.literal, st, true),
                NodeValue::Emph(_) => {
                    let s = Style { i: true, ..st.clone() };
                    self.inlines(n, &s, allow_blocks, depth + 1, out);
                }
                NodeValue::Strong(_) => {
                    let s = Style { b: true, ..st.clone() };
                    self.inlines(n, &s, allow_blocks, depth + 1, out);
                }
                NodeValue::Strikethrough(_) => {
                    let s = Style { s: true, ..st.clone() };
                    self.inlines(n, &s, allow_blocks, depth + 1, out);
                }
                NodeValue::Link(l) if auto_link_text(n, &l.url).map_or(false, |t| !t.is_ascii()) => {
                    // 自动识别的网址把紧贴的中文标点也吞进去了（服务端只认 ASCII）：截到第一个非 ASCII 字符，后面按文字
                    let text = auto_link_text(n, &l.url).unwrap();
                    let cut = text.find(|c: char| !c.is_ascii()).unwrap_or(text.len());
                    let (head, tail) = text.split_at(cut);
                    let url = l.url[..l.url.len() - text.len() + cut].to_string();
                    let mut s = st.clone();
                    let (href, att) = self.link_target(&url);
                    if !href.is_empty() || !att.is_empty() {
                        s.href = href;
                        s.att = att;
                    }
                    add(out, head, &s, false);
                    add(out, tail, st, false);
                }
                NodeValue::Link(l) => {
                    let mut s = st.clone();
                    let (href, att) = self.link_target(&l.url);
                    if !href.is_empty() || !att.is_empty() {
                        s.href = href;
                        s.att = att;
                    }
                    self.inlines(n, &s, allow_blocks, depth + 1, out);
                }
                NodeValue::Image(l) => {
                    let alt = plain_of(n);
                    match self.image_block(&l.url, &alt) {
                        Some(b) if allow_blocks => out.push(INode::Block(b)),
                        Some(b) if b.kind_ == "progress" => add(out, &progress_text(&b), st, false),
                        Some(b) => {
                            let mut s = st.clone();
                            if !b.att.is_empty() {
                                s.att = b.att.clone();
                            }
                            let label = first_non_empty(&[&alt, &b.name, "图片"]);
                            add(out, &format!("🖼 {label}"), &s, false);
                        }
                        None => add(out, &alt, st, false),
                    }
                }
                NodeValue::HtmlInline(h) => {
                    if is_br(&h) {
                        add(out, "\n", st, false)
                    } else {
                        add(out, &h, st, false)
                    }
                }
                NodeValue::FootnoteReference(r) => {
                    let ix = r.ix as i64;
                    out.push(INode::Text(Run { text: ix.to_string(), fn_: ix, ..Default::default() }));
                }
                _ => self.inlines(n, st, allow_blocks, depth + 1, out),
            }
        }
    }

    /// 只放行 http / https / mailto / huijian://message/；attachment: 解析成附件 id
    fn link_target(&self, dest: &str) -> (String, String) {
        let dest = dest.trim();
        let lower = dest.to_lowercase();
        if lower.starts_with("attachment:") {
            return match self.find_att(&dest["attachment:".len()..]) {
                Some(a) => (String::new(), a.id.clone()),
                None => (String::new(), String::new()),
            };
        }
        if lower.starts_with("http://") || lower.starts_with("https://") || lower.starts_with("mailto:") || is_msg_link(dest) {
            return (dest.into(), String::new());
        }
        // 改名前的 hongyan://message/<id> 统一成新 scheme
        if let Some(rest) = dest.strip_prefix("hongyan://") {
            let n = format!("huijian://{rest}");
            if is_msg_link(&n) {
                return (n, String::new());
            }
        }
        (String::new(), String::new())
    }

    fn find_att(&self, r: &str) -> Option<&Att> {
        let r = path_unescape(r).unwrap_or_else(|| r.to_string());
        let r = r.trim();
        if let Some(a) = self.atts.iter().find(|a| a.name == r) {
            return Some(a);
        }
        if let Some(a) = self.atts.iter().find(|a| eq_fold(&a.name, r)) {
            return Some(a);
        }
        match r.parse::<i64>() {
            Ok(n) if n >= 1 && n as usize <= self.atts.len() => Some(&self.atts[n as usize - 1]),
            _ => None,
        }
    }

    fn image_block(&self, dest: &str, alt: &str) -> Option<Block> {
        let dest = dest.trim();
        let lower = dest.to_lowercase();
        if lower.starts_with("attachment:") {
            let r = &dest["attachment:".len()..];
            return Some(match self.find_att(r) {
                None => Block::para(vec![Run { text: format!("（找不到附件 {r}）"), i: true, ..Default::default() }]),
                Some(a) => Block {
                    kind_: if a.mime.starts_with("image/") { "image" } else { "file" }.into(),
                    att: a.id.clone(),
                    alt: alt.into(),
                    name: a.name.clone(),
                    mime: a.mime.clone(),
                    size: a.size,
                    ..Default::default()
                },
            });
        }
        if lower.starts_with("progress:") {
            return progress(&dest["progress:".len()..], alt);
        }
        if lower.starts_with("http://") || lower.starts_with("https://") {
            return Some(Block { kind_: "image".into(), src: dest.into(), alt: alt.into(), ..Default::default() });
        }
        None
    }
}

/// 自动识别的链接（裸网址、www.、邮箱）：只有一个文字子节点，并且网址就是文字本身（或加了 http:// / mailto:）
fn auto_link_text<'b>(n: Node<'b>, url: &str) -> Option<String> {
    let c = n.first_child()?;
    if c.next_sibling().is_some() {
        return None;
    }
    let NodeValue::Text(t) = &c.data().value else { return None };
    let t = t.to_string();
    if url == t || url == format!("http://{t}") || url == format!("mailto:{t}") {
        Some(t)
    } else {
        None
    }
}

fn plain_of<'b>(n: Node<'b>) -> String {
    let mut s = String::new();
    for d in n.descendants() {
        match &d.data().value {
            NodeValue::Text(t) => s.push_str(t),
            NodeValue::Code(c) => s.push_str(&c.literal),
            NodeValue::SoftBreak | NodeValue::LineBreak => s.push('\n'),
            _ => {}
        }
    }
    if s.is_empty() {
        match &n.data().value {
            NodeValue::CodeBlock(cb) => return cb.literal.trim_end_matches('\n').into(),
            NodeValue::HtmlBlock(h) => return h.literal.trim_end_matches('\n').into(),
            _ => {}
        }
    }
    s
}

fn is_ws(c: u8) -> bool {
    matches!(c, b' ' | b'\t' | b'\n' | b'\r' | b'\x0c')
}

/// `^<br\s*/?>$`，不分大小写
fn is_br(h: &str) -> bool {
    let b = h.as_bytes();
    if b.len() < 4 || !b[..3].eq_ignore_ascii_case(b"<br") || b[b.len() - 1] != b'>' {
        return false;
    }
    let mut i = 3;
    while i < b.len() - 1 && is_ws(b[i]) {
        i += 1;
    }
    if i < b.len() - 1 && b[i] == b'/' {
        i += 1;
    }
    i == b.len() - 1
}

/// `^huijian://message/[0-9]{1,18}$`
fn is_msg_link(s: &str) -> bool {
    match s.strip_prefix("huijian://message/") {
        Some(d) => !d.is_empty() && d.len() <= 18 && d.bytes().all(|c| c.is_ascii_digit()),
        None => false,
    }
}

/// Go url.PathUnescape：%XX 解码，格式不对返回 None
fn path_unescape(s: &str) -> Option<String> {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' {
            let h = |c: u8| (c as char).to_digit(16);
            if i + 2 >= b.len() + 0 && i + 2 > b.len() - 1 + 1 {
                return None;
            }
            let (x, y) = (h(*b.get(i + 1)?)?, h(*b.get(i + 2)?)?);
            out.push((x * 16 + y) as u8);
            i += 3;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    Some(String::from_utf8_lossy(&out).into_owned())
}

fn eq_fold(a: &str, b: &str) -> bool {
    a.chars().flat_map(char::to_lowercase).eq(b.chars().flat_map(char::to_lowercase))
}

fn first_non_empty<'s>(xs: &[&'s str]) -> &'s str {
    xs.iter().find(|x| !x.is_empty()).copied().unwrap_or("")
}

/// 进度：`^\s*([0-9]*\.?[0-9]+)\s*(%|/\s*([0-9]*\.?[0-9]+))?\s*$`
fn progress(s: &str, alt: &str) -> Option<Block> {
    let b = s.as_bytes();
    let mut i = 0;
    let skip = |i: &mut usize| {
        while *i < b.len() && is_ws(b[*i]) {
            *i += 1;
        }
    };
    let num = |i: &mut usize| -> Option<String> {
        let st = *i;
        while *i < b.len() && b[*i].is_ascii_digit() {
            *i += 1;
        }
        if *i + 1 < b.len() && b[*i] == b'.' && b[*i + 1].is_ascii_digit() {
            *i += 1;
            while *i < b.len() && b[*i].is_ascii_digit() {
                *i += 1;
            }
        }
        if *i == st {
            None
        } else {
            Some(s[st..*i].to_string())
        }
    };
    skip(&mut i);
    let m1 = num(&mut i)?;
    skip(&mut i);
    let (mut pct, mut m3) = (false, String::new());
    if i < b.len() && b[i] == b'%' {
        pct = true;
        i += 1;
    } else if i < b.len() && b[i] == b'/' {
        i += 1;
        skip(&mut i);
        m3 = num(&mut i)?;
    }
    skip(&mut i);
    if i != b.len() {
        return None;
    }
    let x: f64 = m1.parse().ok()?;
    let mut txt = String::new();
    let v = if pct {
        x / 100.0
    } else if !m3.is_empty() {
        let total: f64 = m3.parse().ok()?;
        txt = format!("{m1}/{m3}");
        if total > 0.0 {
            x / total
        } else {
            0.0
        }
    } else if x > 1.0 {
        x / 100.0
    } else {
        x
    };
    if v.is_nan() || v.is_infinite() {
        return None;
    }
    let v = v.clamp(0.0, 1.0);
    Some(Block { kind_: "progress".into(), value: Some(v), label: alt.into(), text: txt, ..Default::default() })
}

fn progress_text(b: &Block) -> String {
    let mut s = format!("{:.0}%", b.value.unwrap_or(0.0) * 100.0);
    if !b.text.is_empty() {
        s += &format!("（{}）", b.text);
    }
    if !b.label.is_empty() {
        s = format!("{} {}", b.label, s);
    }
    s
}

const CALLOUT_KINDS: &[(&str, &str)] = &[
    ("note", "note"), ("info", "note"), ("tip", "tip"), ("hint", "tip"), ("important", "important"),
    ("warning", "warning"), ("warn", "warning"), ("attention", "warning"), ("caution", "caution"), ("danger", "caution"),
    ("error", "failure"), ("failure", "failure"), ("fail", "failure"), ("bug", "failure"),
    ("success", "success"), ("done", "success"), ("check", "success"),
];

/// `^\[!([A-Za-z]+)\]([+-]?)[ \t]*(.*)$` → (类型, 折叠)
fn callout_head(s: &str) -> Option<(&'static str, &'static str)> {
    let r = s.strip_prefix("[!")?;
    let end = r.find(']')?;
    let name = &r[..end];
    if name.is_empty() || !name.bytes().all(|c| c.is_ascii_alphabetic()) {
        return None;
    }
    if r[end + 1..].contains('\n') {
        return None;
    }
    let kind = CALLOUT_KINDS.iter().find(|(k, _)| k.eq_ignore_ascii_case(name))?.1;
    let fold = match r[end + 1..].as_bytes().first() {
        Some(b'-') => "closed",
        Some(b'+') => "open",
        _ => "",
    };
    Some((kind, fold))
}

/// 去掉 `^\s*\[![A-Za-z]+\][+-]?`
fn strip_callout_prefix(s: &str) -> &str {
    let t = s.trim_start();
    if let Some(r) = t.strip_prefix("[!") {
        let n = r.bytes().take_while(|c| c.is_ascii_alphabetic()).count();
        if n > 0 && r.as_bytes().get(n) == Some(&b']') {
            let mut rest = &r[n + 1..];
            if rest.starts_with('+') || rest.starts_with('-') {
                rest = &rest[1..];
            }
            return rest;
        }
    }
    s
}

fn split_first_line(nodes: &[INode]) -> (String, Vec<INode>) {
    let mut first = String::new();
    for (i, n) in nodes.iter().enumerate() {
        if let INode::Text(r) = n {
            if let Some(j) = r.text.find('\n') {
                first.push_str(&r.text[..j]);
                let mut rest = nodes[i..].to_vec();
                if let INode::Text(r0) = &mut rest[0] {
                    r0.text = r0.text[j + 1..].to_string();
                }
                return (first, rest);
            }
            first.push_str(&r.text);
        }
    }
    (first, vec![])
}

fn split_paragraph(nodes: Vec<INode>) -> Vec<Block> {
    let mut out = Vec::new();
    let mut cur: Vec<INode> = Vec::new();
    let flush = |cur: &mut Vec<INode>, out: &mut Vec<Block>| {
        let mut runs = flatten(std::mem::take(cur));
        while !runs.is_empty() && runs[0].text.trim().is_empty() && runs[0].fn_ == 0 {
            runs.remove(0);
        }
        while !runs.is_empty() && runs[runs.len() - 1].text.trim().is_empty() {
            runs.pop();
        }
        if !runs.is_empty() {
            runs[0].text = runs[0].text.trim_start_matches('\n').into();
            let k = runs.len() - 1;
            runs[k].text = runs[k].text.trim_end_matches('\n').into();
            out.push(Block::para(runs));
        }
    };
    for n in nodes {
        match n {
            INode::Block(b) => {
                flush(&mut cur, &mut out);
                out.push(b);
            }
            t => cur.push(t),
        }
    }
    flush(&mut cur, &mut out);
    out
}

fn same_style(a: &Run, b: &Run) -> bool {
    a.b == b.b && a.i == b.i && a.s == b.s && a.code == b.code && a.href == b.href && a.att == b.att
}

fn is_punct_or_symbol(c: char) -> bool {
    matches!(c.general_category_group(), GeneralCategoryGroup::Punctuation | GeneralCategoryGroup::Symbol)
}

fn edge_punct(s: &str) -> bool {
    match (s.chars().next(), s.chars().last()) {
        (Some(f), Some(l)) => is_punct_or_symbol(f) || is_punct_or_symbol(l),
        _ => false,
    }
}

/// `\*\*([^*\n]+?)\*\*|~~([^~\n]+?)~~` 的全部不重叠匹配：(起, 止, 内容起, 内容止, 是否加粗)
fn cjk_bold_matches(s: &str) -> Vec<(usize, usize, usize, usize, bool)> {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i + 1 < b.len() {
        let mut hit = None;
        for (mark, bold) in [(b'*', true), (b'~', false)] {
            if b[i] == mark && b[i + 1] == mark {
                let j = i + 2;
                let mut k = j;
                while k < b.len() && b[k] != mark && b[k] != b'\n' {
                    k += 1;
                }
                if k > j && k + 1 < b.len() && b[k] == mark && b[k + 1] == mark {
                    hit = Some((i, k + 2, j, k, bold));
                    break;
                }
            }
        }
        match hit {
            Some(m) => {
                out.push(m);
                i = m.1;
            }
            None => i += 1,
        }
    }
    out
}

/// 合并相邻同样式文字，补上 CommonMark 不认的中文加粗，再补识别紧贴中文标点的网址
fn flatten(nodes: Vec<INode>) -> Vec<Run> {
    let mut out: Vec<Run> = Vec::new();
    for n in nodes {
        let INode::Text(r) = n else { continue };
        if r.text.is_empty() {
            continue;
        }
        if let Some(k) = out.last_mut() {
            if r.fn_ == 0 && k.fn_ == 0 && same_style(k, &r) {
                k.text.push_str(&r.text);
                continue;
            }
        }
        out.push(r);
    }
    let mut fixed = Vec::new();
    for r in out {
        if r.code || r.fn_ != 0 || !(r.text.contains('*') || r.text.contains('~')) {
            fixed.push(r);
            continue;
        }
        let mut last = 0;
        for (m0, m1, a, z, bold) in cjk_bold_matches(&r.text) {
            if !edge_punct(&r.text[a..z]) {
                continue;
            }
            if m0 > last {
                fixed.push(Run { text: r.text[last..m0].into(), ..r.clone() });
            }
            let mut x = Run { text: r.text[a..z].into(), ..r.clone() };
            if bold {
                x.b = true;
            } else {
                x.s = true;
            }
            fixed.push(x);
            last = m1;
        }
        if last < r.text.len() {
            fixed.push(Run { text: r.text[last..].into(), ..r.clone() });
        }
    }
    linkify_runs(fixed)
}

fn url_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || b"-._~:/?#[]@!$&'*+,;=%".contains(&c)
}

fn linkify_runs(input: Vec<Run>) -> Vec<Run> {
    let mut out = Vec::new();
    for r in input {
        if r.code || !r.href.is_empty() || !r.att.is_empty() || r.fn_ != 0 || !r.text.contains("://") {
            out.push(r);
            continue;
        }
        let b = r.text.as_bytes();
        let (mut last, mut i) = (0, 0);
        while i < b.len() {
            let pre = if b[i..].starts_with(b"https://") {
                8
            } else if b[i..].starts_with(b"http://") {
                7
            } else {
                i += 1;
                continue;
            };
            let mut e = i + pre;
            while e < b.len() && url_char(b[e]) {
                e += 1;
            }
            if e == i + pre {
                i += 1;
                continue;
            }
            let full_end = e;
            while e > i && b".,;:!?'".contains(&b[e - 1]) {
                e -= 1;
            }
            if i > last {
                out.push(Run { text: r.text[last..i].into(), ..r.clone() });
            }
            out.push(Run { text: r.text[i..e].into(), href: r.text[i..e].into(), ..r.clone() });
            last = e;
            i = full_end.max(i + 1);
        }
        if last < r.text.len() {
            out.push(Run { text: r.text[last..].into(), ..r.clone() });
        }
    }
    out
}

// ---------- 纯文本（通知正文、列表预览） ----------

const CALLOUT_NAMES: &[(&str, &str)] = &[("note", "说明"), ("tip", "建议"), ("important", "重要"), ("warning", "警告"), ("caution", "危险"), ("success", "成功"), ("failure", "失败")];
const CALLOUT_ICONS: &[(&str, &str)] = &[("note", "ℹ️"), ("tip", "💡"), ("important", "❗"), ("warning", "⚠️"), ("caution", "⛔"), ("success", "✅"), ("failure", "❌")];

fn lookup(t: &[(&str, &'static str)], k: &str) -> &'static str {
    t.iter().find(|(x, _)| *x == k).map(|x| x.1).unwrap_or("")
}

fn runs_text(rs: &[Run]) -> String {
    let mut s = String::new();
    for r in rs {
        if r.fn_ != 0 {
            s += &format!("[{}]", r.text);
        } else {
            s += &r.text;
        }
    }
    s
}

pub fn doc_plain(blocks: &[Block]) -> String {
    let mut b = String::new();
    fn line(b: &mut String, s: &str) {
        if !b.is_empty() {
            b.push('\n');
        }
        b.push_str(s);
    }
    fn walk(b: &mut String, bs: &[Block], indent: &str) {
        for x in bs {
            match x.kind_.as_str() {
                "heading" | "paragraph" => line(b, &format!("{indent}{}", runs_text(&x.runs).replace('\n', &format!("\n{indent}")))),
                "list" => {
                    for (i, it) in x.items.iter().enumerate() {
                        let mut mark = "· ".to_string();
                        if x.ordered {
                            mark = format!("{}. ", x.start.unwrap_or(1) + i as i64);
                        }
                        if let Some(c) = it.check {
                            mark = if c { "☑ " } else { "☐ " }.into();
                        }
                        let sub = doc_plain(it.blocks.as_deref().unwrap_or(&[]));
                        line(b, &format!("{indent}{mark}{}", sub.replace('\n', &format!("\n{indent}  "))));
                    }
                }
                "quote" => walk(b, &x.blocks, indent),
                "callout" => {
                    let t = if x.title.is_empty() { lookup(CALLOUT_NAMES, &x.kind).to_string() } else { x.title.clone() };
                    line(b, &format!("{indent}{}", format!("{} {}", lookup(CALLOUT_ICONS, &x.kind), t).trim()));
                    walk(b, &x.blocks, indent);
                }
                "code" => line(b, &format!("{indent}{}", x.text)),
                "table" => {
                    let row = |b: &mut String, cells: &[Vec<Run>]| {
                        let cs: Vec<String> = cells.iter().map(|c| runs_text(c).replace('\n', " ")).collect();
                        line(b, &format!("{indent}{}", cs.join(" · ")));
                    };
                    if !x.head.is_empty() {
                        row(b, &x.head);
                    }
                    for r in &x.rows {
                        row(b, r);
                    }
                }
                "image" => line(b, &format!("{indent}🖼 {}", first_non_empty(&[&x.alt, &x.name, "图片"]))),
                "file" => line(b, &format!("{indent}📎 {}", first_non_empty(&[&x.alt, &x.name]))),
                "progress" => line(b, &format!("{indent}{}", progress_text(x))),
                "footnotes" => {
                    for it in &x.items {
                        line(b, &format!("{indent}[{}] {}", it.n, doc_plain(it.blocks.as_deref().unwrap_or(&[]))));
                    }
                }
                _ => {}
            }
        }
    }
    walk(&mut b, blocks, "");
    b.trim().to_string()
}

fn clip(s: &str, n: usize) -> String {
    if s.chars().count() > n {
        s.chars().take(n).collect::<String>() + "…"
    } else {
        s.to_string()
    }
}

pub fn to_json(d: &Doc) -> String {
    serde_json::to_string(d).unwrap_or_default()
}

/// 消息的 doc 和预览（和服务端 buildDoc 一致）：doc 过大退回纯文本；预览跳过和标题相同的开头标题
pub fn build(title: &str, desp: &str, atts: &[Att]) -> (Doc, String) {
    let mut d = parse(desp, atts);
    if to_json(&d).len() > DOC_MAX_BYTES && to_json(&d).len() > 4 * desp.len() {
        d = plain_doc(desp);
    }
    let blocks = d.blocks.clone().unwrap_or_default();
    let pv: &[Block] = if blocks.len() > 1 && blocks[0].kind_ == "heading" && doc_plain(&blocks[..1]).trim() == title.trim() {
        &blocks[1..]
    } else {
        &blocks
    };
    let preview = clip(&doc_plain(pv), 200);
    (d, preview)
}

/// 给 C 接口用：输入 {"text","desp","atts":[{id,name,mime,size}]}，输出 {"doc":…, "preview":…}
pub fn build_json(input: &str) -> Option<String> {
    #[derive(Deserialize)]
    struct In {
        #[serde(default)]
        text: String,
        #[serde(default)]
        desp: String,
        #[serde(default)]
        atts: Vec<Att>,
    }
    let i: In = serde_json::from_str(input).ok()?;
    let (d, p) = build(&i.text, &i.desp, &i.atts);
    Some(format!("{{\"doc\":{},\"preview\":{}}}", to_json(&d), serde_json::to_string(&p).ok()?))
}
