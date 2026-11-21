# Agent 双向通信（设计草案，2026-11-20 用户已确认主要决定）

目标：让跑在自己机器上的 agent（Claude Code、DeepSeek、Hermes 之类，或者任何脚本）把消息发到用户手机，用户直接在回笺里回复，回复送回**发这条消息的那个 agent 会话**，agent 收到后继续干活或改主意。

回复等于远程指挥 agent，所以安全要求比普通推送高：**服务器既不能读回复，也不能伪造回复，也不能把回复送错会话。**

## 1. 范围

做：
- 同一账号内部：agent → 自己的设备，自己的设备 → 自己的 agent。
- 一个核心实现：`huijian agent …` 命令行子命令（同一个 Go 二进制）。
- skill 和 MCP 都只是薄壳：
  - skill 教 agent 调命令行；
  - `huijian mcp` 是 stdio MCP 服务，把命令行的能力暴露成工具。

不做：
- 用户之间互发、agent 之间互发（避免变成即时通信）。
- 回复里带附件（第一版只有文字）。

## 2. 名词

| 名词 | 说明 |
|---|---|
| Agent key | 账号下专门给 agent 用的 key，前缀 `AK_`。只能发加密消息、发起会话请求，不能读消息列表、不能管理账号。每个账号最多 10 把（0.11.0 起；之前 1 把），一般每台 agent 电脑一把（连接码兑换时新建、带名字），可以单独吊销 |
| 会话 | 一个 agent 进程（一个 MCP 进程或一次 `huijian agent` 登录）。登录时生成会话钥匙对，经手机批准后拿到会话令牌 `ST_` |
| 回复 | 用户对某条会话消息的回复，加密后暂存在服务器，等 agent 取走 |

## 3. 内测额度

| 项目 | 内测 | 以后付费版可以放宽 |
|---|---|---|
| Agent key | 每账号 10 把 | 更多 |
| 同时在线的会话 | 全账号 3 个 | 更多 |
| 回复在服务器保留 | 3 天（agent 确认取走后立即删除） | 更久 |
| 单条回复 | 16 KB 文字 | — |

差异只按数量划分，不靠「消息混用」之类降低隔离：回复送错 agent 是安全事故。

## 4. 加密和身份

所有账号都加密，没有不加密的账号：0.8.0 起首次客户端登录就自动开启，不能关闭。账号还没有钥匙（新建后没有客户端登录过）时，Agent key 的请求返回 409「请先在任一设备登录回笺」。

### 4.0 连接码（0.11.0，feature `agent.connect`）

用户在设备上点「连接 agent」生成 8 位一次性连接码（Crockford Base32，40 位随机，显示为 XXXX-XXXX，10 分钟有效），在 agent 电脑上运行 `huijian agent setup -u <服务器> <连接码>`：用连接码换一把这台电脑专用的 Agent key（带名字，存在 `~/.huijian/agent/<槽位>/agent_key`），然后照常走 4.1 的登录（仍要在设备上核对 6 位核对码）。连接码只是代替「复制 Agent key」，不跳过核对：服务器拿到连接码也只能换 key，冒充不了账号公钥。服务器只存连接码的哈希；兑换接口按 IP 限速，失败统一 403 并延迟。

setup 接着找出本机装的 agent（Claude Code、Codex、Cursor、DeepSeek Harness、Hermes、Qwen Code、Pi），把 `huijian mcp` 写进它们的配置、装上 skill；写之前备份为 `<文件>.bak-huijian`，写入内容带标记，`huijian agent setup -remove` 原样撤销并结束会话；`huijian agent status` 列出接入情况。

### 4.1 登录（手机批准 + 6 位核对码）

沿用设备批准的「先承诺、后揭晓」流程（[api.md](api.md)「设备批准的核对码」），把「新设备」换成「agent 会话」：

1. agent 生成会话钥匙对（X25519）和随机 `nb`，用 Agent key 调 `POST /v1/agent/sessions {name, pub, commit}`。`commit` 的算法和设备批准一样，但用 agent 专用前缀 `huijian agent v1 commit`，账号公钥取 `GET /v1/agent/info` 返回的值（或 agent 以前钉住的值）。
2. 已解锁的设备收到请求（长轮询 `kind: "agent"`），出 `na`。agent 揭晓 `nb`。
3. 两边都显示 6 位核对码，前缀改为 `huijian agent v1 sas`。终端里打印，手机上显示。用户对上后在手机上点「一致，批准」。核对码要等手机点了「批准」（发出 challenge）才算得出来，所以终端在这之前只提示「去设备上点批准」（2026-11-21 实测：agent 看不到核对码会以为卡住了）。
4. 批准设备写一份**会话证明** `hja1`：
   - 内容：会话 id、会话公钥、名称、批准时间；
   - 加密：AES-256-GCM，密钥 = HKDF-SHA256(账号私钥, info=`huijian agent v1 attest`)；
   - 只有持有账号私钥的设备能写、能验。服务器不能伪造，也不能偷换会话公钥。
5. agent 拿到会话令牌 `ST_`，同时钉住账号公钥（存在 `~/.huijian/agent/`，权限 600）。

会话令牌一直有效（已确认），不会因为长期不在线而失效，直到用户在设备上「结束会话」或吊销 Agent key。agent 重启后用保存的令牌和会话私钥直接恢复，不用重新批准。

### 4.2 两个方向都用 HPKE Auth 模式

HPKE Auth 模式（RFC 9180 `mode_auth`）在加密的同时证明「是谁加密的」，所以服务器两头都伪造不了：

| 方向 | 发送方钥匙 | 接收方公钥 | 接收方核对 |
|---|---|---|---|
| agent → 设备 | 会话私钥 | 账号公钥 | 发送方公钥必须等于会话证明里的会话公钥 |
| 设备 → agent | 账号私钥 | 会话公钥（取自会话证明） | 发送方公钥必须等于 agent 钉住的账号公钥 |

- 信封前缀用 `hje2`，和普通加密消息 `hje1` 区分。
- 明文里带 `session_id`、`msg_id`（回复时为被回复的消息 id）、`seq`、时间。agent 记录已处理的 `seq`，重放的回复丢弃。
- agent 消息可以带快捷回复选项 `choices`（最多 4 个，每个最长 20 字），和正文一起加密。
- 客户端：点选项只是选中（再点取消），和补充文字一起点「发送」才发出（2026-11-21 用户要求：先填好再统一发送）。回复正文：只有选项时就是选项；只有文字时就是文字；都有时第一行是选项、换行后是补充。协议不变，仍是一段 `text`。
- `ask` 拿到第一条回复就结束，之后的回复要 agent 再来取：MCP `ask` 的结果以「用户回复：」开头并附提示「继续做之前、结束之前用 check_replies 看看」；客户端在回复已被 agent 收到后提示「agent 已拿到你的回复，现在没在等你」。
- 实现前先确认各端的 HPKE 库支持 Auth 模式：
  - Go 和 Rust 核心是自己写的 HPKE，补 AuthEncap 工作量小；
  - CryptoKit 原生支持。

### 4.3 服务器知道什么

服务器知道：哪个会话、什么时候发了多少条、回复了没有、大小。

服务器不知道：消息和回复的内容。

## 5. 路由

- 每条会话消息带明文的 `session_id`（路由用）。
- 用户回复哪条消息，回复就进那条消息的会话。客户端用会话证明再核对一次：会话已结束或证明对不上时，不让回复。
- Agent key 只决定账号和权限，不参与路由。多个 agent 共用一把 Agent key 也不会串。
- 会话离线时回复照样暂存，agent 重连后取走；超过 3 天自动删除，发回复的设备会显示「已过期，agent 没有取走」。

### 5.1 送达回执（已确认要做）

回复的人要确切知道 agent 收到了。每条回复有三个状态：

| 状态 | 什么时候 | 谁能证明 |
|---|---|---|
| 已发出 | 服务器接收了回复 | 服务器 |
| agent 已收到 | agent 取走并解开回复后，发回一张**回执** | agent（端到端证明） |
| 已过期 | 3 天内 agent 没取走 | 服务器 |

- 回执 = agent 用会话私钥、以 HPKE Auth 模式加密给账号公钥的一小段内容：`{type: "receipt", reply_id, seq, received_at}`。设备核对发送方是这个会话后，才显示「agent 已收到」。服务器能扣住回执，但伪造不了。
- agent 取回复时自动发回执（命令行 `replies`、`ask` 和 MCP 都自动发，不需要 agent 自己写）。
- 回执到达后，同账号所有设备的回复气泡变成「✓✓ agent 已收到 · 时间」。发回复的那台设备如果已经离开这个页面，弹一条**静默提示**「家里 Claude Code 已收到你的回复」：不响铃，在 App 内弹提示条，在后台时发静默通知。
- 回复 2 分钟后还是「已发出」，而会话不在线：显示「agent 目前不在线，回复会等它上线后送达」。

## 6. 接口（草案）

| 请求 | 认证 | 说明 |
|---|---|---|
| `GET /v1/agent/info` | Agent key | 账号公钥（agent 首次登录时钉住）、额度 |
| `POST /v1/agent/sessions` | Agent key | 发起会话请求：`{name, pub, commit}` → `{session_id}` |
| `GET /v1/agent/sessions/{id}` | Agent key + 会话 id | 等批准：`{state, challenge}`；批准后返回一次 `token` |
| `POST /v1/agent/sessions/{id}/reveal` | 同上 | `{nonce}` |
| `POST /v1/agent/push` | `ST_` | 发消息：同 `/message/push` 的参数，但 `e2e` 必须是 `hje2`，可带 `ask: true`（客户端突出显示「等你回复」） |
| `GET /v1/agent/replies?wait=<秒>` | `ST_` | 长轮询取回复 → `[{reply_id, msg_id, e2e}]` |
| `POST /v1/agent/replies/ack` | `ST_` | `{receipts: [{reply_id, e2e}]}`：确认收到并附上加密回执，服务器删除回复正文、保留回执（3 天），并通知设备（长轮询 `kind: "agent"`） |
| `GET /v1/agent/sessions` | 设备 | 列出本账号的会话和请求（含 `hja1` 证明、在线状态） |
| `POST /v1/agent/sessions/{id}/challenge`、`/approve`、`/deny` | 设备 | 批准流程，`approve` 带 `hja1` |
| `DELETE /v1/agent/sessions/{id}` | 设备 | 结束会话：令牌作废，未取走的回复删除 |
| `POST /v1/agent/replies` | 设备 | 回复：`{msg_id, e2e}`，服务器按 `msg_id` 找到会话 → `{reply_id}` |
| `GET /v1/agent/replies/status?msg_id=` | 设备 | 某条消息下各回复的状态和回执 |

「在线」= 90 秒内有过 `replies` 长轮询。同时在线超过 3 个时，新会话的长轮询返回 429，提示到设备上结束旧会话。

## 7. 命令行、skill、MCP

```bash
export HUIJIAN_URL=https://push.example.com
export HUIJIAN_AGENT_KEY=AK_xxx
huijian agent login -name "家里 Claude Code"   # 手机上点「批准」后打印 6 位核对码，核对一致再确认
huijian agent send -p 3 "数据清洗完成"          # 发会话消息（可被回复）
huijian agent ask -timeout 30m -choice 删 -choice 保留 "要不要删掉 3 个异常样本？"   # 发出并等回复（可带快捷按钮），回复打印到标准输出
huijian agent replies -wait 60                  # 取回复（JSON 每行一条）
huijian agent logout
huijian mcp                                     # stdio MCP 服务
```

MCP 工具：
- `notify(title, body, priority)`：发消息，不等回复；
- `ask(question, choices?, timeout)`：发出并等待回复，返回「用户回复：<文字>」加补充提示，或「超时」；
- `check_replies()`：取未处理的回复（ask 超时后才回的、ask 之后用户又补充的）。

skill：`skills/huijian` 里加一节「问用户、等回复」，教 agent 用 `huijian agent ask`。只有确实需要人决定时才用，不要把普通进度做成提问。

会话状态（会话私钥、令牌、钉住的账号公钥、消息序号、处理过的回复）存在 `~/.huijian/agent/<槽位>/session.json`（目录 700、文件 600）；槽位用 `-s` 或环境变量 `HUIJIAN_AGENT_SESSION` 指定，默认 `default`。`ask` 超时退出码 3；等待期间收到的别的消息的回复留到下次 `replies` / `check_replies` 交出。MCP 的工具调用一个一个执行（`ask` 等待期间别的调用排队）。

## 8. 客户端

Mac、iPhone、安卓同步做：
- 消息：会话消息显示 agent 名称和「回复」按钮；`ask` 消息显示「等你回复」，有快捷选项时显示成可选中的按钮，选好、写好补充后点「发送」一起发出；
- 回复框：纯文字，发出后显示「已发出 / ✓✓ agent 已收到 / 已过期」，见 5.1；
- 设置 → Pushkey 页（Agent key 和 pushkey 一样是交给程序的钥匙，放在一起；登录请求显示在这一页最上方）：
  - Agent key 新建、复制、吊销；
  - 会话列表（名称、上次在线、批准时间），可以结束；
  - 批准请求（显示核对码，和设备批准同一套界面）。

## 9. 实施步骤

1. 先确认本文档。
2. HPKE Auth 模式：Go、Rust 核心、测试向量。
3. 服务端接口、额度、3 天清理，测试。
4. 命令行 `huijian agent` 和 skill，在自建服务器上实测。
5. Mac、iPhone、安卓的回复和批准界面。
6. `huijian mcp`，用 Claude Code 实测 `ask`。

## 10. 已确认（2026-11-20）

1. 会话令牌一直有效，靠手动结束会话或吊销 Agent key。
2. 做快捷回复按钮。
3. 做送达回执：agent 收到后回复的人能看到提示（5.1）。
4. 所有账号都加密，没有不加密的账号。

## 11. 格式与接口细节（2026-11-20 定稿，实现以此为准）

### 11.1 钥匙和令牌

| 名称 | 格式 | 说明 |
|---|---|---|
| Agent key | `AK_` + 32 位小写十六进制 | 在设备上新建（`POST /v1/agent/keys`），明文只返回这一次，服务器只存 SHA-256。吊销后它登录的所有会话一起结束 |
| 会话令牌 | `ST_` + 32 位小写十六进制 | 批准后由服务器生成，agent 取走一次后服务器只留哈希 |
| 会话钥匙对 | X25519 | agent 本机生成，私钥只在 `~/.huijian/agent/<会话名>/`（权限 600） |

### 11.2 密码学格式（都在共用核心 / Go 里实现，各端不自己拼）

| 用途 | 格式 | 算法 |
|---|---|---|
| 登录承诺 | `commit = SHA-256("huijian agent v1 commit" ‖ 会话公钥 ‖ 账号公钥 ‖ nb ‖ SHA-256(会话名称))` | 名称也在承诺里：服务器改不了设备上显示、写进证明的名称 |
| 核对码 | `SHA-256("huijian agent v1 sas" ‖ 会话公钥 ‖ 账号公钥 ‖ na ‖ nb)` 前 4 字节（大端）mod 1000000，6 位 | 同上 |
| 会话证明 `hja1` | `hja1.<base64url(nonce‖密文)>`，AES-256-GCM，附加数据 `hja1`，钥匙 `HKDF-SHA256(salt="huijian agent v1 attest", ikm=账号私钥)`，明文 `{"session_id","pub","name","approved_at"}` | 只有持有账号私钥的设备能写、能验 |
| agent → 账号 `hje2` | `hje2.<kid>.<session_id>.<base64url(enc‖ct)>`；HPKE auth（发送方 = 会话私钥，接收方 = 账号公钥），info `huijian agent v1 message`，附加数据 `hje2.<kid>.<session_id>` | 消息和回执都用它 |
| 消息载荷 | `{"v":1,"kind":"message","text","desp","ask":bool,"choices":[…],"seq":n,"sent_at":秒}` | `choices` 最多 4 个、每个最长 20 字 |
| 回执载荷 | `{"v":1,"kind":"receipt","reply_id":n,"n":"<回复里的随机数>","received_at":秒}` | |
| 设备 → agent `hjq1` | `hjq1.<session_id>.<base64url(enc‖ct)>`；HPKE auth（发送方 = 账号私钥，接收方 = 会话公钥，取自会话证明），info `huijian agent v1 reply`，附加数据 `hjq1.<session_id>.<msg_id>` | |
| 回复载荷 | `{"v":1,"re_seq":n,"text","n":"<16 字节随机数 base64url>","sent_at":秒,"device":"<设备名>"}` | `re_seq` = 被回复消息载荷里的 `seq`（设备解开消息得到）：agent 只认 `re_seq` 和自己记下的「消息 id → seq」都对得上的回复，服务器挪不了「回的是哪个问题」。文字最长 16 KB；agent 记下处理过的 `n`（保留 3 天），`sent_at` 早于 3 天或在未来的拒绝 |
| 回复副本 | 普通 `hje1` 信封（加密给账号公钥），载荷同上 | 同账号其他设备靠它显示回复内容（`hjq1` 只有 agent 解得开） |

登录与收发的几条规则（2026-11-20 审查后补充）：
- agent 揭晓 nb 之后，challenge 再变就放弃这次登录（重新 `login`：新会话钥匙、新 nb）；服务端在揭晓后收到同一台设备的新 challenge 时把请求作废（409）。否则服务器知道 nb 后可以挑 na 凑出想要的核对码。
- 会话令牌在批准后 10 分钟内只能取走一次（比较后清空）；没取走的由定时清理删掉。
- agent 收到回复：先解开、核对、存进本地待交付列表并存盘，再发回执；回执没送到时下次照发，内容不重复交出。
- 一个会话槽位同一时间只能被一个进程使用（文件锁）；同时跑多个 agent 用不同槽位、各自登录。幂等键带随机数；服务端遇到同一幂等键、不同密文时返回 409。
- 设备只信任**当前账号钥匙**写的会话证明来回复；重置加密前的证明只用来显示历史消息。
- 回复副本（hje1）任何人都能用账号公钥写：副本只用来显示「回复过什么」，✓✓ 只看 agent 用会话私钥写的回执（核对 reply_id 和 n）。

共用核心（`core/src/agent.rs`，JSON 操作见 `api.rs`）给设备一侧提供：

| 操作 | 参数 → 结果 |
|---|---|
| `agent_commit` | `{pub, account, nonce, name}` → `{commit}`：设备用**自己私钥算出的**账号公钥核对 agent 揭晓的 nb |
| `agent_sas` | `{pub, account, na, nb}` → `{code}` |
| `agent_attest_seal` | `{sk, session_id, pub, name, approved_at}` → `{attest}` |
| `agent_attest_open` | `{sk, attest, session_id, pub}` → `{name, approved_at}`；证明里的会话 id、公钥对不上时 `format` |
| `agent_open` | `{keys:[账号私钥…], session_pub, session_id, envelope}` → `{payload, kid}`：消息和回执都用它 |
| `agent_reply_seal` | `{sk, session_pub, session_id, msg_id, payload}` → `{envelope, copy}` |

跨平台向量：`server/testdata/agent_vectors.json`（Go 生成，`core/tests/agent.rs` 逐字节核对）。

设备收到 `hje2` 消息：先用会话证明拿到会话公钥（证明解不开、`session_id` 对不上 → 显示「来源无法核实」，不显示回复按钮），再用 auth 模式解开；发送方核对失败同样当作「来源无法核实」。

### 11.3 接口

认证：`AK` = `Authorization: Bearer AK_…`；`ST` = `Authorization: Bearer ST_…`；`设备` = 现有设备 token。

| 请求 | 认证 | 说明 |
|---|---|---|
| `POST /v1/agent/keys` | 设备 | 新建 Agent key → `{"id","key","prefix","created_at"}`；每账号最多 10 把，满了 409 |
| `POST /v1/agent/connect-codes` | 设备 | 0.11.0：生成连接码 → `{"code":"XXXX-XXXX","expires_at","expires_in":600}`；同一设备重新生成时旧码作废；key 已满或账号没有钥匙时 409 |
| `POST /v1/agent/connect` | 无（按 IP 限速） | 0.11.0：`{code, name}` → `{"id","key","prefix","name"}`，用连接码换一把带名字的 Agent key；码不对 / 过期 / 用过统一 403（延迟 0.5 秒） |
| `GET /v1/agent/keys` | 设备 | `{"keys":[{"id","prefix","created_at","last_used"}]}` |
| `DELETE /v1/agent/keys/{id}` | 设备 | 吊销，它登录的会话全部结束 |
| `GET /v1/agent/info` | AK | `{"account_pub","kid","limits":{…}}`；账号还没有钥匙时 409 |
| `POST /v1/agent/sessions` | AK | `{name, pub, commit}` → `{"session_id"}`；等待批准的请求每账号最多 3 个，10 分钟没批准自动作废 |
| `GET /v1/agent/sessions/{id}` | AK | `{"state","challenge"}`；`state`：`pending` / `approved` / `denied` / `expired` / `ended`。批准后第一次查询带 `token`（只给一次） |
| `POST /v1/agent/sessions/{id}/reveal` | AK | `{nonce: nb}` |
| `GET /v1/agent/sessions` | 设备 | `{"sessions":[{"id","name","pub","state","commit","challenge","reveal","attest","created_at","approved_at","last_seen","online"}]}`（不含已作废超过 3 天的） |
| `POST /v1/agent/sessions/{id}/challenge` | 设备 | `{nonce: na}`；已被别的设备接手时 409 |
| `POST /v1/agent/sessions/{id}/approve` | 设备 | `{attest: hja1…}`；必须已揭晓 |
| `POST /v1/agent/sessions/{id}/deny` | 设备 | 拒绝 |
| `DELETE /v1/agent/sessions/{id}` | 设备 | 结束会话：令牌作废，未取走的回复删除 |
| `POST /v1/agent/push` | ST | `{e2e: hje2…, priority, topic, thread, ask, idem}` → `{"id"}`；`topic` 默认 `agent` |
| `GET /v1/agent/replies?wait=<秒>` | ST | 长轮询（最长 60 秒）→ `{"replies":[{"reply_id","msg_id","e2e","created_at"}]}`；同时算作在线 |
| `POST /v1/agent/replies/ack` | ST | `{receipts:[{reply_id, e2e: hje2 回执}]}`：服务器删掉回复密文、保存回执，通知设备 |
| `DELETE /v1/agent/session` | ST | agent 自己退出（等于结束会话） |
| `POST /v1/agent/replies` | 设备 | `{msg_id, e2e: hjq1…, copy: hje1…}` → `{"reply_id"}`；会话已结束时 409 |
| `GET /v1/agent/replies/status?msg_id=` | 设备 | `{"replies":[{"reply_id","state","created_at","received_at","copy","receipt","device"}]}`；`state`：`sent` / `received` / `expired` |

`GET /v1/messages` 里 agent 发来的消息多两个字段：`agent_session`（会话 id）、`ask`（布尔）。新的批准请求、回执、会话状态变化都记一条 `kind: "agent"` 的变更（`msg_id` 为 0），客户端收到后重新拉 `GET /v1/agent/sessions` 和正在看的消息的回复状态。

第一版 agent 消息只有文字（不带附件）；要发图表请照旧用 `huijian push`（不能回复）。
