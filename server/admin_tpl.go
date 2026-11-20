package main

// 管理网页的样式、图标、模板。设计规范见 ../DESIGN.md。
// 注意：本文件是 Go 原始字符串，模板里的 JS 不能用反引号。

const adminCSS = `{{define "css"}}<style>
:root{--bg:#F4F1EA;--sidebar:#EDE9E0;--surface:#FBF9F5;--surface2:#F0ECE4;--border:#E1DBD0;--text:#2B2924;--text2:#6A655C;--text3:#9D978C;
--accent:#4A63B5;--accent-soft:rgba(74,99,181,.11);--ok:#3E8E63;
--p5:#D44C3D;--p4:#DB7B2E;--p3:#3F7FD0;--p2:#958F84;--p1:#B4AEA3;--p0:#C8C2B6;
--shadow:0 1px 2px rgba(60,48,30,.06),0 6px 16px rgba(60,48,30,.05);--r:12px}
@media (prefers-color-scheme:dark){:root{--bg:#1A1917;--sidebar:#151412;--surface:#22201E;--surface2:#2B2926;--border:#35322E;--text:#EBE6DC;
--text2:#ABA497;--text3:#77716A;--accent:#8EA2EC;--accent-soft:rgba(142,162,236,.16);--ok:#5DB585;--shadow:none}}
*{box-sizing:border-box}
html,body{margin:0;background:radial-gradient(1100px 420px at 75% -12%,var(--accent-soft),transparent 65%) fixed,var(--bg);color:var(--text);font:13.5px/1.55 -apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang SC","Hiragino Sans GB","Helvetica Neue",sans-serif;-webkit-font-smoothing:antialiased}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
code,pre,.mono{font-family:ui-monospace,"SF Mono",SFMono-Regular,Menlo,monospace}
svg{display:block}
.app{display:flex;min-height:100vh}
.side{width:224px;flex:none;background:var(--sidebar);border-right:1px solid var(--border);display:flex;flex-direction:column;padding:18px 12px 14px;position:sticky;top:0;height:100vh}
.brand{display:flex;align-items:center;gap:10px;padding:2px 8px 22px;font-weight:650;font-size:15px;letter-spacing:-.01em}
.logo{--lg-bg:#F4F1EA;--lg-env:#4A63B5;--lg-line:#2B2924;--lg-flap:#F4F1EA;--lg-arrow:#4A63B5;--lg-spark:#D44C3D;
width:30px;height:30px;border-radius:8px;overflow:hidden;flex:none;border:1px solid var(--border);box-shadow:0 1px 3px rgba(60,48,30,.12)}
@media (prefers-color-scheme:dark){.logo{--lg-bg:#1A1917;--lg-env:#5B74C9;--lg-line:#EBE6DC;--lg-flap:#1A1917;--lg-arrow:#8EA2EC;--lg-spark:#E06A5A;box-shadow:none}}
.logo svg{width:100%;height:100%}
.brand small{display:block;font-weight:500;font-size:11.5px;color:var(--text3);letter-spacing:0}
.nav a{display:flex;align-items:center;gap:10px;padding:7px 10px;border-radius:7px;color:var(--text2);font-weight:500;margin-bottom:2px;text-decoration:none}
.nav a:hover{background:var(--surface2);color:var(--text)}
.nav a.on{background:var(--surface);color:var(--accent);box-shadow:0 1px 2px rgba(60,48,30,.10)}
@media (prefers-color-scheme:dark){.nav a.on{background:var(--surface2);box-shadow:none}}
.nav svg{width:17px;height:17px;flex:none}
.side .foot{margin-top:auto;padding:10px;border-top:1px solid var(--border);color:var(--text3);font-size:12px;display:flex;flex-direction:column;gap:8px}
.side .foot form{margin:0}
.live{display:flex;align-items:center;gap:7px;color:var(--text2)}
.pulse{width:8px;height:8px;border-radius:50%;background:var(--ok);box-shadow:0 0 0 3px color-mix(in srgb,var(--ok) 20%,transparent)}
.pulse.off{background:var(--text3);box-shadow:none}
.main{flex:1;min-width:0;padding:30px 40px 64px}
.wrap{max-width:1080px;margin:0 auto}
.head{display:flex;align-items:flex-end;justify-content:space-between;gap:16px;margin-bottom:22px;flex-wrap:wrap}
h1{font-size:22px;font-weight:650;margin:0;letter-spacing:-.015em}
.sub{color:var(--text2);margin-top:4px;max-width:640px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:var(--r);box-shadow:var(--shadow);margin-bottom:18px;overflow:hidden}
.card-h{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:13px 18px;border-bottom:1px solid var(--border)}
.card-h h2{font-size:14px;margin:0;font-weight:600}
.card-h .aside{color:var(--text3);font-size:12px}
.card-b{padding:16px 18px}
.grid4{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:14px;margin-bottom:18px}
.grid4 .card{margin:0}
.cols{display:grid;grid-template-columns:minmax(0,2fr) minmax(0,1fr);gap:14px}
.stat{padding:16px 18px 15px}
.stat .k{color:var(--text2);font-size:12.5px;font-weight:500;display:flex;align-items:center;gap:8px}
.stat .ti{width:26px;height:26px;border-radius:7px;display:grid;place-items:center;background:color-mix(in srgb,var(--c) 14%,transparent);color:var(--c)}
.stat .ti svg{width:15px;height:15px}
.stat .v{font-size:28px;font-weight:650;margin-top:6px;letter-spacing:-.02em;font-variant-numeric:tabular-nums;line-height:1.15}
.stat .v small{font-size:15px;color:var(--text3);font-weight:500}
.stat .d{color:var(--text3);font-size:12px;margin-top:4px}
.chart{display:flex;align-items:flex-end;gap:7px;height:132px;padding:4px 2px 0}
.chart .col{flex:1;display:flex;flex-direction:column;align-items:center;justify-content:flex-end;height:100%;gap:6px;min-width:0}
.chart .bar{width:100%;max-width:26px;background:var(--accent);border-radius:4px 4px 2px 2px;min-height:3px;position:relative;opacity:.9}
.chart .bar.zero{background:var(--surface2);opacity:1}
.chart .col:hover .bar{opacity:1}
.chart .n{font-size:10.5px;color:var(--text2);font-variant-numeric:tabular-nums;height:14px}
.chart .lb{font-size:10.5px;color:var(--text3);white-space:nowrap}
.stack{display:flex;height:10px;border-radius:5px;overflow:hidden;background:var(--surface2);gap:2px}
.stack span{display:block;height:100%}
.legend{list-style:none;margin:14px 0 0;padding:0;display:flex;flex-direction:column;gap:8px}
.legend li{display:flex;align-items:center;gap:8px;color:var(--text2)}
.legend b{margin-left:auto;font-weight:600;color:var(--text);font-variant-numeric:tabular-nums}
.dot{width:8px;height:8px;border-radius:50%;display:inline-block;flex:none}
.c5{background:var(--p5)}.c4{background:var(--p4)}.c3{background:var(--p3)}.c2{background:var(--p2)}.c1{background:var(--p1)}.c0{background:var(--p0)}
.msg{display:flex;gap:16px;padding:14px 18px 14px 20px;border-bottom:1px solid var(--border);position:relative}
.msg:last-child{border-bottom:0}
.msg:hover{background:color-mix(in srgb,var(--surface2) 45%,transparent)}
.msg.p5::before,.msg.p4::before{content:"";position:absolute;left:0;top:12px;bottom:12px;width:3px;border-radius:0 3px 3px 0}
.msg.p5::before{background:var(--p5)}.msg.p4::before{background:var(--p4)}
.msg.dim .tt,.msg.dim .desp{color:var(--text2)}
.msg .body{flex:1;min-width:0}
.msg .t{display:flex;align-items:center;gap:8px;min-width:0}
.msg .tt{font-weight:600;font-size:14px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.msg.p5 .tt{color:var(--p5)}
.msg .meta{display:flex;flex-wrap:wrap;gap:6px 10px;align-items:center;color:var(--text3);font-size:12px;margin-top:5px}
.msg .desp{color:var(--text2);white-space:pre-wrap;word-break:break-word;margin-top:7px;font-size:13px}
.msg details.desp summary{cursor:pointer;list-style:none}
.msg details.desp summary::after{content:" 展开";color:var(--accent);font-size:12px}
.msg details.desp[open] summary{display:none}
.msg .desp.md{white-space:normal}
.md p{margin:0 0 6px}.md p:last-child{margin-bottom:0}.md p.h{font-weight:600;color:var(--text)}
.md ul,.md ol{margin:2px 0 6px;padding-left:20px}.md li{margin:1px 0}
.md code{font-size:12px;background:var(--surface2);padding:1px 5px;border-radius:4px;color:var(--text)}
.md pre.code{background:var(--surface2);border-radius:7px;padding:9px 12px;margin:4px 0 8px;overflow-x:auto;white-space:pre}
.md pre.code code{background:none;padding:0;font-size:12px;line-height:1.6}
.md b{color:var(--text);font-weight:600}
.md p.h1,.md p.h2{font-size:15px}.md hr{border:0;border-top:1px solid var(--line,#ddd);margin:8px 0}
.md blockquote{margin:4px 0 8px;padding:2px 0 2px 10px;border-left:3px solid var(--line,#ccc);color:var(--text2,#666)}
.md .callout{margin:4px 0 8px;padding:7px 10px;border-radius:7px;background:var(--surface2)}.md .callout .ct,.md .callout summary{font-weight:600;margin:0 0 4px;cursor:pointer}
.md .callout.warning,.md .callout.caution,.md .callout.failure{background:rgba(220,120,40,.12)}.md .callout.success{background:rgba(40,160,90,.12)}
.md .tbl{overflow-x:auto;margin:4px 0 8px}.md table{border-collapse:collapse;font-size:12.5px}.md th,.md td{border:1px solid var(--line,#ddd);padding:3px 8px}.md th{background:var(--surface2);font-weight:600}
.md .prog{position:relative;background:var(--surface2);border-radius:6px;height:20px;margin:4px 0 8px;overflow:hidden}.md .prog i{position:absolute;left:0;top:0;bottom:0;background:rgba(80,110,200,.35)}.md .prog span{position:relative;z-index:1;font-size:12px;padding:0 8px;line-height:20px}
.md .fn{font-size:12px;color:var(--text2,#666);border-top:1px solid var(--line,#ddd);margin-top:6px;padding-top:4px}.md .att{color:var(--text2,#666)}
.msg details.desp summary{color:var(--text2)}
.msg.compact{padding-top:12px;padding-bottom:12px}
.msg.compact .meta .sn{color:var(--text2);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0;flex:1 1 200px}
.msg .time{color:var(--text3);font-size:12px;white-space:nowrap;padding-top:2px;font-variant-numeric:tabular-nums}
.msg .time{display:flex;flex-direction:column;align-items:flex-end;gap:6px}.msg .del{visibility:hidden}.msg:hover .del,.msg .del:focus-within{visibility:visible}
.badge{display:inline-flex;align-items:center;height:19px;padding:0 6px;border-radius:4px;font-size:11px;font-weight:600;flex:none;white-space:nowrap}
.badge.p5{background:var(--p5);color:#fff}
.badge.p4{background:color-mix(in srgb,var(--p4) 15%,transparent);color:var(--p4)}
.badge.p3{background:color-mix(in srgb,var(--p3) 13%,transparent);color:var(--p3)}
.badge.p2,.badge.p1,.badge.p0{background:var(--surface2);color:var(--text2)}
.chip{display:inline-flex;align-items:center;gap:4px;height:20px;padding:0 7px;border-radius:5px;background:var(--surface2);color:var(--text2);font-size:11.5px;font-weight:500;white-space:nowrap}
.chip.ok{background:color-mix(in srgb,var(--ok) 14%,transparent);color:var(--ok)}
.chip.bad{background:color-mix(in srgb,var(--p5) 12%,transparent);color:var(--p5)}
.chip.acc{background:var(--accent-soft);color:var(--accent)}
.acctbar{display:flex;align-items:center;gap:8px;justify-content:flex-end;margin:-6px 0 10px}.acctbar select{height:28px;padding:0 8px}
ul.pairs{margin:6px 0 0;padding-left:16px;font-size:11.5px}
.chip.warn{background:color-mix(in srgb,var(--p4) 14%,transparent);color:var(--p4)}
.atts{display:flex;flex-wrap:wrap;gap:8px;margin-top:10px}
.att{display:flex;align-items:center;gap:9px;padding:6px 12px 6px 6px;border:1px solid var(--border);border-radius:8px;background:var(--surface);color:var(--text);max-width:300px;text-decoration:none}
.att:hover{border-color:var(--accent);text-decoration:none}
.att .ic{width:30px;height:30px;border-radius:6px;display:grid;place-items:center;font-size:9.5px;font-weight:700;letter-spacing:.02em;flex:none;background:color-mix(in srgb,var(--c) 14%,transparent);color:var(--c)}
.att .nm{display:flex;flex-direction:column;min-width:0;line-height:1.3}
.att .n{font-size:12.5px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.att .s{font-size:11px;color:var(--text3)}
.k-img{--c:#8758BF}.k-pdf{--c:#D44C3D}.k-doc{--c:#3E6BC4}.k-xls{--c:#3E8E63}.k-ppt{--c:#DB7B2E}.k-zip{--c:#958F84}.k-txt{--c:var(--text2)}.k-oth{--c:#958F84}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:6px;height:32px;padding:0 13px;border-radius:7px;border:1px solid var(--border);background:var(--surface);color:var(--text);font:inherit;font-weight:500;cursor:pointer;white-space:nowrap;text-decoration:none}
.btn:hover{background:var(--surface2);text-decoration:none}
.btn.primary{background:var(--accent);border-color:var(--accent);color:#fff;box-shadow:0 1px 2px rgba(52,72,143,.25)}
@media (prefers-color-scheme:dark){.btn.primary{color:#15161c}}
.btn.primary:hover{filter:brightness(1.08);background:var(--accent)}
.btn.danger{color:var(--p5)}
.btn.danger:hover{background:color-mix(in srgb,var(--p5) 9%,transparent);border-color:color-mix(in srgb,var(--p5) 35%,var(--border))}
.btn.ghost{border-color:transparent;background:transparent;color:var(--text2)}
.btn.ghost:hover{background:var(--surface2);color:var(--text)}
.btn.sm{height:27px;padding:0 10px;font-size:12.5px}
.btn svg{width:15px;height:15px}
.in{height:32px;padding:0 10px;border:1px solid var(--border);border-radius:7px;background:var(--surface);color:var(--text);font:inherit;outline:none;min-width:0}
.in:focus{border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-soft)}
select.in{padding-right:26px}
.check{display:inline-flex;align-items:center;gap:6px;color:var(--text2);cursor:pointer;user-select:none}
.check input{accent-color:var(--accent);width:15px;height:15px;margin:0}
.row{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
form.inline{display:inline;margin:0}
.filters{display:flex;gap:10px;flex-wrap:wrap;align-items:center;padding:12px 18px;border-bottom:1px solid var(--border);background:color-mix(in srgb,var(--surface2) 55%,var(--surface))}
.seg{display:inline-flex;background:var(--surface2);border-radius:8px;padding:2px;gap:2px}
.seg a{padding:4px 10px;border-radius:6px;color:var(--text2);font-size:12.5px;font-weight:500;text-decoration:none;display:flex;align-items:center;gap:6px}
.seg a.on{background:var(--surface);color:var(--text);box-shadow:0 1px 2px rgba(60,48,30,.12)}
.tbl{width:100%;border-collapse:collapse}
.tbl th{font-size:12px;color:var(--text3);font-weight:500;text-align:left;padding:10px 18px;border-bottom:1px solid var(--border);white-space:nowrap}
.tbl td{padding:13px 18px;border-bottom:1px solid var(--border);vertical-align:middle}
.tbl tr:last-child td{border-bottom:0}
.tbl tr.rev td{opacity:.5}
.tbl .r{text-align:right}
.dev{display:flex;align-items:center;gap:12px}
.dev .av{width:36px;height:36px;border-radius:9px;background:var(--surface2);display:grid;place-items:center;color:var(--text2);flex:none}
.dev .av svg{width:19px;height:19px}
.dev b{font-weight:600;display:block}
.muted{color:var(--text3)}.small{font-size:12px}
.sw{width:36px;height:21px;border-radius:11px;background:var(--border);position:relative;border:0;cursor:pointer;padding:0;transition:background .15s;vertical-align:middle}
.sw::after{content:"";position:absolute;top:2.5px;left:2.5px;width:16px;height:16px;border-radius:50%;background:#fff;transition:left .15s;box-shadow:0 1px 2px rgba(0,0,0,.25)}
.sw.on{background:var(--ok)}.sw.on::after{left:17.5px}
.key{padding:16px 18px;border-bottom:1px solid var(--border)}
.key:last-child{border-bottom:0}
.key.rev{opacity:.5}
.key .top{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.key .nm{font-weight:600;font-size:14px}
.key .when{margin-left:auto;color:var(--text3);font-size:12px;display:flex;gap:14px}
.keyline{display:flex;align-items:center;gap:6px;margin-top:10px}
.keyline .kl{flex:none;width:92px;color:var(--text3);font-size:12px}
.keyhint{line-height:1.75}.keyhint b{color:var(--text2);font-weight:600}.keyhint code{font-size:11.5px;background:var(--surface2);padding:1px 5px;border-radius:4px}
.keyline code{font-size:12.5px;background:var(--surface2);padding:7px 10px;border-radius:6px;flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--text)}
.snipbox{margin-top:12px;border:1px solid var(--border);border-radius:8px;overflow:hidden}
.tabs{display:flex;gap:2px;padding:0 6px;background:var(--surface2);border-bottom:1px solid var(--border);align-items:center}
.tabs button{background:none;border:0;padding:8px 10px 7px;color:var(--text2);font:inherit;font-size:12.5px;cursor:pointer;border-bottom:2px solid transparent;margin-bottom:-1px}
.tabs button.on{color:var(--text);border-color:var(--accent);font-weight:500}
.tabs .cp{margin-left:auto}
pre.snip{margin:0;padding:12px 14px;font-size:12px;line-height:1.65;white-space:pre-wrap;word-break:break-all;color:var(--text);background:var(--surface)}
.hl{border-color:color-mix(in srgb,var(--accent) 45%,var(--border));box-shadow:0 0 0 4px var(--accent-soft)}
.pair{display:flex;align-items:center;gap:28px;flex-wrap:wrap}
.paircode{font:600 42px/1 ui-monospace,"SF Mono",Menlo,monospace;letter-spacing:.2em;color:var(--text)}
.notes{margin:8px 0;padding:10px 14px;background:var(--surface2);border-radius:8px;color:var(--text2);font:inherit;font-size:13px;line-height:1.7;white-space:pre-wrap;word-break:break-word;max-height:320px;overflow:auto}
.updform{display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin-top:6px}
.updform .in{flex:1;min-width:220px}
.updform input[type=file]{font-size:12.5px;color:var(--text2);max-width:100%}
.updsec{margin-top:16px;padding-top:14px;border-top:1px solid var(--border)}
.updsec h3{font-size:13px;font-weight:600;margin:0 0 4px}
.cd{color:var(--text2);font-size:12.5px;margin-top:8px;font-variant-numeric:tabular-nums}
.steps{margin:0;padding-left:18px;color:var(--text2);line-height:1.8}
.empty{padding:44px 18px;text-align:center;color:var(--text2)}
.empty .big{font-size:15px;font-weight:600;color:var(--text);margin-bottom:6px}
.empty pre{text-align:left;display:inline-block;max-width:100%;background:var(--surface2);padding:10px 14px;border-radius:8px;font-size:12px;margin-top:12px;white-space:pre-wrap;word-break:break-all}
.pager{display:flex;justify-content:space-between;padding:12px 18px;border-top:1px solid var(--border)}
.kv{display:grid;grid-template-columns:140px 1fr;gap:10px 16px;margin:0}
.kv dt{color:var(--text3)}.kv dd{margin:0;word-break:break-all}
.flash{position:fixed;top:18px;left:50%;transform:translateX(-50%);background:var(--text);color:var(--surface);padding:9px 16px;border-radius:9px;font-weight:500;box-shadow:0 10px 30px rgba(0,0,0,.18);z-index:9;animation:fl 4s forwards}
@keyframes fl{0%{opacity:0;transform:translate(-50%,-6px)}6%,82%{opacity:1;transform:translate(-50%,0)}100%{opacity:0;visibility:hidden}}
.login{min-height:100vh;display:grid;place-items:center;padding:24px}
.login .card{width:380px;max-width:100%;padding:30px 28px 24px;margin:0}
.login .logo{width:44px;height:44px;border-radius:12px;margin-bottom:16px}
.login h1{font-size:19px}
.login .in{width:100%;height:38px;margin:18px 0 12px}
.login .btn{width:100%;height:38px;margin-top:16px}
.err{color:var(--p5);font-size:12.5px;margin-top:10px}
.hint{margin-top:20px;padding-top:16px;border-top:1px solid var(--border);color:var(--text3);font-size:12px;line-height:1.7}
.hint code{font-size:11.5px;background:var(--surface2);padding:2px 5px;border-radius:4px;color:var(--text2)}
@media (max-width:980px){.grid4{grid-template-columns:repeat(2,minmax(0,1fr))}.cols{grid-template-columns:1fr}}
@media (max-width:760px){.side{width:62px;padding:16px 8px}.brand span,.nav .lb,.side .foot .tx{display:none}.brand{justify-content:center;padding:2px 0 18px}.nav a{justify-content:center}.main{padding:22px 16px 48px}}
details.edit{margin-top:6px}
details.edit summary{cursor:pointer;list-style:none;display:inline-block}
details.edit summary:hover{color:var(--accent)}
details.edit form{margin-top:6px;gap:6px}
.copyid{cursor:pointer;border-bottom:1px dashed var(--border)}
.copyid:hover{color:var(--accent)}
form.search{margin:0 0 12px;gap:6px}
</style>{{end}}`

const adminIcons = `
{{/* 回笺图标简化版（design/icon/make.py 的 svg(theme, simple=True)），颜色随页面亮 / 暗主题切换（.logo 的 --lg-* 变量） */}}
{{define "i-logo"}}<svg xmlns="http://www.w3.org/2000/svg" aria-hidden="true" viewBox="0 0 1024 1024"><rect width="1024" height="1024" style="fill:var(--lg-bg)"/><g transform="translate(512 512) scale(1.1200) translate(-534 -470)"><rect x="476" y="404" width="420" height="304" rx="46" stroke-width="26" style="fill:var(--lg-env);stroke:var(--lg-line)"/><polyline points="500,446 686,572 872,446" fill="none" style="stroke:var(--lg-flap)" stroke-width="30" stroke-linecap="round" stroke-linejoin="round"/><path d="M 118 566 C 130 330, 500.5 125.1, 627.0 317.2 L 578.6 349.1 C 474.1 190.5, 190 360, 118 566 Z" style="fill:var(--lg-arrow)"/><path d="M 660.0 420.0 L 557.7 362.9 L 647.9 303.4 Z" stroke-width="14" stroke-linejoin="round" paint-order="stroke" style="fill:var(--lg-arrow);stroke:var(--lg-bg)"/><line x1="812" y1="352" x2="784" y2="306" style="stroke:var(--lg-spark)" stroke-width="26" stroke-linecap="round"/><line x1="862" y1="334" x2="862" y2="272" style="stroke:var(--lg-spark)" stroke-width="26" stroke-linecap="round"/><line x1="912" y1="352" x2="940" y2="306" style="stroke:var(--lg-spark)" stroke-width="26" stroke-linecap="round"/></g></svg>{{end}}
{{define "i-overview"}}<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="7" height="9" rx="1.5"/><rect x="14" y="3" width="7" height="5" rx="1.5"/><rect x="14" y="12" width="7" height="9" rx="1.5"/><rect x="3" y="16" width="7" height="5" rx="1.5"/></svg>{{end}}
{{define "i-messages"}}<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M22 12h-6l-2 3h-4l-2-3H2"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/></svg>{{end}}
{{define "i-keys"}}<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="7.5" cy="15.5" r="5.5"/><path d="m21 2-9.6 9.6M15.5 7.5l3 3L22 7l-3-3"/></svg>{{end}}
{{define "i-devices"}}<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="4" width="14" height="10" rx="1.5"/><path d="M5 18h8"/><rect x="17" y="8" width="5" height="12" rx="1.2"/></svg>{{end}}
{{define "i-settings"}}<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M20 7h-9M14 17H5"/><circle cx="17" cy="17" r="3"/><circle cx="7" cy="7" r="3"/></svg>{{end}}
{{define "i-laptop"}}<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M20 16V7a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v9m16 0H4m16 0 1.28 2.55a1 1 0 0 1-.9 1.45H3.62a1 1 0 0 1-.9-1.45L4 16"/></svg>{{end}}
{{define "i-phone"}}<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="6" y="2" width="12" height="20" rx="2.5"/><path d="M11 18h2"/></svg>{{end}}
{{define "i-box"}}<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M21 8 12 3 3 8v8l9 5 9-5z"/><path d="m3 8 9 5 9-5M12 13v8"/></svg>{{end}}
{{define "i-clip"}}<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="m21.4 11.1-9.2 9.2a6 6 0 0 1-8.5-8.5l9.2-9.2a4 4 0 0 1 5.7 5.7l-9.2 9.2a2 2 0 0 1-2.8-2.8l8.5-8.5"/></svg>{{end}}
{{define "i-plus"}}<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></svg>{{end}}
{{define "i-logout"}}<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9"/></svg>{{end}}
`

const adminTemplates = `
{{define "top"}}<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark"><link rel="icon" type="image/png" href="/favicon.png"><link rel="apple-touch-icon" href="/apple-touch-icon.png"><title>{{.Title}} · 回笺</title>{{template "css"}}</head><body>
{{if .Flash}}<div class="flash">{{.Flash}}</div>{{end}}
<div class="app"><aside class="side">
<div class="brand"><div class="logo">{{template "i-logo"}}</div><span>回笺<small>Huijian · 消息中台</small></span></div>
<nav class="nav">
<a href="/" class="{{if eq .Nav "overview"}}on{{end}}">{{template "i-overview"}}<span class="lb">概览</span></a>
<a href="/messages" class="{{if eq .Nav "messages"}}on{{end}}">{{template "i-messages"}}<span class="lb">消息</span></a>
<a href="/keys" class="{{if eq .Nav "keys"}}on{{end}}">{{template "i-keys"}}<span class="lb">Pushkey</span></a>
<a href="/devices" class="{{if eq .Nav "devices"}}on{{end}}">{{template "i-devices"}}<span class="lb">设备</span></a>
<a href="/accounts" class="{{if eq .Nav "accounts"}}on{{end}}">{{template "i-keys"}}<span class="lb">账号</span></a>
<a href="/settings" class="{{if eq .Nav "settings"}}on{{end}}">{{template "i-settings"}}<span class="lb">设置</span></a>
</nav>
<div class="foot"><div class="live"><span class="pulse{{if not .Online}} off{{end}}"></span><span class="tx">{{.Online}} 台设备在线</span></div>
<span class="tx">回笺 v{{.Version}}</span></div>
</aside><main class="main"><div class="wrap">{{if ne .Nav "accounts"}}{{if ne .Nav "settings"}}{{template "acctbar" .}}{{end}}{{end}}{{end}}

{{define "bottom"}}</div></main></div>
<script>
function copyText(t,btn){var ta=document.createElement('textarea');ta.value=t;ta.style.position='fixed';ta.style.opacity='0';document.body.appendChild(ta);ta.select();var ok=false;try{ok=document.execCommand('copy')}catch(e){}document.body.removeChild(ta);if(!ok&&navigator.clipboard){navigator.clipboard.writeText(t);ok=true}if(btn){var o=btn.textContent;btn.textContent=ok?'已复制':'复制失败';setTimeout(function(){btn.textContent=o},1400)}}
document.addEventListener('click',function(e){
 var c=e.target.closest('[data-copy]');if(c){e.preventDefault();copyText(c.getAttribute('data-copy'),c);return}
 var s=e.target.closest('[data-copy-snip]');if(s){e.preventDefault();var box=s.closest('.snipbox');var pre=box.querySelector('pre.snip:not([hidden])');copyText(pre.textContent,s);return}
 var r=e.target.closest('[data-reveal]');if(r){var el=document.getElementById(r.getAttribute('data-reveal'));if(el.textContent===el.getAttribute('data-mask')){el.textContent=el.getAttribute('data-full');r.textContent='隐藏'}else{el.textContent=el.getAttribute('data-mask');r.textContent='显示'}return}
 var tb=e.target.closest('.tabs button[data-tab]');if(tb){var g=tb.closest('.snipbox');g.querySelectorAll('.tabs button[data-tab]').forEach(function(b){b.classList.toggle('on',b===tb)});g.querySelectorAll('pre.snip').forEach(function(p){p.hidden=p.getAttribute('data-pane')!==tb.getAttribute('data-tab')})}
});
document.querySelectorAll('form[data-confirm]').forEach(function(f){f.addEventListener('submit',function(e){if(!confirm(f.getAttribute('data-confirm')))e.preventDefault()})});
var cd=document.querySelector('[data-expire]');if(cd){var end=+cd.getAttribute('data-expire')*1000;(function tick(){var s=Math.max(0,Math.round((end-Date.now())/1000));cd.textContent=s>0?(Math.floor(s/60)+':'+String(s%60).padStart(2,'0')+' 后失效'):'已失效，请重新生成';if(s>0)setTimeout(tick,1000)})()}
var up=document.querySelector('[data-upd-poll]');if(up){(function(){var stg=document.getElementById('upd-stage'),ver=up.getAttribute('data-upd-poll'),bad=0;function fail(){if(!bad)bad=Date.now();if(Date.now()-bad>120000){location.reload();return}setTimeout(poll,1500)}function poll(){fetch('/update/status',{credentials:'same-origin',cache:'no-store'}).then(function(r){if(r.redirected){location.reload();return null}if(!r.ok)throw new Error('HTTP '+r.status);return r.json()}).then(function(s){if(!s)return;bad=0;if(!s.applying||s.version!==ver){location.reload();return}if(stg&&s.stage)stg.textContent=s.stage;setTimeout(poll,1000)}).catch(fail)}poll()})()}
if(location.search.indexOf('f=')>=0&&history.replaceState){var u=new URL(location.href);u.searchParams.delete('f');history.replaceState(null,'',u.pathname+(u.search||''))}
</script></body></html>{{end}}

{{define "msgrow"}}<div class="msg p{{.Priority}}{{if le .Priority 1}} dim{{end}}">
<div class="body">
<div class="t"><span class="badge p{{.Priority}}">P{{.Priority}} {{pname .Priority}}</span><span class="tt" title="{{.Text}}">{{.Text}}</span></div>
<div class="meta"><span class="chip"># {{.Topic}}</span>{{if .Sealed}}<span class="chip" title="发送端用普通 pushkey 发来，服务器收到后立即加密保存；内容只能在已解锁的回笺客户端里看">🔐 服务器加密</span>{{else if .E2E}}<span class="chip" title="发送端加密，服务器看不到内容；请在已解锁的回笺客户端里看">🔒 端到端加密</span>{{end}}{{if .Thread}}<span class="chip">线程 · {{.Thread}}</span>{{end}}{{if .Source}}<span>来自 {{.Source}}</span>{{end}}</div>
{{if .Desp}}{{if long .Desp}}<details class="desp md"><summary>{{snip (msgplain .) 160}}</summary>{{msgmd .}}</details>{{else}}<div class="desp md">{{msgmd .}}</div>{{end}}{{end}}
{{if .Attachments}}<div class="atts">{{range .Attachments}}{{$k := kind .Mime .Name}}<a class="att k-{{$k.Class}}" href="/att/{{.ID}}" title="下载 {{.Name}}"><span class="ic">{{$k.Label}}</span><span class="nm"><span class="n">{{.Name}}</span><span class="s">{{size .Size}}</span></span></a>{{end}}</div>{{end}}
</div>
<div class="time"><span title="{{full .CreatedAt}}">{{rel .CreatedAt}}</span>
<form class="inline del" method="post" action="/messages/{{.ID}}/delete" data-confirm="删除这条消息？这个账号的所有设备上都会消失，附件一起删除，无法恢复。"><input type="hidden" name="u" value="{{.Owner}}"><button class="btn sm danger" title="删除这条消息">删除</button></form></div>
</div>{{end}}

{{define "msgrowc"}}<div class="msg compact p{{.Priority}}{{if le .Priority 1}} dim{{end}}">
<div class="body"><div class="t"><span class="badge p{{.Priority}}">P{{.Priority}} {{pname .Priority}}</span><span class="tt" title="{{.Text}}">{{.Text}}</span></div>
<div class="meta"><span class="chip"># {{.Topic}}</span>{{if .Sealed}}<span class="chip" title="发送端用普通 pushkey 发来，服务器收到后立即加密保存；内容只能在已解锁的回笺客户端里看">🔐 服务器加密</span>{{else if .E2E}}<span class="chip" title="发送端加密，服务器看不到内容；请在已解锁的回笺客户端里看">🔒 端到端加密</span>{{end}}{{if .Thread}}<span class="chip">线程 · {{.Thread}}</span>{{end}}{{if .Attachments}}<span class="chip">📎 {{len .Attachments}} 个附件</span>{{end}}{{if .Desp}}<span class="sn">{{snip (msgplain .) 90}}</span>{{end}}</div></div>
<div class="time" title="{{full .CreatedAt}}">{{rel .CreatedAt}}</div></div>{{end}}

{{define "login"}}<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark"><link rel="icon" type="image/png" href="/favicon.png"><link rel="apple-touch-icon" href="/apple-touch-icon.png"><title>登录 · 回笺</title>{{template "css"}}</head><body>
<div class="login"><div class="card">
<div class="logo">{{template "i-logo"}}</div>
<h1>回笺 · 管理后台</h1><div class="sub">输入管理令牌登录。勾选「记住」后这个浏览器一年内免登录。</div>
<form method="post" action="/login">
<input class="in mono" type="password" name="token" placeholder="AT_…" autocomplete="current-password" autofocus required>
<label class="check"><input type="checkbox" name="remember" value="1" checked> 记住此浏览器（一年，访问即自动顺延）</label>
{{if eq .Err "1"}}<div class="err">令牌不正确</div>{{end}}
{{if eq .Err "link"}}<div class="err">登录链接已失效或已被使用，请重新获取</div>{{end}}
{{if eq .Err "rate"}}<div class="err">尝试太频繁，请一分钟后再试</div>{{end}}
<button class="btn primary">登录</button>
</form>
<div class="hint">更方便的方式：在 Mac 菜单栏的回笺里点「管理后台」，一键登录。<br>
第一次登录或忘记令牌：在服务器上执行 <code>docker exec huijian huijian admin-link</code>，会给出一个一次性登录链接。</div>
</div></div></body></html>{{end}}

{{define "overview"}}{{template "top" .}}
<div class="head"><div><h1>概览</h1><div class="sub">{{if .LastMsg}}最近一条消息 {{rel .LastMsg}}{{else}}还没有收到过消息{{end}}</div></div>
<a class="btn" href="/messages">查看全部消息</a></div>

<div class="grid4">
<div class="card stat"><div class="k"><span class="ti" style="--c:var(--accent)">{{template "i-messages"}}</span>今日消息</div><div class="v">{{.Today}}</div><div class="d">近 24 小时 {{.Total24}} 条</div></div>
<div class="card stat"><div class="k"><span class="ti" style="--c:var(--ok)">{{template "i-devices"}}</span>在线设备</div><div class="v">{{.Online}}<small> / {{.ActiveDevices}}</small></div><div class="d">正在等待新消息的设备</div></div>
<div class="card stat"><div class="k"><span class="ti" style="--c:#8758BF">{{template "i-clip"}}</span>附件</div><div class="v">{{size .Stats.AttBytes}}</div><div class="d">{{.Stats.Attachments}} 个文件</div></div>
<div class="card stat"><div class="k"><span class="ti" style="--c:var(--p4)">{{template "i-keys"}}</span>Pushkey</div><div class="v">{{.Stats.Pushkeys}}</div><div class="d">有效的发送凭证</div></div>
</div>

<div class="cols">
<div class="card"><div class="card-h"><h2>近 14 天消息量</h2><span class="aside">按天</span></div><div class="card-b">
<div class="chart">{{range .Days}}<div class="col" title="{{.Label}}：{{.Count}} 条"><span class="n">{{if .Count}}{{.Count}}{{end}}</span><div class="bar{{if not .Count}} zero{{end}}" style="height:{{.Pct}}%"></div><span class="lb">{{.Label}}</span></div>{{end}}</div>
</div></div>
<div class="card"><div class="card-h"><h2>近 24 小时级别分布</h2><span class="aside">{{.Total24}} 条</span></div><div class="card-b">
{{if .Segs}}<div class="stack">{{range .Segs}}<span class="c{{.P}}" style="width:{{pct .Pct}}%" title="P{{.P}} {{.Count}} 条"></span>{{end}}</div>
<ul class="legend">{{range .Segs}}<li><span class="dot c{{.P}}"></span>P{{.P}} {{pname .P}}<b>{{.Count}}</b></li>{{end}}</ul>
{{else}}<div class="muted">近 24 小时没有消息</div>{{end}}
</div></div>
</div>

<div class="card"><div class="card-h"><h2>最近消息</h2><a class="small" href="/messages">全部 →</a></div>
{{range .Recent}}{{template "msgrowc" .}}{{else}}<div class="empty"><div class="big">还没有消息</div>先到「Pushkey」新建一把 key，然后试一下：
<pre>curl "{{.PublicURL}}/message/push?pushkey=PK_xxx&text=hello"</pre></div>{{end}}
</div>

<div class="card"><div class="card-h"><h2>发送测试消息</h2><span class="aside">发给自己所有设备</span></div><div class="card-b">
<form method="post" action="/test" class="row"><input type="hidden" name="u" value="{{$.Acct.ID}}"><input class="in" name="text" placeholder="标题" style="flex:2;min-width:180px">
<input class="in" name="desp" placeholder="正文（可选，支持 Markdown）" style="flex:3;min-width:200px">
<select class="in" name="priority"><option value="5">P5 紧急</option><option value="4">P4 重要</option><option value="3" selected>P3 普通</option><option value="2">P2 低</option></select>
<button class="btn primary">发送</button></form></div></div>
{{template "bottom" .}}{{end}}

{{define "messages"}}{{template "top" .}}
<div class="head"><div><h1>消息</h1><div class="sub">所有发给你的消息。附件可以直接点击下载。</div></div></div>
<div class="card">
<form class="filters" method="get" action="/messages">
<div class="seg">{{range .PrioOpts}}<a href="{{.Href}}" class="{{if .On}}on{{end}}">{{if ge .P 0}}<span class="dot c{{.P}}"></span>{{end}}{{.Label}}</a>{{end}}</div>
{{if ge .F.Priority 0}}<input type="hidden" name="p" value="{{.F.Priority}}">{{end}}
<select class="in" name="topic" onchange="this.form.submit()"><option value="">全部频道</option>{{$t := .F.Topic}}{{range .Topics}}<option value="{{.Topic}}" {{if eq .Topic $t}}selected{{end}}># {{.Topic}}（{{.Count}}）</option>{{end}}</select>
<input class="in" name="q" value="{{.F.Q}}" placeholder="搜索标题、正文、线程、来源" style="flex:1;min-width:180px">
<label class="check"><input type="checkbox" name="att" value="1" {{if .F.HasAtt}}checked{{end}} onchange="this.form.submit()"> 只看有附件</label>
<button class="btn">搜索</button>
</form>
{{range .Msgs}}{{template "msgrow" .}}{{else}}<div class="empty"><div class="big">没有符合条件的消息</div>换个筛选条件试试。</div>{{end}}
{{if or .Paged .Next}}<div class="pager">{{if .Paged}}<a class="btn sm" href="/messages">← 回到最新</a>{{else}}<span></span>{{end}}{{if .Next}}<a class="btn sm" href="{{.Next}}">更早的消息 →</a>{{end}}</div>{{end}}
</div>
{{template "bottom" .}}{{end}}

{{define "keys"}}{{template "top" .}}
<div class="head"><div><h1>Pushkey <span class="chip acc" title="pushkey 属于账号，这个账号的所有设备看到的是同一组">账号「{{.Acct.Label}}」</span></h1><div class="sub">发送方用 pushkey 把消息发给账号「{{.Acct.Label}}」的所有设备。建议每台机器、每个项目各用一把，泄露时只吊销那一把即可。</div></div>
<form method="post" action="/keys" class="row"><input type="hidden" name="u" value="{{$.Acct.ID}}"><input class="in" name="name" placeholder="备注，例如：PC 训练脚本" required maxlength="40" style="width:200px"{{if not .HasActiveKey}} value="default"{{end}}><input class="in mono" name="key" placeholder="自定义 key（可选）" pattern="[A-Za-z0-9_\-]{16,64}" title="16–64 位字母、数字、下划线或短横线" style="width:200px"><button class="btn primary">{{template "i-plus"}}新建</button></form></div>
{{$pub := .PublicURL}}{{$new := .NewKey}}{{$sp := .SendPub}}
{{if $sp}}<div class="card"><div class="card-b small muted keyhint"><b>加密发送密钥</b>（<code>&lt;pushkey&gt;.e2e.&lt;公钥&gt;</code>）给 huijian 命令行和 Python SDK 用：标题、正文、附件在发送端加密，服务器看不到内容。<br><b>普通 pushkey</b> 适合 curl 等无法加密的发送端，消息由服务器收到后立即用账号公钥加密再保存（服务器代加密，始终开启）：数据库和备份里没有明文，但服务器在收到的那一刻能看到内容。</div></div>{{end}}
<div class="card">
{{range $i, $k := .Keys}}<div class="key{{if $k.Revoked}} rev{{end}}">
<div class="top"><span class="nm">{{$k.Name}}</span>{{if $k.Revoked}}<span class="chip bad">已吊销</span>{{else if eq $k.Key $new}}<span class="chip acc">刚创建</span>{{else}}<span class="chip ok">有效</span>{{end}}
<span class="when"><span title="{{full $k.Created}}">创建于 {{rel $k.Created}}</span><span>{{if $k.LastUsed.Valid}}<span title="{{full $k.LastUsed.Int64}}">最近使用 {{rel $k.LastUsed.Int64}}</span>{{else}}从未使用{{end}}</span></span>
{{if $k.Revoked}}<form class="inline" method="post" action="/keys/{{$k.ID}}/delete" data-confirm="彻底删除「{{$k.Name}}」？历史消息会保留。"><input type="hidden" name="u" value="{{$.Acct.ID}}"><button class="btn sm danger">删除</button></form>{{end}}</div>
{{if not $k.Revoked}}
{{$ek := $k.Key}}{{if $sp}}{{$ek = printf "%s.e2e.%s" $k.Key $sp}}
<div class="keyline"><span class="kl">加密发送密钥</span><code id="e{{$k.ID}}" data-mask="{{mask $k.Key}}.e2e.{{$sp}}" data-full="{{$ek}}">{{if eq $k.Key $new}}{{$ek}}{{else}}{{mask $k.Key}}.e2e.{{$sp}}{{end}}</code>
<button class="btn sm" data-reveal="e{{$k.ID}}">{{if eq $k.Key $new}}隐藏{{else}}显示{{end}}</button><button class="btn sm" data-copy="{{$ek}}">复制</button></div>{{end}}
<div class="keyline">{{if $sp}}<span class="kl">普通 pushkey</span>{{end}}<code id="k{{$k.ID}}" data-mask="{{mask $k.Key}}" data-full="{{$k.Key}}">{{if eq $k.Key $new}}{{$k.Key}}{{else}}{{mask $k.Key}}{{end}}</code>
<button class="btn sm" data-reveal="k{{$k.ID}}">{{if eq $k.Key $new}}隐藏{{else}}显示{{end}}</button><button class="btn sm" data-copy="{{$k.Key}}">复制</button>
<form class="inline" method="post" action="/keys/{{$k.ID}}/revoke" data-confirm="吊销「{{$k.Name}}」后，使用它的发送方将无法再发送（加密发送密钥也一起失效）。确定吗？"><input type="hidden" name="u" value="{{$.Acct.ID}}"><button class="btn sm danger">吊销</button></form></div>
<details class="edit"><summary class="muted small">改名 / 更换 key</summary>
<form method="post" action="/keys/{{$k.ID}}/update" class="row" data-confirm="确定保存？如果更换了 key，旧 key 会立即失效。"><input type="hidden" name="u" value="{{$.Acct.ID}}">
<input class="in" name="name" value="{{$k.Name}}" maxlength="40" style="width:180px">
<input class="in mono" name="key" placeholder="新 key（留空不变）" pattern="[A-Za-z0-9_\-]{16,64}" title="16–64 位字母、数字、下划线或短横线" style="width:240px">
<button class="btn sm">保存</button></form></details>
<div class="snipbox{{if eq $k.Key $new}} hl{{end}}"><div class="tabs">
<button type="button" data-tab="a" class="on">curl</button><button type="button" data-tab="b">curl + 附件</button><button type="button" data-tab="c">命令行</button><button type="button" data-tab="d">Python</button>
<button type="button" class="btn ghost sm cp" data-copy-snip>复制</button></div>
<pre class="snip" data-pane="a">curl "{{$pub}}/message/push?pushkey={{$k.Key}}&amp;text=训练完成"</pre>
<pre class="snip" data-pane="b" hidden>curl -F pushkey={{$k.Key}} -F text="exp42 完成" -F priority=4 \
     -F desp="val_loss **0.231**" -F file=@loss.png -F file=@report.pdf \
     {{$pub}}/message/push</pre>
<pre class="snip" data-pane="c" hidden>export HUIJIAN_URL={{$pub}}
export HUIJIAN_PUSHKEY={{$ek}}
huijian push -p 4 -topic train -f loss.png "exp42 完成"</pre>
<pre class="snip" data-pane="d" hidden>import huijian   # sdk/python/huijian.py，单文件无依赖
huijian.push("exp42 完成", "val_loss 0.231", files=["loss.png"], priority=4,
            topic="train", pushkey="{{$ek}}")

with huijian.run("exp42", pushkey="{{$ek}}"):   # 自动发送开始/完成/异常
    train()</pre>
</div>{{end}}
</div>{{else}}<div class="empty"><div class="big">还没有 pushkey</div>在右上角填一个备注，新建第一把。</div>{{end}}
</div>
{{template "bottom" .}}{{end}}

{{define "devices"}}{{template "top" .}}
<div class="head"><div><h1>设备</h1><div class="sub">接收消息的设备。每台设备有自己的凭证，可以随时吊销，不影响其他设备。</div></div>
<form method="post" action="/pair" class="row"><input type="hidden" name="u" value="{{$.Acct.ID}}"><span class="muted small">加入账号「{{.Acct.Label}}」</span><label class="check" title="允许后，这台设备可以一键登录管理后台、查看服务器存储与备份（服务器级权限，只给你自己的设备）"><input type="checkbox" name="can_admin" value="1"> 允许管理服务器</label><button class="btn primary">{{template "i-plus"}}添加设备</button></form></div>

{{if .Code}}<div class="card hl"><div class="card-h"><h2>配对码</h2><span class="aside">只能使用一次</span></div><div class="card-b pair">
<div><div class="paircode">{{.Code}}</div><div class="cd" data-expire="{{.CodeExp}}"></div></div>
<ol class="steps"><li>打开回笺 App，在配对窗口输入这 6 位数字</li>
<li>服务器地址：<code class="mono">{{.PublicURL}}</code>{{if .InternalURL}}（内网也可以填 <code class="mono">{{.InternalURL}}</code>）{{end}}</li>
<li>配对后这台设备进入账号「{{.Acct.Label}}」，可以管理这个账号的 pushkey；{{if .CodeAdmin}}并且<b>可以</b>一键进入管理后台{{else}}没有服务器管理权限，需要时在下方打开「允许管理」{{end}}</li>
<li>同一台设备再次配对或登录时会沿用原来的设备记录，不会重复出现</li></ol>
</div></div>{{end}}

<form method="get" action="/devices" class="row search"><input class="in" type="search" name="q" value="{{.Q}}" placeholder="按名称或设备 ID 搜索" style="width:280px"><button class="btn sm">搜索</button>{{if .Q}}<a class="btn sm ghost" href="/devices">清除</a>{{end}}</form>
<div class="card">{{$on := .OnlineMap}}
<table class="tbl"><tr><th>设备</th><th>状态</th><th>配对</th><th title="服务器级权限：一键登录本管理后台、查看服务器存储与备份">允许管理</th><th class="r"></th></tr>
{{range .Devices}}<tr class="{{if .Revoked}}rev{{end}}">
<td><div class="dev"><div class="av">{{if eq .Platform "macos"}}{{template "i-laptop"}}{{else if eq .Platform "ios"}}{{template "i-phone"}}{{else}}{{template "i-box"}}{{end}}</div>
<div><b>{{.Name}}</b><span class="muted small mono">{{if .Client}}{{.Client}}{{else}}{{.Platform}}{{end}}{{if and (not .Revoked) (index $.Outdated .ID)}} <span class="chip warn" title="客户端不是最新版本，部分新功能需要更新客户端后才能使用">较旧</span>{{end}} · <span class="copyid" data-copy="{{.ID}}" title="点击复制设备 ID">{{.ID}}</span></span>
{{if $.AcctLabels}}<span class="chip acc small">{{index $.AcctLabels .UserID}}</span>{{end}}
{{if not .Revoked}}<details class="edit"><summary class="muted small">改名</summary><form method="post" action="/devices/{{.ID}}/rename" class="row"><input class="in" name="name" value="{{.Name}}" maxlength="64" style="width:180px"><button class="btn sm">保存</button></form></details>{{end}}</div></div></td>
<td>{{if .Revoked}}<span class="chip bad">已吊销</span>{{else if index $on .ID}}<span class="live"><span class="pulse"></span>在线</span>{{else}}<span class="muted" title="{{if .LastSeen.Valid}}{{full .LastSeen.Int64}}{{end}}">{{if .LastSeen.Valid}}{{rel .LastSeen.Int64}}在线{{else}}从未连接{{end}}</span>{{end}}</td>
<td class="muted small"><span title="{{full .Created}}">首次 {{rel .Created}}</span>{{if gt .PairCount 1}}
<details class="edit"><summary class="muted small">配对 {{.PairCount}} 次 · 最近 {{rel .LastPaired}}</summary><ul class="pairs">{{range index $.Pairings .ID}}<li title="{{.Client}}">{{full .At}} · {{.MethodLabel}}{{if .IP}} · {{.IP}}{{end}}</li>{{end}}</ul></details>{{end}}</td>
<td>{{if not .Revoked}}<form class="inline" method="post" action="/devices/{{.ID}}/admin"><input type="hidden" name="on" value="{{if .CanAdmin}}0{{else}}1{{end}}"><button class="sw{{if .CanAdmin}} on{{end}}" title="{{if .CanAdmin}}已允许，点击关闭{{else}}未允许，点击开启{{end}}"></button></form>{{end}}</td>
<td class="r">{{if not .Revoked}}<form class="inline" method="post" action="/devices/{{.ID}}/revoke" data-confirm="吊销「{{.Name}}」后它将无法再接收消息，需要重新配对。确定吗？"><button class="btn sm danger">吊销</button></form>{{end}}</td></tr>
{{else}}<tr><td colspan="5"><div class="empty">{{if .Q}}<div class="big">没有匹配「{{.Q}}」的设备</div>{{else}}<div class="big">还没有设备</div>点右上角「添加设备」生成配对码。{{end}}</div></td></tr>{{end}}
</table></div>
{{template "bottom" .}}{{end}}

{{define "settings"}}{{template "top" .}}
<div class="head"><div><h1>设置</h1><div class="sub">登录状态和服务信息。</div></div>
<form method="post" action="/logout"><button class="btn">{{template "i-logout"}}退出登录</button></form></div>

<div class="card"><div class="card-h"><h2>已登录的浏览器</h2><span class="aside">勾选「记住」的会话每次访问自动顺延一年</span></div>
<table class="tbl"><tr><th>浏览器</th><th>登录时间</th><th>最近访问</th><th>有效期</th><th class="r"></th></tr>
{{$cur := .Current}}{{range .Sessions}}<tr><td>{{.Label}} {{if eq .IDHash $cur}}<span class="chip acc">当前</span>{{end}}</td>
<td class="muted" title="{{full .Created}}">{{rel .Created}}</td><td class="muted" title="{{full .LastSeen}}">{{rel .LastSeen}}</td>
<td class="muted">{{if .Sliding}}记住（至 {{full .Expires}}）{{else}}本次会话（12 小时）{{end}}</td>
<td class="r"><form class="inline" method="post" action="/sessions/{{.IDHash}}/revoke" data-confirm="注销这个浏览器的登录？"><button class="btn sm danger">注销</button></form></td></tr>{{end}}
</table></div>

<div class="card"><div class="card-h"><h2>如何登录</h2></div><div class="card-b">
<ol class="steps">
<li><b>记住此浏览器</b>：用令牌登录时勾选「记住」，一年内免登录，容器重启也不会掉。</li>
<li><b>Mac 一键登录</b>：在「设备」页为你的 Mac 打开「管理后台」开关，然后在菜单栏回笺里点「管理后台」。</li>
<li><b>忘记令牌</b>：在服务器上执行下面的命令，得到一个 5 分钟有效的一次性登录链接：</li></ol>
<div class="keyline"><code>docker exec huijian huijian admin-link</code><button class="btn sm" data-copy="docker exec huijian huijian admin-link">复制</button></div>
</div></div>

{{with .Update}}<div class="card" id="update"><div class="card-h"><h2>服务端更新</h2><span class="aside">从 GitHub（{{.Repo}}）检查，签名校验通过才会安装；更新前自动备份数据库</span>
{{if .Enabled}}<form class="inline" method="post" action="/update/check" style="margin-left:auto"><button class="btn sm"{{if .Applying}} disabled{{end}}>检查更新</button></form>{{end}}</div><div class="card-b">
<dl class="kv"><dt>当前版本</dt><dd>v{{.Current}} <span class="muted small mono">{{.Platform}}</span></dd>
{{if not .Enabled}}<dt>状态</dt><dd class="muted">已关闭（HUIJIAN_SERVER_UPDATE=0）</dd>{{else}}
<dt>最新版本</dt><dd>{{with .Latest}}v{{.Version}} {{if .Newer}}<span class="chip acc">可更新</span>{{else}}<span class="chip">已是最新</span>{{end}} <a class="muted small" href="{{.Page}}" target="_blank" rel="noopener">发布说明</a>{{else}}<span class="muted">{{if .CheckErr}}检查失败：{{.CheckErr}}{{else}}尚未检查（启动 1 分钟后自动检查，之后每 12 小时一次）{{end}}</span>{{end}}</dd>
{{if .Checked}}<dt>上次检查</dt><dd class="muted" title="{{full .Checked}}">{{rel .Checked}}{{if and .CheckErr .Latest}} · 最近一次失败：{{.CheckErr}}{{end}}</dd>{{end}}
<dt>下载代理</dt><dd>{{if .Proxy}}<span class="mono">{{.Proxy}}</span>{{else if not .ProxyErr}}<span class="muted">不使用</span>{{end}} <span class="muted small">{{.ProxySource}}</span>{{if .ProxyErr}}<br><span class="small" style="color:var(--danger,#c33)">设置有误：{{.ProxyErr}}</span>{{end}}</dd>
{{if .Mirror}}<dt>下载镜像</dt><dd><span class="mono">{{.Mirror}}</span> <span class="muted small">HUIJIAN_SERVER_UPDATE_MIRROR，只用于下载清单和程序</span></dd>{{end}}
{{if .Applying}}<dt>进度</dt><dd data-upd-poll="{{.Current}}"><b id="upd-stage">{{.Stage}}</b><span class="muted small">（页面自动刷新；完成后服务自动重启）</span></dd>{{end}}
{{if .ApplyErr}}<dt>上次更新</dt><dd style="color:var(--danger,#c33)">失败：{{.ApplyErr}}</dd>{{end}}
{{if .Bad}}<dt>已回退</dt><dd class="muted">{{range .Bad}}v{{.}} {{end}}更新后没能正常启动，已自动回退到当前版本</dd>{{end}}{{end}}</dl>
{{with .Latest}}{{if and .Newer $.Update.Enabled}}{{if .Notes}}<pre class="notes">{{.Notes}}</pre>{{end}}
<form method="post" action="/update/apply" data-confirm="更新到 v{{.Version}}？会先备份数据库，然后服务重启约半分钟，期间客户端会自动重连。"><button class="btn acc"{{if $.Update.Applying}} disabled{{end}}>一键更新到 v{{.Version}}</button></form>{{end}}{{end}}
{{if .Enabled}}<div class="updsec"><h3>下载代理</h3><div class="muted small">只用于服务端更新（GitHub API、清单、程序），不影响 Bark 等其他请求。优先级：这里的设置 &gt; 环境变量 HUIJIAN_SERVER_UPDATE_PROXY &gt; HTTPS_PROXY / HTTP_PROXY。</div>
<form class="updform" method="post" action="/update/proxy"><input class="in mono" name="proxy" placeholder="http://127.0.0.1:7890 或 socks5://127.0.0.1:1080" autocomplete="off" spellcheck="false"><button class="btn sm">保存</button>{{if .PageProxy}}<button class="btn sm" name="clear" value="1">清除</button>{{end}}<span class="muted small">含密码时会保存在数据库和备份里</span></form></div>
<div class="updsec"><h3>手动上传</h3><div class="muted small">服务器下载不了 GitHub 时，在别的电脑上从发布页下载本平台（{{.Platform}}）的程序和 update-server.json，在这里上传。签名校验和一键更新完全一样。</div>
<form class="updform" method="post" action="/update/upload" enctype="multipart/form-data" data-confirm="上传并更新？校验通过后会先备份数据库，然后服务重启约半分钟。">
<label class="small muted">update-server.json <input type="file" name="manifest" accept=".json,application/json" required></label>
<label class="small muted">程序文件 <input type="file" name="file" required></label>
<button class="btn sm"{{if .Applying}} disabled{{end}}>上传并更新</button></form></div>{{end}}
</div></div>{{end}}

<div class="card"><div class="card-h"><h2>客户端更新</h2><span class="aside">客户端检测到新版本后会提示「更新并重启」</span></div>
<table class="tbl"><tr><th>平台</th><th>版本</th><th>大小</th><th>发布时间</th><th>说明</th><th class="r"></th></tr>
{{range $i, $r := .Releases}}<tr><td class="mono">{{$r.Platform}}</td><td><b>{{$r.Version}}</b> <span class="muted small mono">build {{$r.Build}}</span></td>
<td class="muted">{{size $r.Size}}</td><td class="muted" title="{{full $r.Created}}">{{rel $r.Created}}</td>
<td class="muted small">{{$r.Notes}}</td>
<td class="r"><form class="inline" method="post" action="/releases/{{$r.ID}}/delete" data-confirm="删除 {{$r.Platform}} {{$r.Version}}？已经更新的客户端不受影响。"><button class="btn sm danger">删除</button></form></td></tr>
{{else}}<tr><td colspan="6"><div class="empty"><div class="big">还没有发布过客户端</div>在开发机上执行 <code>mac/release.sh</code> 打包、签名并上传。</div></td></tr>{{end}}
</table></div>

{{with .Storage}}<div class="card"><div class="card-h"><h2>存储与备份</h2><span class="aside">路径在配置文件 / .env 里修改：HUIJIAN_DATA、HUIJIAN_FILES、HUIJIAN_BACKUP_DIR</span>
<form class="inline" method="post" action="/backup/run" style="margin-left:auto"><button class="btn sm"{{if or .Running (not .BackupOn)}} disabled{{end}}>{{if .Running}}备份中…{{else}}立即备份{{end}}</button></form></div><div class="card-b">
<dl class="kv">
<dt>数据库</dt><dd><span class="mono">{{.DataDir}}</span> · {{size .DBSize}}</dd>
<dt>附件目录</dt><dd><span class="mono">{{.FilesDir}}</span>{{if .FilesOK}} · {{.FilesCount}} 个文件，{{size .FilesSize}}{{if ge .FilesFree 0}}，剩余 {{size .FilesFree}}{{end}}{{else}}<br><span class="chip bad">不可用</span> <span class="small">{{.FilesError}}</span>{{end}}
{{if .Pending}}<br><span class="chip warn">{{.Pending}} 个附件暂存在本地</span> <span class="small muted">附件目录恢复后自动搬回</span>{{end}}
{{if .Legacy}}<br><span class="small muted">另有 {{.Legacy}} 个旧版本附件在 数据目录/blobs，照常可用</span>{{end}}</dd>
<dt>备份目录</dt><dd>{{if .BackupOn}}<span class="mono">{{.BackupDir}}</span>{{if .BackupOK}}{{if ge .BackupFree 0}} · 剩余 {{size .BackupFree}}{{end}}{{else}}<br><span class="chip bad">不可用</span> <span class="small">{{.BackupError}}</span>{{end}}{{else}}<span class="muted">已关闭</span>{{end}}</dd>
{{if .BackupOn}}<dt>备份计划</dt><dd>每天 {{.BackupAt}}，保留 {{.BackupKeep}} 份数据库快照；{{if .BackupFiles}}镜像附件{{else}}不镜像附件（与附件目录在同一块磁盘）{{end}} · 下次 {{full .Next}}</dd>{{end}}
<dt>上次备份</dt><dd>{{with .Last}}{{if .OK}}<span class="chip ok">成功</span>{{else}}<span class="chip bad">失败</span>{{end}} <span title="{{full .At}}">{{rel .At}}</span> · {{.Reason}}{{if .OK}} · 快照 <span class="mono">{{.DB}}</span>（{{size .DBSize}}）{{if .Files}} · 新增附件 {{.Copied}} 个{{end}} · 用时 {{printf "%.1f" .Seconds}}s{{end}}
{{if .Error}}<br><span class="small">{{.Error}}</span>{{end}}{{if .Warning}}<br><span class="small">⚠️ {{.Warning}}</span>{{end}}{{else}}<span class="muted">还没有备份过</span>{{end}}</dd>
</dl>
<p class="muted small" style="margin:12px 0 0">换服务器：复制配置文件，在新服务器上执行 <code>huijian restore &lt;备份目录&gt;</code>（docker：<code>docker compose run --rm --entrypoint huijian huijian restore /backup</code>）。文件统计每 5 分钟更新，<a href="/settings?fresh=1">立即刷新</a>。</p>
</div></div>{{end}}

<div class="card"><div class="card-h"><h2>服务信息</h2></div><div class="card-b">
<dl class="kv"><dt>版本</dt><dd>v{{.Version}}</dd>
<dt>已运行</dt><dd>{{.Uptime}}（启动于 {{full .Started}}）</dd>
<dt>公网地址</dt><dd class="mono">{{.PublicURL}}</dd>
<dt>内网地址</dt><dd class="mono">http://{{.PubAddr}}</dd>
<dt>管理后台</dt><dd class="mono">{{.AdminURL}}（仅内网）</dd>
{{if .Storage.ConfigFile}}<dt>配置文件</dt><dd class="mono">{{.Storage.ConfigFile}}</dd>{{end}}
<dt>时区</dt><dd>{{.Storage.ServerTZ}}</dd></dl>
</div></div>
{{template "bottom" .}}{{end}}
`
