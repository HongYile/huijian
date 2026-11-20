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
| Agent key | 账号下专门给 agent 用的 key，前缀 `AK_`。只能发加密消息、发起会话请求，不能读消息列表、不能管理账号。内测每个账号 1 把，可以给多个 agent 共用 |
| 会话 | 一个 agent 进程（一个 MCP 进程或一次 `huijian agent` 登录）。登录时生成会话钥匙对，经手机批准后拿到会话令牌 `ST_` |
| 回复 | 用户对某条会话消息的回复，加密后暂存在服务器，等 agent 取走 |

## 3. 内测额度

| 项目 | 内测 | 以后付费版可以放宽 |
|---|---|---|
| Agent key | 每账号 1 把 | 多把 |
| 同时在线的会话 | 全账号 3 个 | 更多 |
| 回复在服务器保留 | 3 天（agent 确认取走后立即删除） | 更久 |
| 单条回复 | 16 KB 文字 | — |

差异只按数量划分，不靠「消息混用」之类降低隔离：回复送错 agent 是安全事故。

## 4. 加密和身份

所有账号都加密，没有不加密的账号：0.8.0 起首次客户端登录就自动开启，不能关闭。账号还没有钥匙（新建后没有客户端登录过）时，Agent key 的请求返回 409「请先在任一设备登录回笺」。

### 4.1 登录（手机批准 + 6 位核对码）

沿用设备批准的「先承诺、后揭晓」流程（[api.md](api.md)「设备批准的核对码」），把「新设备」换成「agent 会话」：

1. agent 生成会话钥匙对（X25519）和随机 `nb`，用 Agent key 调 `POST /v1/agent/sessions {name, pub, commit}`。`commit` 的算法和设备批准一样，但用 agent 专用前缀 `huijian agent v1 commit`，账号公钥取 `GET /v1/agent/info` 返回的值（或 agent 以前钉住的值）。
2. 已解锁的设备收到请求（长轮询 `kind: "agent"`），出 `na`。agent 揭晓 `nb`。
3. 两边都显示 6 位核对码，前缀改为 `huijian agent v1 sas`。终端里打印，手机上显示。用户对上后在手机上点「批准」。
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
huijian agent login -name "家里 Claude Code"   # 打印 6 位核对码，等手机批准
huijian agent send -p 3 "数据清洗完成"          # 发会话消息（可被回复）
huijian agent ask -timeout 30m -choice 删 -choice 保留 "要不要删掉 3 个异常样本？"   # 发出并等回复（可带快捷按钮），回复打印到标准输出
huijian agent replies -wait 60                  # 取回复（JSON 每行一条）
huijian agent logout
huijian mcp                                     # stdio MCP 服务
```

MCP 工具：
- `notify(title, body, priority)`：发消息，不等回复；
- `ask(question, choices?, timeout)`：发出并等待回复，返回回复文字或「超时」；
- `check_replies()`：取未处理的回复。

skill：`skills/huijian` 里加一节「问用户、等回复」，教 agent 用 `huijian agent ask`。只有确实需要人决定时才用，不要把普通进度做成提问。

会话状态（会话私钥、令牌、钉住的账号公钥、已处理 seq）存在 `~/.huijian/agent/<会话名>/`，权限 600。

## 8. 客户端

Mac、iPhone、安卓同步做：
- 消息：会话消息显示 agent 名称和「回复」按钮；`ask` 消息显示「等你回复」，有快捷选项时显示成按钮，点一下即回复（iPhone、安卓的通知上也可以直接点）；
- 回复框：纯文字，发出后显示「已发出 / ✓✓ agent 已收到 / 已过期」，见 5.1；
- 设置 → Agent：
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
