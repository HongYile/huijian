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
.cols2{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:14px}
.chart.dense{gap:3px}.chart.dense .bar{max-width:18px}.chart.dense .lb{overflow:visible;height:14px;line-height:14px}
.chart.cm .bar{background:#8758BF}.chart.cn .bar{background:var(--ok)}
.chart .bar.zero,.chart.cm .bar.zero,.chart.cn .bar.zero{background:var(--surface2)}
.tbl .num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
.tbl .nowrap{white-space:nowrap}
.tblwrap{overflow-x:auto}
@media (max-width:980px){.cols2{grid-template-columns:1fr}}
.newcodes{margin-top:12px;display:flex;flex-wrap:wrap;gap:8px 14px;align-items:center}
.newcodes .keyline{display:inline-flex;gap:6px;align-items:center;margin:0}
.seg-form{gap:8px 18px}
</style>{{end}}`

const adminIcons = `
{{/* 回笺图标简化版（design/icon/make.py 的 svg(theme, simple=True)），颜色随页面亮 / 暗主题切换（.logo 的 --lg-* 变量） */}}
{{define "i-logo"}}<svg xmlns="http://www.w3.org/2000/svg" aria-hidden="true" viewBox="0 0 1024 1024"><rect width="1024" height="1024" style="fill:var(--lg-bg)"/><g transform="translate(512 512) scale(1.1200) translate(-534 -470)"><rect x="476" y="404" width="420" height="304" rx="46" stroke-width="26" style="fill:var(--lg-env);stroke:var(--lg-line)"/><polyline points="500,446 686,572 872,446" fill="none" style="stroke:var(--lg-flap)" stroke-width="30" stroke-linecap="round" stroke-linejoin="round"/><path d="M 118 566 C 130 330, 500.5 125.1, 627.0 317.2 L 578.6 349.1 C 474.1 190.5, 190 360, 118 566 Z" style="fill:var(--lg-arrow)"/><path d="M 660.0 420.0 L 557.7 362.9 L 647.9 303.4 Z" stroke-width="14" stroke-linejoin="round" paint-order="stroke" style="fill:var(--lg-arrow);stroke:var(--lg-bg)"/><line x1="812" y1="352" x2="784" y2="306" style="stroke:var(--lg-spark)" stroke-width="26" stroke-linecap="round"/><line x1="862" y1="334" x2="862" y2="272" style="stroke:var(--lg-spark)" stroke-width="26" stroke-linecap="round"/><line x1="912" y1="352" x2="940" y2="306" style="stroke:var(--lg-spark)" stroke-width="26" stroke-linecap="round"/></g></svg>{{end}}
{{define "i-overview"}}<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="7" height="9" rx="1.5"/><rect x="14" y="3" width="7" height="5" rx="1.5"/><rect x="14" y="12" width="7" height="9" rx="1.5"/><rect x="3" y="16" width="7" height="5" rx="1.5"/></svg>{{end}}
{{define "i-messages"}}<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M22 12h-6l-2 3h-4l-2-3H2"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/></svg>{{end}}
{{define "i-users"}}<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="9" cy="8" r="3.5"/><path d="M2.5 20a6.5 6.5 0 0 1 13 0"/><path d="M16 4.6a3.5 3.5 0 0 1 0 6.8M18.5 14.2A6.5 6.5 0 0 1 21.5 20"/></svg>{{end}}
{{define "i-active"}}<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M22 12h-4l-3 8L9 4l-3 8H2"/></svg>{{end}}
{{define "i-db"}}<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v14c0 1.7 3.6 3 8 3s8-1.3 8-3V5"/><path d="M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/></svg>{{end}}
{{define "i-ticket"}}<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v3a2 2 0 0 0 0 4v3a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-3a2 2 0 0 0 0-4z"/><path d="M14 5v2M14 11v2M14 17v2"/></svg>{{end}}
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
<a href="/accounts" class="{{if eq .Nav "accounts"}}on{{end}}">{{template "i-users"}}<span class="lb">账号</span></a>
<a href="/invites" class="{{if eq .Nav "invites"}}on{{end}}">{{template "i-ticket"}}<span class="lb">邀请码</span></a>
<a href="/settings" class="{{if eq .Nav "settings"}}on{{end}}">{{template "i-settings"}}<span class="lb">设置</span></a>
</nav>
<div class="foot"><span class="tx">回笺 v{{.Version}}</span></div>
</aside><main class="main"><div class="wrap">{{end}}

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
<div class="hint">管理后台只能在服务器上进入，回笺客户端不能登录后台。<br>
第一次登录或忘记令牌：在服务器上执行 <code>docker exec huijian huijian admin-link</code>，会给出一个一次性登录链接。</div>
</div></div></body></html>{{end}}

{{define "overview"}}{{template "top" .}}
<div class="head"><div><h1>概览</h1><div class="sub">全服务器的统计。只有计数，不含任何账号的消息内容、key 或设备信息。</div></div></div>

<div class="grid4">
<div class="card stat"><div class="k"><span class="ti" style="--c:var(--accent)">{{template "i-users"}}</span>账号</div><div class="v">{{.Accounts.Total}}</div><div class="d">已加密 {{.Accounts.Encrypted}}{{if .Accounts.Waiting}} · 未加密旧账号 {{.Accounts.Waiting}}{{end}}{{if .Accounts.Disabled}} · 停用 {{.Accounts.Disabled}}{{end}}</div>
<div class="d"><a href="/invites">邀请码</a> 已发 {{.InvIssued}} · 已用 {{.InvUsed}}{{if eq .Mode "open"}} · 开放注册{{else if eq .Mode "closed"}} · 注册已关闭{{end}}</div></div>
<div class="card stat"><div class="k"><span class="ti" style="--c:var(--ok)">{{template "i-active"}}</span>今天活跃</div><div class="v">{{.Active1}}</div><div class="d">7 天 {{.Active7}} · 30 天 {{.Active30}}</div></div>
<div class="card stat"><div class="k"><span class="ti" style="--c:var(--p4)">{{template "i-devices"}}</span>设备</div><div class="v">{{.Devices}}<small> 台</small></div><div class="d">在线 {{.Online}}{{if .Outdated}} · 较旧 {{.Outdated}}{{end}}</div></div>
<div class="card stat"><div class="k"><span class="ti" style="--c:#8758BF">{{template "i-db"}}</span>存储</div><div class="v">{{size .Storage.DBSize}}<small> + {{size .AttBytes}}</small></div><div class="d">数据库 + 附件 {{.AttCount}} 个</div></div>
</div>

<div class="card"><div class="card-h"><h2>近 30 天每日活跃账号</h2><span class="aside">有设备登录或访问过接口的账号</span></div><div class="card-b">
<div class="chart dense">{{range .Days}}<div class="col" title="{{.Day}}：{{.Active}} 个账号"><span class="n">{{if .Tick}}{{if .Active}}{{.Active}}{{end}}{{end}}</span><div class="bar{{if not .Active}} zero{{end}}" style="height:{{pct .PctActive}}%"></div><span class="lb">{{if .Tick}}{{.Label}}{{end}}</span></div>{{end}}</div>
</div></div>

<div class="cols2">
<div class="card"><div class="card-h"><h2>每日新消息</h2><span class="aside">全服务器合计 · 30 天 {{.Msgs30}} 条</span></div><div class="card-b">
<div class="chart dense cm">{{range .Days}}<div class="col" title="{{.Day}}：{{.Messages}} 条，附件 {{size .AttBytes}}"><span class="n">{{if .Tick10}}{{if .Messages}}{{.Messages}}{{end}}{{end}}</span><div class="bar{{if not .Messages}} zero{{end}}" style="height:{{pct .PctMessages}}%"></div><span class="lb">{{if .Tick10}}{{.Label}}{{end}}</span></div>{{end}}</div>
</div></div>
<div class="card"><div class="card-h"><h2>每日新账号</h2><span class="aside">30 天 {{.New30}} 个</span></div><div class="card-b">
<div class="chart dense cn">{{range .Days}}<div class="col" title="{{.Day}}：{{.NewAccounts}} 个"><span class="n">{{if .NewAccounts}}{{.NewAccounts}}{{end}}</span><div class="bar{{if not .NewAccounts}} zero{{end}}" style="height:{{pct .PctAccounts}}%"></div><span class="lb">{{if .Tick10}}{{.Label}}{{end}}</span></div>{{end}}</div>
</div></div>
</div>

<div class="cols2">
<div class="card"><div class="card-h"><h2>设备平台与版本</h2><span class="aside">在用设备 {{.Devices}} 台{{if .Outdated}}，较旧 {{.Outdated}} 台{{end}}</span></div>
<table class="tbl"><tr><th>平台</th><th class="num">设备</th><th class="num">较旧</th><th>版本</th></tr>
{{range .Platforms}}<tr><td class="mono">{{.Platform}}</td><td class="num">{{.Total}}</td><td class="num">{{if .Outdated}}<span class="chip warn">{{.Outdated}}</span>{{else}}<span class="muted">0</span>{{end}}</td>
<td>{{range .Versions}}<span class="chip small">{{.Version}} × {{.Count}}</span> {{end}}</td></tr>
{{else}}<tr><td colspan="4"><div class="empty"><div class="big">还没有设备</div>用户在回笺客户端登录后出现在这里。</div></td></tr>{{end}}
</table>
<p class="muted small" style="margin:0;padding:10px 18px 14px">较旧：低于这个平台在「设置 → 客户端更新」里发布的最新版本，或没有上报版本号的旧客户端。</p></div>

{{with .Storage}}<div class="card"><div class="card-h"><h2>存储与备份</h2><a class="small" href="/settings">设置 →</a></div><div class="card-b">
<dl class="kv"><dt>数据库</dt><dd>{{size .DBSize}}</dd>
<dt>附件</dt><dd>{{$.AttCount}} 个，{{size $.AttBytes}}{{if .FilesOK}}<span class="muted small">（附件目录 {{.FilesCount}} 个文件，{{size .FilesSize}}{{if ge .FilesFree 0}}，剩余 {{size .FilesFree}}{{end}}）</span>{{else}} <span class="chip bad">附件目录不可用</span>{{end}}
{{if .Pending}}<br><span class="chip warn">{{.Pending}} 个附件暂存在本地</span>{{end}}</dd>
<dt>备份</dt><dd>{{if not .BackupOn}}<span class="muted">已关闭</span>{{else}}{{if not .BackupOK}}<span class="chip bad">备份目录不可用</span> {{end}}每天 {{.BackupAt}} · 下次 {{full .Next}}{{end}}</dd>
<dt>上次备份</dt><dd>{{if .Running}}<span class="chip acc">备份中</span>{{else}}{{with .Last}}{{if .OK}}<span class="chip ok">成功</span>{{else}}<span class="chip bad">失败</span>{{end}} <span title="{{full .At}}">{{rel .At}}</span>{{if .OK}} · {{size .DBSize}}{{end}}{{if .Error}}<br><span class="small">{{.Error}}</span>{{end}}{{else}}<span class="muted">还没有备份过</span>{{end}}{{end}}</dd></dl>
</div></div>{{end}}
</div>
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
<li><b>只能在服务器上进入</b>：任何账号都不能从回笺客户端进入管理后台。用管理令牌（数据目录里的 <code>admin.token</code>）登录，或者在服务器上执行下面的命令，得到一个 5 分钟有效的一次性登录链接：</li></ol>
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
