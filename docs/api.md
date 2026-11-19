# API 参考

回笺有两个监听端口：

| 端口（默认） | 用途 | 暴露范围 |
|---|---|---|
| `8790` 公网 API | 发送消息、设备配对、拉取消息、下载附件 | 经 HTTPS 反向代理对公网开放 |
| `8791` 管理后台 | 网页管理界面 | **仅本机或内网**，不要经公网代理转发 |

## 1. 发送消息

`GET | POST /message/push`

兼容 [PushDeer](https://github.com/easychen/pushdeer) 的参数，旧脚本只需替换域名即可迁移。

| 参数 | 必填 | 说明 |
|---|---|---|
| `pushkey` | 是 | 接收方的 pushkey，多个用逗号分隔（≤20）；也可放在 `Authorization: Bearer PK_xxx` 头里 |
| `text` | 是* | 标题。带附件时可省略，自动用文件名 |
| `desp` | 否 | 正文，回笺 Markdown（标准 Markdown + 附件内嵌、进度条、提示框等扩展，见 [markdown.md](markdown.md)），≤64KB |
| `type` | 否 | `markdown`（默认）/ `text` / `image` |
| `priority` | 否 | 0–5，默认 3。见下表 |
| `topic` | 否 | 频道，默认 `default`，≤64 字节 |
| `thread` | 否 | 线程（例如一次训练的 run 名），客户端会把同一线程折叠显示 |
| `idem` | 否 | 幂等键（≤64 字节）。同一个幂等键重复发送只会生成一条消息。CLI 和 SDK 自动生成 |
| `file` | 否 | 附件，`multipart/form-data`，可重复多次（≤20 个，总大小默认 ≤512MB） |
| `e2e` | 否 | 端到端加密的信封 `hje1.…`（0.7.0 起，见下文「加密发送」）。带它时忽略 `text` / `desp` / `type` |

请求体支持 query string、`application/x-www-form-urlencoded`、`multipart/form-data`、`application/json`。

**加密发送**（0.7.0 起，功能 id `e2e`，设计见 [e2ee.md](e2ee.md)）：客户端 Pushkey 页可以复制「加密发送密钥」`PK_xxx.e2e.<公钥>`。`huijian push` 和 Python SDK 拿到这种密钥会在本机加密，服务器只收到：

- `pushkey`：`.e2e.` 之前的部分（整串原样传也可以，服务器只认前半段）；
- `e2e`：信封 `hje1.<kid>.<base64url(enc‖ct)>`，HPKE（RFC 9180 base 模式，DHKEM(X25519, HKDF-SHA256) + HKDF-SHA256 + AES-256-GCM），`info` = `huijian e2e v1 message`，附加数据 = `hje1.<kid>`，kid = 公钥 SHA-256 前 8 字节的十六进制。信封最长 120 KB。
- 明文是 JSON：`{"v": 1, "text", "desp", "type", "atts": [{"name", "mime", "size", "key"}]}`。`atts` 和上传的附件按顺序一一对应，`key` 是这个附件的随机 32 字节密钥（base64url），`size` 是明文大小；
- 附件上传密文：文件头 `HJF1` + 4 字节块大小（大端，65536），之后每块 AES-256-GCM（密文 + 16 字节校验），nonce = 11 字节块序号（大端）+ 1 字节末块标记，附加数据 = 文件头。空文件也有一个（空的）末块。上传时文件名写 `encrypted-N.bin`（服务器也会强制改成这样），真实名字在信封里。
- `priority`、`topic`、`thread`、`idem` 照常明文传（服务器要靠它们提醒、分类、去重）。

服务器检查信封格式和 kid 是否属于这个账号（钥匙已更换时返回 400，请重新复制加密发送密钥），存下的消息 `type` 为 `e2e`，`text` 是占位文字「🔒 加密消息（请把回笺更新到最新版查看）」，`desp` 为空。一次发给多个 pushkey 时，它们必须属于同一个账号。用加密发送密钥（带 `.e2e.`）却没有 `e2e` 字段时返回 400（多半是旧版命令行或 curl，避免误以为发出去的是加密的）。钥匙更换后，用已停用的旧钥匙加密的消息返回 400。账号打开「只接受加密消息」后，明文发送返回 403（一次发给多个账号时，任何一个打开了都拒收）；服务器自己产生的系统通知（管理后台发的消息、存储告警）不受这个开关限制。

加密只保证**保密**，不保证**来源**：拿到加密发送密钥的人、以及服务器本身都能往你的账号塞一条「加密消息」，也能改它的优先级和频道。客户端不要把 🔒 显示成「可信来源」。各端用 `server/testdata/e2e_vectors.json` 的测试向量核对实现。

**优先级**

| 级 | 名称 | Mac 客户端默认行为 |
|---|---|---|
| 5 | 紧急 | 弹出通知并响铃，菜单栏图标变红；免打扰期间也会提醒 |
| 4 | 重要 | 弹出通知并响铃 |
| 3 | 普通 | 静默弹出通知 |
| 2 | 低 | 不弹出，只进入列表 |
| 1 | 日志 | 不弹出，列表中显示为弱化样式 |
| 0 | 调试 | 不弹出 |

**响应**

```json
{"code": 0, "content": {"result": ["123"]}}
```

错误时返回对应 HTTP 状态码和 `{"code": 403, "error": "pushkey 无效或已吊销"}`。可能的状态码：400（参数错误）、403（pushkey 无效）、413（超过大小上限）、429（发送太频繁）。

**示例**

```bash
curl "https://push.example.com/message/push?pushkey=PK_xxx&text=训练完成"

curl -F pushkey=PK_xxx -F text="exp42 完成" -F desp="val_loss **0.231**" -F priority=4 \
     -F topic=train -F thread=exp42 -F file=@loss.png -F file=@report.pdf \
     https://push.example.com/message/push
```

## 2. 设备接口

除配对、登录、注册和 `/v1/info` 外，都需要请求头 `Authorization: Bearer DT_xxx`（设备 token）。

### 版本兼容

客户端和服务端各自升级，可能出现「客户端新、服务端旧」或反过来的情况。约定如下：

- 服务端**只新增**接口和字段，不删除、不改变含义；旧客户端在新服务端上照常工作。
- `GET /v1/info`（无需鉴权）返回版本和功能清单：
  ```json
  {"name": "huijian", "version": "0.5.0", "api": 1, "register_open": false,
   "features": [{"id": "keys", "title": "在客户端管理 pushkey", "since": "0.4.2"}, …]}
  ```
  所有 `/v1` 响应都带 `X-Huijian-Server: <版本>`，客户端发现版本变化时重新拉取。
- 客户端按 `features` 判断功能是否可用：服务端没有的功能显示「更新服务端后可用」；服务端有、客户端不认识的功能显示「更新客户端后可用」（用 `title` 展示）。
- 0.5.0 以前的服务端没有 `/v1/info`：调用不存在的接口时，路由层返回**纯文本**的 `404 not found` 或 `405`（业务上的 404 都是 `{"error": …}`），客户端据此判断「服务端版本较旧」。

### 账号

一个账号 = 一个人，拥有自己的 pushkey、设备和消息历史。管理员在管理后台「账号」页创建账号，也可以开放注册。0.5.0 以前的数据属于第一个账号，它一开始没有密码，Mac 客户端升级到 0.5.1 后，在「允许管理」的设备上打开会先要求设置用户名和密码，之后即可在其他设备登录。新账号不预置 pushkey，由账号自己新建（客户端新建第一把时名称默认填 `default`）。

用户名 2–32 个字，可以用中文、字母、数字、空格、下划线、点和短横线（0.5.1 起允许中间有空格，例如 `Alex Chen`）；首尾空白会去掉，中间连续空白合并成一个空格。登录时不区分大小写。

| 请求 | 说明 |
|---|---|
| `GET /v1/prelogin?username=` | 0.7.0 起：登录前取密码派生参数。`{"kdf": "argon2id", "salt", "time", "memory_kib", "lanes"}`：按新协议登录；`{"kdf": "pbkdf2-sha256", "salt", "iterations"}`：还没升级的旧账号，客户端在本机算 PBKDF2-HMAC-SHA256(密码, salt, iterations, 32 字节)，作为 `password_key` 发送（不发密码原文）。账号不存在时返回由用户名算出的固定假盐（注册时「用户名已被占用」本来就能看出账号是否存在，这里只是不额外给出答案） |
| `POST /v1/login` | `{"username", "password", "name", "platform", "fingerprint"}` → `{"device_id", "name", "token", "reused"}`；用户名不区分大小写。0.7.0 起可以不带 `password` 而带 `auth_key`（已升级的账号）或 `password_key`（旧账号），见下文「新登录协议」；带 `auth_key` 时响应多一个 `e2e: {"enabled", "keys", "password_wrap"}`。已升级的账号用 `password` / `password_key` 登录返回 426 |
| `POST /v1/register` | 同上，注册新账号（管理员开放注册后才可用，否则 403）。新协议注册带 `auth_key` 和 `auth_salt`（客户端随机生成的 16 字节盐，十六进制），服务器从头到尾拿不到密码 |
| `PUT /v1/account/auth` | 0.7.0 起：升级到新登录协议 / 改密码。`{"current_password" / "current_password_key" / "current_auth_key", "auth_salt", "auth_key", "password_wrap"}`；已开启加密时 `password_wrap`（用新密码锁住的私钥）必填（缺少时 400，和开启加密同时发生时 409） |
| `POST /v1/logout` | 本机 token 立即失效（设备记录保留） |
| `GET /v1/account` | 账号信息和本账号全部设备：`{"account": {"id", "username", "has_password"}, "devices": [{…, "pair_count", "pairings": [{"at", "ip", "method", "client"}]}], "register_open"}` |
| `POST /v1/account/credentials` | `{"username", "password", "current_password"}`：账号还没有密码时，只有「允许管理」的设备能设置（防止被拿到普通配对码的人抢先设密码）；已有密码时需要当前密码，「允许管理」的设备可直接重设。`password` 为空表示只改用户名。已升级到新登录协议的账号：改密码要用 `PUT /v1/account/auth`（这里带 `password` 返回 426），只改用户名时用 `current_auth_key` 核对 |
| `POST /v1/pair-codes` | 为本账号生成配对码（3 分钟有效、只能用一次，新设备没有服务器管理权限）→ `{"code", "expires_in"}`。同一台设备再次生成时，它之前没用掉的配对码立即作废；每个账号最多 5 个未使用的配对码，超出返回 429 |
| `GET /v1/pair-codes/{code}` | 配对码状态（0.5.6 起，功能 id `pair.status`）：`{"state": "waiting" \| "used" \| "expired", "expires_in", "used_by", "used_at"}`，`used` 时带使用它的设备名。只能查本账号的配对码；已用或过期的配对码保留一小时 |
| `POST /v1/devices/{id}/revoke` | 移除本账号的另一台设备（没有「允许管理」的设备不能移除有「允许管理」的设备，返回 403） |

**新登录协议（0.7.0 起）**：密码不再发给服务器。客户端先 `GET /v1/prelogin` 取盐，在本机算 Argon2id（RFC 9106，`time`=3、`memory_kib`=65536、`lanes`=1，输出 64 字节），前 32 字节 base64url 后作为 `auth_key` 发给服务器（服务器只存它的 SHA-256），后 32 字节是解锁钥匙，只留在本机，用来解开 `password_wrap`。旧账号用新客户端登录时发 `password_key`（PBKDF2 结果），登录后客户端用 `PUT /v1/account/auth` 自动升级。管理员在后台用原文重设密码后，账号回到旧协议，用旧密码锁住的私钥副本作废（要靠恢复码或另一台设备批准解锁，再重新升级）。核对当前密码的接口（`current_password` / `current_password_key` / `current_auth_key`）规则相同。

**客户端必须遵守**（防止被攻破的服务器骗出能快速破解的派生值）：

- Argon2id 参数写死在客户端（3 轮、64 MiB、1 线程），服务器给的不一致就拒绝登录；PBKDF2 轮数少于 600000 也拒绝；
- 新客户端**从不**发送 `password` 原文；
- 记住「这个服务器上的这个账号已经升级过」，之后再收到 `pbkdf2-sha256` 就拒绝并提示可能有人冒充服务器；
- 新协议注册、开启加密、改密码时，密码强度（至少 10 位、不是常见弱密码）只能由客户端检查，服务器拿不到密码。

**设备身份**：配对、登录时带上 `fingerprint`（客户端根据本机硬件生成的哈希，32–128 位十六进制）。同一账号下指纹相同的设备会沿用原来的设备记录（ID、名称、接收规则不变），旧 token 作废，并追加一条配对记录；返回里 `reused: true`。

### 按设备接收规则、在用设备优先

| 请求 | 说明 |
|---|---|
| `GET /v1/subscriptions` | 本机对每把 pushkey 的接收方式：`{"subscriptions": [{"pushkey_id", "name", "mode"}], "away_silent": true}` |
| `PUT /v1/subscriptions/{pushkey_id}` | `{"mode": "notify" \| "silent" \| "off"}`：提醒（默认）/ 静默（进列表、不弹不响）/ 不接收 |
| `PATCH /v1/me` | `{"away_silent": false}`：关闭「我在用其他设备时本机不响」 |
| `POST /v1/presence` | 客户端有人在用时每 30 秒上报一次（返回 204） |

`GET /v1/messages` 返回的消息带 `pushkey_id`；按本机规则需要静默的消息带 `"silent": true` 和 `silent_reason`（`key` = 这把 key 设为静默，`active_elsewhere` = 同账号的另一台设备 90 秒内有人在用）。紧急（P5）消息不会被静默。设为「不接收」的 key 发来的消息不会出现在本机的列表里，也不会唤醒长轮询。

### `POST /v1/pair`
```json
{"code": "123456", "name": "我的 MacBook", "platform": "macos", "fingerprint": "…"}
```
配对码在管理后台「设备」页（加入当前选中的账号）或已登录设备的「账户」页生成，3 分钟内有效，只能使用一次。返回：
```json
{"device_id": "d_…", "name": "我的 MacBook", "token": "DT_…", "reused": false}
```
token 只返回这一次，请妥善保存（Mac 客户端存放在钥匙串里）。

### `GET /v1/me`
返回 `device_id`、`name`、`platform`、`can_admin`、`admin_url`、`account`、`away_silent`，以及 `bark`（0.5.7 起：`{"url": "...", "encrypted": true}`，没设置时为 `null`；不返回加密密钥）。

### 转发到 Bark（0.5.7 起，功能 id `bark`）

iPhone 客户端用 GBox 等工具自签安装，用不了苹果推送。锁屏通知借用 App Store 免费 App「Bark」的推送通道：每台设备可以登记一个 Bark 推送地址，新消息按**这台设备**的接收规则判断后转发过去（不接收的 key、静默的 key / 频道、正在别的设备上使用时不转发；P0–P2 不转发）。

| 接口 | 说明 |
|---|---|
| `PUT /v1/bark` `{"url": "https://api.day.app/<key>", "cipher_key": "", "cipher_iv": ""}` | 设置 / 修改；`url` 为空字符串表示关闭。地址可以直接粘贴 Bark 里复制的整段，会规范化为 `scheme://host/<key>`。可选端到端加密：`cipher_key` 16 / 24 / 32 个字符（AES128 / 192 / 256），`cipher_iv` 16 个字符；Bark「加密设置」里选 CBC 模式、填同样的 key（iv 随每条推送发送）。加密时 level、group、url 等参数全部放在密文里 → `{"url", "encrypted"}` |
| `POST /v1/bark/test` | 发一条测试通知 → `{"ok": true}`；Bark 连不上或返回错误时 502 `{"error": "..."}` |

转发内容：`title` 为消息标题，`body` 为正文转成的纯文本（规则见 [markdown.md](markdown.md) 末尾，最多 300 字，带附件数），`group` 为频道显示名，`url` 为 `huijian://message/<id>`（点通知打开回笺的这条消息），`level`：P5 `critical`（静音和勿扰下也响）、P4 `timeSensitive`、P3 `active`；`isArchive=0`（历史在回笺里看）。加密时以上所有参数都放进 `ciphertext`（实测 Bark 加密推送只认密文里的参数），表单外只有 `ciphertext` 和 `iv`。设置了 `HUIJIAN_PUBLIC_URL` 时通知带回笺图标。

### 端到端加密（0.7.0 起，功能 id `e2e`）

设计和算法见 [e2ee.md](e2ee.md)。服务器只存公钥和「锁住的私钥副本」，自己解不开。下面的锁住的副本格式都是 `<前缀>.<base64url(nonce 12 字节‖密文)>`，AES-256-GCM，附加数据 = 前缀：

- `hjp1`：用密码派生的解锁钥匙锁住（见上文「新登录协议」）；
- `hjr1`：用恢复码锁住，密钥 = HKDF-SHA256(恢复码 16 字节, salt=`huijian e2e v1 recovery`, 32 字节)。恢复码显示为 26 位 Crockford Base32，分组 `XXXXX-XXXXX-XXXXX-XXXXX-XXXXXX`；
- `hjg1`：转交给某台设备，`hjg1.<base64url(enc‖ct)>`，HPKE 加密给这台设备登记的公钥，`info` = `huijian e2e v1 grant`，附加数据 = `hjg1`。

明文都是 32 字节 X25519 私钥。

**设备批准的核对码**（先承诺、后揭晓，防止服务器挑选能碰出相同核对码的公钥冒充新设备）：

1. 新设备 B 生成随机 32 字节 `nb`，`PUT /v1/e2e/device {"pub", "request": true, "commit"}`，`commit` = SHA-256(`huijian e2e v1 commit` ‖ B 公钥 ‖ nb)；
2. 已解锁的设备 A 在 `requests` 里看到请求（带 `commit`），生成随机 32 字节 `na`，`POST /v1/e2e/challenge`。A 必须只用**自己生成**的 na；
3. B 在 `device.challenge` 里看到 na 后 `POST /v1/e2e/reveal {nonce: nb}`。每个 nb 只揭晓一次：揭晓之后 na 变了，就整个请求重来（新的 nb）；
4. A 在 `requests[].reveal` 里拿到 nb，先核对 commit，两边各自显示核对码 = SHA-256(`huijian e2e v1 sas` ‖ B 公钥 ‖ na ‖ nb) 前 4 字节大端整数 mod 10⁶，补足 6 位。用户核对一致后 A 才 `grant`。

公钥、na、nb 都是 32 字节，base64url 传输。测试向量里的 `sas_*` 字段可以用来核对实现。

| 请求 | 说明 |
|---|---|
| `GET /v1/e2e` | 本账号的加密状态：`{"enabled", "keys": [{"kid", "pub", "active"}], "e2e_only", "auth_key"（是否已升级新登录协议）, "has_password_wrap", "recovery_wrap", "device": {"pub", "grant", "requested", "challenge", "revealed"}, "requests": [{"device_id", "name", "platform", "pub", "requested_at", "commit", "challenge", "reveal"}]}`。`requests` 是等待批准的其他设备 |
| `POST /v1/e2e/setup` | 开启加密（同时升级登录协议）：`{"pub", "auth_salt", "auth_key", "password_wrap", "recovery_wrap", "current_password" / "current_password_key" / "current_auth_key"}` → `{"kid"}`。已开启返回 409 |
| `POST /v1/e2e/unlock` | 没输过密码的设备（配对码登录）解锁：`{"auth_key"}` → `{"password_wrap"}` |
| `PUT /v1/e2e/device` | 登记本机公钥：`{"pub", "request", "commit"}`。`request: true` 时请求其他设备批准（必须带 `commit`）；每次调用都让之前的核对过程作废；公钥换了，原来转交给本机的副本作废 |
| `POST /v1/e2e/challenge` | 批准设备接手请求：`{"device_id", "nonce"}`（na）。每个请求只能接手一次，否则 409 |
| `POST /v1/e2e/reveal` | 新设备揭晓：`{"nonce"}`（nb），必须和承诺一致、只能揭晓一次，否则 409 |
| `POST /v1/e2e/grant` | 批准另一台设备：`{"device_id", "pub", "grant"}`。对方必须在等待批准、已经揭晓 nb，`pub` 必须和对方当前登记的一致，否则 409。新设备收到转交的私钥后，必须核对它对应的公钥是账号的有效钥匙（`keys` 里 `active` 的那把），对不上就丢弃 |
| `POST /v1/e2e/deny` | 拒绝：`{"device_id"}` |
| `PUT /v1/e2e/recovery` | 换恢复码：`{"recovery_wrap", "current_password" / "current_password_key" / "current_auth_key"}`，旧恢复码立即失效 |
| `PATCH /v1/e2e` | `{"e2e_only": true/false}`：只接受加密消息 |
| `POST /v1/e2e/delete-plain` | `{"confirm": true}` → `{"deleted"}`：删除服务器上本账号的全部明文消息（加密消息不动）。删掉的消息记为 `kind: "purge"` 的变更（不是 `delete`），各设备保留已同步的本地副本。数据库开启了 `secure_delete`，删除后数据库文件里不残留原文；**之前做的备份不受影响**，需要的话请自行删除旧备份 |

有设备请求批准、批准或拒绝后，同账号的长轮询会收到 `kind: "e2e"` 的变更（id 0），客户端重新 `GET /v1/e2e`。移除设备时，转交给它的副本一并删除。

### `PATCH /v1/me`
给本机改名：`{"name": "我的 MacBook"}`，返回同 `GET /v1/me`。名称可以重名；设备 ID 唯一，格式为 `d_<UTC 时间戳>_<4 位随机>`，例如 `d_20261117083015_a1b2`。

### Pushkey 自助管理
本账号的任何设备都可以直接管理本账号的 pushkey，不必登录管理后台（0.5.0 以前需要「允许管理」）：

| 请求 | 说明 |
|---|---|
| `GET /v1/keys` | 列出全部：`{"keys": [{"id", "name", "key", "created_at", "last_used", "revoked"}]}` |
| `POST /v1/keys` | 新建：`{"name": "…", "key": "…"}`，`key` 可省略（自动生成）；自定义 key 为 16–64 位字母、数字、`_`、`-`，重复返回 409 |
| `PATCH /v1/keys/{id}` | 改名 / 更换 key：`{"name": "…", "key": "…"}`，空字符串表示不改；更换后旧 key 立即失效 |
| `POST /v1/keys/{id}/revoke` | 吊销 |
| `DELETE /v1/keys/{id}` | 删除一把**已吊销**的 pushkey（0.5.2 起，功能 id `keys.delete`）→ 204；未吊销返回 409。删除后列表里不再显示，历史消息保留；服务端仍保留这条记录，key 字符串不能再被任何账号用作自定义 key |

### `GET /v1/messages?since=<id>&limit=<n>&wait=<秒>`
- 返回 `id > since` 的消息，按 id 升序排列；`limit` 默认 200，最大 500。
- 不带 `since` 时返回最新的 `limit` 条。
- 返回里的 `next_since` 是服务端已经扫过的位置（0.5.0 起）。本机设为「不接收」的消息会被跳过，下一次请求用 `next_since` 代替最后一条消息的 id，避免反复扫描被过滤掉的消息。
- **长轮询**：带 `wait`（秒）时，如果暂时没有新消息，服务器会挂起等待，有新消息立即返回，超时则返回空列表。

  每次响应都是完整结束的，所以能穿过会缓冲流式响应的代理或杀毒软件。客户端推荐用这种方式实时接收。

  `wait` 的上限：0.6.4 起由 `/v1/info` 的 `long_poll_max` 给出（默认 600，服务端用 `HUIJIAN_LONGPOLL_MAX` 调整，功能 id `poll.long`）；更早的服务端是 55，超过的按上限处理。

  **自适应等待时长**（官方客户端的做法，自己写客户端时建议照做）：等得越久，手机网络被唤醒的次数越少；但等太久会被运营商 NAT、路由器或反向代理悄悄断开。
  - 从 120 秒起步；连续 3 轮没有消息、等满了才返回，就加 60 秒，最多 600 秒，且不超过 `long_poll_max`；
  - 中途被切断（连接被关闭，或代理 / CDN 读超时返回 408、502、503、504、520–524，例如 Cloudflare 100 秒返回 524）：退到切断点前 15 秒，把切断点记为上限；
  - 到点没有响应（客户端读超时 = wait + 20 秒）：减半，把这次的时长记为上限；
  - 上限 6 小时后失效，重新试探；请求发出 20 秒内就失败、或耗时超过 wait + 90 秒（设备睡眠、App 被挂起）的不算；
  - Wi-Fi、蜂窝、VPN、有线分开记；请求期间换了网络或断网的失败不记。服务端没有 `poll.long` 时固定用 50 秒。

消息格式：
```json
{
  "id": 123, "topic": "train", "thread": "exp42", "priority": 4, "type": "markdown",
  "text": "exp42 完成", "desp": "val_loss **0.231**", "source": "PC 训练脚本",
  "created_at": "2026-11-17T06:32:05Z",
  "attachments": [{"id": "a_…", "name": "loss.png", "mime": "image/png", "size": 102901, "sha256": "…"}]
}
```

0.6.0 起（功能 id `markdown.doc`）`type` 不是 `text` / `image` 且正文非空的消息多两个字段：`preview`（纯文本预览，≤200 字）和 `doc`（服务端解析好的回笺 Markdown 结构，`{"v":1,"blocks":[…]}`，定义见 [markdown.md](markdown.md#给客户端开发者doc-结构)）。客户端按 `doc` 绘制，各端效果一致；没有 `doc` 时自己解析 `desp`。

0.5.4 起消息多一个 `archive` 字段（没有时为 0）：`0` 自动（客户端按「超过 N 天自动归档」显示）、`1` 已归档、`2` 保留在收件箱（不再自动归档）。

### 删除与归档消息（0.5.4 起，功能 id `messages.manage`）

| 接口 | 说明 |
|---|---|
| `POST /v1/messages/delete` `{"ids":[1,2]}` | 从账号删除（同账号的所有设备都会同步删除），附件文件一起删除 → `{"deleted": n}`。不属于本账号或不存在的 id 忽略；一次最多 1000 个 |
| `POST /v1/messages/archive` `{"ids":[…],"state":1}` | 设置归档状态（0 / 1 / 2，含义见上）→ `{"updated": n}` |
| `GET /v1/messages/state` | 对账：`{"items":[[id, archive], …], "changes_next": 游标}`，本账号全部消息。客户端本地有、这里没有的消息已被删除 |

**多设备同步**：长轮询 `GET /v1/messages` 加上 `changes_since=<游标>` 后，响应多三个字段：

- `changes`：游标之后本账号的删除 / 归档变更，`[{"seq": 41, "id": 123, "kind": "delete"}, {"seq": 42, "id": 124, "kind": "archive", "state": 1}]`；0.7.0 起还有 `kind: "purge"`：「删除服务器上的明文消息」删掉的消息，服务器上已经没有了，但客户端应当**保留**已同步的本地副本（记为「仅本机保留」，对账时也不删）；
- `changes_next`：下一次请求用的游标；
- `changes_reset`：为 `true` 时游标已经失效（离线超过 90 天、变更记录已清理，或服务端数据库从备份恢复过），客户端应调用 `GET /v1/messages/state` 重新对账，再用返回的 `changes_next` 继续。

有新变更时挂起的长轮询会立即返回。客户端第一次使用时先调 `GET /v1/messages/state` 拿到游标。不带 `changes_since` 的旧客户端不受影响。

**设置实时同步**（服务端 0.6.1 起，功能 id `sync.settings`）：同一条变更流里还会出现账号设置的变化，`id` 都是 0，客户端收到后重新拉取对应的设置：

| kind | 什么变了 | 客户端重新调用 |
|---|---|---|
| `channels` | 频道改名、隐藏、静音、置顶、排序、删除（0.5.x 起） | `GET /v1/channels` |
| `keys` | pushkey 新建、改名、换 key、吊销、删除 | `GET /v1/keys` |
| `devices` | 设备加入、改名、移除、管理权限 | `GET /v1/account` |
| `account` | 用户名、密码（账号被停用时也会唤醒，接下来的请求返回 403） | `GET /v1/account` |

每台设备自己的接收规则、离开静音、Bark 转发设置只有本机能改，不产生变更。

管理后台和设备接口的修改都会产生这些变更，挂起的长轮询会立即返回。客户端要忽略不认识的 `kind`。

### 频道设置（0.5.5 起，功能 id `channels`）

频道就是消息的 `topic`（发送时的参数，没带时为 `default`）。每个账号可以给频道起显示名、隐藏、静音、置顶和手动排序，所有设备共用：

| 接口 | 说明 |
|---|---|
| `GET /v1/channels` | `{"channels":[{"topic":"train","alias":"训练","hidden":false,"muted":true,"pinned":true,"sort":1}]}`，只返回设置过的频道 |
| `PATCH /v1/channels` `{"topic":"train","alias":"训练","muted":true}` | 修改设置，只改传了的字段；`alias` 最多 32 个字，空字符串 = 恢复原名 → 修改后的设置 |
| `PUT /v1/channels/order` `{"topics":["train","infra"]}` | 手动排序（按列表顺序 1、2、3…，没列出的清掉顺序）；空列表 = 恢复按最近活跃排序 → 204 |
| `POST /v1/channels/delete` `{"topic":"train"}` | 删除这个频道的全部消息（附件一起删）和它的设置 → `{"deleted": n}`。之后再有这个 topic 的消息发来，频道会重新出现 |

- **隐藏**：消息不进收件箱、不计未读，服务端把这个频道的消息都标为静默（`silent_reason: "channel_hidden"`，紧急消息也不提醒）。
- **静音**：照常显示，P1–P4 标为静默（`silent_reason: "channel_muted"`），P5 紧急照常提醒。
- 每次修改都会在变更里加一条 `{"kind": "channels", "id": 0}`，其他设备收到后重新调用 `GET /v1/channels`。

管理后台的消息页也可以删除单条消息，同样会同步到客户端。注意：每日备份里的数据库快照（默认保留 14 天）和附件镜像不会因为删除而改变，需要彻底清除时手动处理备份目录。

### `GET /v1/stream?since=<id>`
SSE 实时流（`event: message`，`id:` 为消息 id），每 20 秒发一次心跳。网络环境干净时可以用；如果中间有会缓冲响应的代理，请改用长轮询。

### `GET /v1/att/{id}`
下载附件，支持 `Range` 断点续传。响应头 `X-Huijian-Sha256` 带文件的 sha256，客户端应在下载完成后校验。

### 服务端存储与备份（需要「允许管理」）
- `GET /v1/storage[?fresh=1]`：数据库、附件目录、备份目录的路径、占用、剩余空间，备份计划和上次结果。
- `POST /v1/storage/backup`：在后台开始一次备份，返回 202。

### `POST /v1/admin/link`
设备在管理后台被授予「可进入管理后台」权限后，可以用它换取一个 60 秒内有效的一次性登录链接：
```json
{"url": "http://127.0.0.1:8791/auth/link?t=L_…", "expires_in": 60}
```
无权限时返回 403。

### `GET /v1/update?build=<当前构建号>`
应用内更新。按设备平台返回比 `build` 新的最新版本，没有时返回 `{"update": null}`：
```json
{"update": {"id": 3, "version": "0.4.1", "build": 42, "notes": "…", "size": 3456789,
            "sha256": "…", "signature": "<base64 Ed25519>", "url": "/v1/update/3"}}
```
签名内容是 `hongyan-update-v1\n<platform>\n<build>\n<version>\n<sha256>\n<sha256(notes)>`，由发布方私钥签名，客户端用内置公钥校验。服务端不持有私钥。

长轮询 `/v1/messages` 的响应头 `X-Huijian-Latest-Build` 带最新构建号，客户端据此及时发现新版本。

### `GET /v1/update/{id}`
下载更新包（zip），支持 `Range`。

客户端可以在请求头 `X-Huijian-Client` 里上报自己的版本（例如 `macos 0.4.0 (37)`），会显示在管理后台的设备列表里。

### iPhone 安装包与 GBox 软件源（0.5.7 起，功能 id `ios.source`）
不需要登录（GBox 拉取时不带 token）；设置 `HUIJIAN_IOS_SOURCE=0` 关闭。

| 接口 | 说明 |
|---|---|
| `GET /ios/gbox.appsrc` | [GBox 软件源](https://github.com/GBoxApp/GBoxSource)（JSON），列出最新发布的 iOS 版本。在 GBox 里添加一次，以后发布新版本，GBox 里就能看到并一键重签安装 |
| `GET /ios/Huijian-<版本>-<构建号>.ipa` | 安装包（支持 `Range`） |
| `GET /icon.png` | 应用图标（软件源和 Bark 通知用） |

发布：`huijian release -platform ios -key <私钥> -version 0.1.0 -build N -notes 说明 Huijian.ipa`。iPhone 客户端照常用 `GET /v1/update` 发现新版本，提示到 GBox 里更新。

### 管理端口 `POST /api/releases`
发布更新包，只在管理端口提供，需要 `Authorization: Bearer <管理令牌>`。字段：`platform`、`version`、`build`（必须比已发布的大）、`notes`、`sha256`、`signature`、`file`。每个平台保留最近 5 个版本。一般不直接调用，用下面的 `huijian release` 或 `mac/release.sh`。

### 管理端口 `GET` / `POST /api/server-update`（0.6.2 起）
把签名的服务端程序推送到这台服务器，只在管理端口提供，需要 `Authorization: Bearer <管理令牌>`。

- `GET`：返回 `{"version", "platform", "enabled", "applying"}`，例如 `"platform": "linux-amd64"`。
- `POST`：multipart，`manifest` 是发布时生成的 `update-server.json`，`file` 是清单里本平台的程序。服务器用内置公钥校验本平台条目的签名、程序的 sha256 和大小，版本必须比当前新；然后试运行、备份数据库，返回 `{"ok": true, "version", "previous", ...}`，再平滑重启到新程序。没有令牌或令牌不对返回 401，校验不通过返回 400，`HUIJIAN_SERVER_UPDATE=0` 时返回 403，正在更新返回 409；校验通过但安装失败（例如新程序试运行失败、更新前备份失败）返回 500，服务器继续运行当前版本，错误会显示在设置页「上次更新」里。

一般不直接调用，用 `huijian server-push -manifest update-server.json`（见部署指南「升级」）。

## 3. 命令行

```bash
export HUIJIAN_URL=https://push.example.com        # 可写多个，逗号分隔，按顺序尝试
export HUIJIAN_PUSHKEY=PK_xxx
huijian push -p 4 -topic train -thread exp42 -d "val_loss 0.231" -f loss.png "exp42 完成"
echo "多行内容" | huijian push -
HUIJIAN_PUSHKEY=PK_xxx.e2e.<公钥> huijian push …   # 加密发送密钥：标题、正文、附件在本机加密（0.7.0 起）
huijian flush          # 立即补发 outbox 中积压的消息
huijian admin-link     # 在服务器上生成一次性管理登录链接（忘记令牌时用）

# 客户端发布（在开发机上执行，私钥不离开开发机）
huijian release-key ~/secrets/update.key        # 生成签名私钥，打印公钥
huijian release -key ~/secrets/update.key -version 0.4.1 -build 42 -notes "说明" Huijian.zip

# 服务端推送到自己的服务器（读 HUIJIAN_ADMIN_URL、HUIJIAN_ADMIN_TOKEN）
huijian server-push -manifest server/bin/release/update-server.json
```

发送失败（网络错误或 5xx）时，消息会存入 `~/.huijian/outbox/`，下次执行发送或 `flush` 时自动补发。多个进程同时补发不会重复：outbox 通过原子改名认领任务，服务端再用幂等键去重。

## 4. Python SDK

`sdk/python/huijian.py` 是单个文件，复制到项目里即可使用。普通 pushkey 只用标准库；`pushkey` 是加密发送密钥（`PK_xxx.e2e.<公钥>`）时，标题、正文、附件（含文件名）在本机加密后再发出，需要 `cryptography` 库（`pip install cryptography`）。加密格式和 `huijian push` 逐字节一致。

```python
import huijian
huijian.push("exp42 完成", "val_loss 0.231", files=["loss.png"], priority=4, topic="train")

with huijian.run("exp42", topic="train"):    # 开始 P4 / 完成 P4（含用时）/ 异常 P5（含 traceback）
    train()
```
`push()` 默认不抛异常，返回 `None` 表示失败。这样通知发送失败也不会打断训练。
