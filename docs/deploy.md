# 部署指南

## 方式一：一台有公网 IP 的服务器（推荐，不需要域名）

适合自用：一台云服务器（国内外云厂商的云主机、VPS 都可以），装好 Docker 即可。

```bash
git clone https://github.com/HongYile/huijian.git
cd huijian/deploy/docker
cp .env.example .env        # 把 HUIJIAN_PUBLIC_URL 改成 http://你的公网IP:8790
docker compose up -d --build
```

然后：

1. 在云服务器的**安全组 / 防火墙**里放行 `8790`（消息 API）。管理后台（`8791`）默认只监听服务器本机，**不要**对外放行。
2. 在服务器上生成一个邀请码：
   ```bash
   docker exec huijian huijian invite new -note 自己
   ```
3. 回笺客户端里填服务器地址 `你的公网IP:8790`，选「注册」，填用户名、密码和邀请码。注册完就是登录状态，端到端加密已经开启。**第一个注册的账号**接收服务器自己的通知（备份失败等），不能停用、不能删除。
4. 在客户端「账户与设置 → Pushkey」新建一把 key，用来发消息。其他设备用账号密码登录，或在已登录设备的「账户」页生成配对码。
5. 给别人开账号：同样生成邀请码发给对方，对方在客户端里注册（新部署默认「需要邀请码」才能注册，账号只能这样产生）。
6. 管理后台（看统计、管账号和邀请码）只能在服务器上进入：在自己电脑上开一条 SSH 隧道，再在服务器上要一个一次性登录链接，在自己电脑的浏览器打开（会被记住一年）：
   ```bash
   ssh -L 8791:127.0.0.1:8791 你的服务器          # 自己电脑上，保持这个窗口
   docker exec huijian huijian admin-link        # 服务器上，打印 http://127.0.0.1:8791/auth/link?... （5 分钟有效）
   ```

国内服务器构建镜像慢的话，在 `.env` 里加 `GOPROXY=https://goproxy.cn,direct`。

### 安全须知

- **明文传输**：`http://IP:端口` 方式下，pushkey、设备凭证，以及用普通 pushkey 发来的消息（服务器收到后才代为加密）在网络上都是明文；客户端之间的消息内容和用加密发送密钥发的消息已经端到端加密。自用时可以接受；在意的话请用方式二配置 HTTPS。
- **管理后台**：默认只监听服务器本机（`HUIJIAN_ADMIN_BIND` 默认 `127.0.0.1`），从别的电脑访问用 SSH 隧道。改成 `0.0.0.0` 会对公网开放：登录需要 32 位随机令牌，按 IP 限速（每分钟最多 6 次尝试），会话可以在「设置」里逐个注销，但还是建议只留在本机。
- 任何账号都不能从回笺客户端进入管理后台（0.9.0 起）：后台只能在服务器上进入，见下文「进入管理后台」。

## 方式二：域名 + HTTPS

有域名时，在服务器上用 nginx 或 caddy 做 HTTPS 反向代理，参考 [`deploy/nginx/huijian.conf.example`](../deploy/nginx/huijian.conf.example)。`.env` 改为：

```bash
HUIJIAN_PUBLIC_URL=https://push.example.com
HUIJIAN_ADMIN_BIND=127.0.0.1             # 管理后台只留在本机（SSH 隧道访问），或者也放到反向代理后面
```

注意：国内云服务器用域名对外提供 80/443 服务需要 ICP 备案。

反向代理的读超时（nginx 的 `proxy_read_timeout`）要比长轮询的最长等待（`HUIJIAN_LONGPOLL_MAX`，默认 600 秒）长，示例配置里 `/v1/` 是 660 秒。设短了也能用：客户端发现被代理切断后会自动把等待时长调到代理允许的范围内，只是手机会更费电一些。

## 方式三：家里的服务器 + 云服务器转发

想把数据留在家里（树莓派、开发板、NAS 都能跑），云服务器只负责公网入口：两者之间用 WireGuard 等组网，云服务器上的 nginx 把请求转发到家里的回笺。

- 回笺监听组网地址，例如 `HUIJIAN_PUBLIC_ADDR=10.0.0.2:8790`、`HUIJIAN_ADMIN_ADDR=10.0.0.2:8791`；
- 设置 `HUIJIAN_TRUSTED_PROXY=10.0.0.1`、`HUIJIAN_ADMIN_DENY=10.0.0.1`，这样即使云服务器被攻破，也访问不到管理后台。

## 直接运行二进制

```bash
cd server && go build -o huijian .
./huijian config init        # 生成带注释的配置文件模板（位置见下）
./huijian hub
./huijian admin-link         # 另开终端：一次性登录链接
./huijian config             # 查看实际生效的配置和各目录
```

服务端是单个静态二进制，交叉编译也很简单：`GOOS=linux GOARCH=arm64 go build`。数据库使用纯 Go 实现的 SQLite，不需要 CGO。

### 配置文件与默认位置

配置的优先级：**环境变量 > 配置文件 > 默认值**。配置文件 `huijian.conf` 和 docker 的 `.env` 是同一种格式（`KEY=VALUE`，`#` 开头为注释），查找顺序：环境变量 `HUIJIAN_CONFIG` 指定的文件 → 当前目录的 `huijian.conf` → 系统默认位置。

| 系统 | 配置文件 | 数据目录 |
|---|---|---|
| Linux（root） | `/etc/huijian/huijian.conf` | `/var/lib/huijian` |
| Linux（普通用户） | `~/.config/huijian/huijian.conf` | `~/.local/share/huijian` |
| macOS | `~/Library/Application Support/Huijian Server/huijian.conf` | 同一目录 |
| Windows | `%ProgramData%\Huijian\huijian.conf` | `%ProgramData%\Huijian\data` |
| docker | `.env` | 数据卷 `/data` |

旧版本在当前目录 `./data` 下的数据会继续沿用。

## 存储位置与备份

数据分三处，都可以单独设置：

| 目录 | 变量 | 默认 | 说明 |
|---|---|---|---|
| 数据目录 | `HUIJIAN_DATA` | 见上表 | 数据库、管理令牌、客户端更新包、一键更新下载的服务端程序（`bin/`）。**数据库必须在本地磁盘**，不要放 NAS / 网络盘 |
| 附件目录 | `HUIJIAN_FILES` | 数据目录下的 `files` | 可以放 NAS。按 `年/月/日/时分秒_标题/文件名` 存放，直接打开就能浏览（开启了加密的账号，附件是密文 `encrypted-N.bin`，目录名是占位标题，见下文） |
| 备份目录 | `HUIJIAN_BACKUP_DIR` | 数据目录下的 `backups` | 建议放 NAS 或另一块磁盘；设为 `off` 关闭自动备份 |

**附件放在 NAS 上**：先在服务器上挂载 NAS 共享（NFS 或 SMB，建议走局域网），再把 `HUIJIAN_FILES` 指向挂载点里的目录。第一次使用时目录里会写入标记文件 `.huijian`；之后如果标记不见了（多半是 NAS 没挂载上，挂载点变成了本地空目录），服务端不会往里写，新附件先存在本地，NAS 恢复后自动搬回去，并用回笺给第一个账号推一条通知。具体步骤见下面的「附件和备份放到 NAS」。

**自动备份**：每天 `HUIJIAN_BACKUP_AT`（默认 `03:30`，按 `TZ` 时区）执行，内容：

```
<备份目录>/
  db/huijian-20261117-033000-<实例>.db   数据库快照，保留最近 HUIJIAN_BACKUP_KEEP 份（默认 14）
  files/2026/11/17/...                   附件镜像（只增不删）
  releases/  admin.token  huijian.conf   更新包、管理令牌、配置文件
  说明.txt
```

- 附件镜像（`HUIJIAN_BACKUP_FILES`）：默认 `auto`，和附件在同一块磁盘时用硬链接（不额外占空间，能防误删，防不了磁盘损坏），不同磁盘时复制；`1` 总是复制，`0` 不镜像。在客户端删除消息时，镜像里的附件和已有的数据库快照不会跟着删（这正是防误删的用处）；要彻底清除某些附件，手动删除备份目录里对应的文件。
- 管理后台「设置 → 存储与备份」、Mac 客户端「设置 → 服务器」可以查看状态、立即备份；命令行 `huijian backup`（服务端运行中时会交给服务端执行）。
- 备份失败会用回笺给第一个账号推一条 P4 通知。
- 多台服务器可以共用一个备份目录，快照文件名带实例标识，各自只清理自己的旧快照。
- **加密账号**（0.8.0 起所有账号都加密；0.9.0 起注册时就开启，旧账号在客户端用密码登录后自动开启）：发送端加密的消息、以及用普通 pushkey 发来的消息（明文发送：服务器收到时能看到内容，随后立即加密保存），在数据库、附件目录、备份里都只有密文；0.9.0 起账号还没开启加密时服务器拒收明文消息，不再保存任何明文，管理后台也不显示任何消息。服务器在收到明文消息的那一刻能看到内容（见 [e2ee.md](e2ee.md#服务器代加密080)）；想让服务器完全看不到，发送端用「加密发送密钥」。

### 附件和备份放到 NAS

以 Linux 服务器 + NAS 的 NFS 共享为例（SMB 同理，把挂载命令换成 `cifs` 即可）。服务器和 NAS 在同一个局域网时，用 NAS 的**局域网地址**，不要绕道 VPN / 公网。

**1. NAS 上**：开启 NFS 服务，共享一个文件夹（例如 `huijian`），允许服务器的 IP 读写。常见 NAS 系统都在「文件服务 / 文件共享协议 → NFS」里设置；有的 NAS 需要单独勾选「可见文件夹范围」。

**2. 服务器上挂载**（Debian / Ubuntu）：

```bash
sudo apt-get install -y nfs-common
showmount -e <NAS局域网IP>                 # 看 NAS 导出的路径，例如 /volume1/huijian
sudo mkdir -p /mnt/nas
# 开机自动挂载；nofail：NAS 不在线时不影响服务器开机
echo '<NAS局域网IP>:<导出路径> /mnt/nas nfs rw,hard,timeo=150,retrans=3,_netdev,nofail,noatime 0 0' | sudo tee -a /etc/fstab
sudo systemctl daemon-reload && sudo mount /mnt/nas
df -h /mnt/nas                             # 确认挂上了
```

**3. 建目录并确认服务端用户能写**：

```bash
sudo mkdir -p /mnt/nas/huijian/files /mnt/nas/huijian/backup
# docker 镜像里的服务端用户是 uid 10001；直接运行二进制时换成运行服务端的用户
sudo chown 10001:10001 /mnt/nas/huijian/files /mnt/nas/huijian/backup
sudo -u '#10001' touch /mnt/nas/huijian/files/.t && sudo rm /mnt/nas/huijian/files/.t && echo 可写
```

NAS 的 NFS 常把所有用户映射成同一个 NAS 用户（squash），这时 `chown` 不起作用，只要上面的写入测试通过就行。

**4. 让服务端用这两个目录**：

- docker（推荐）：

  ```bash
  cd deploy/docker
  cp compose.nas.example.yaml compose.override.yaml   # 里面的路径按第 3 步修改
  docker compose up -d
  ```

  示例把整个挂载点 `/mnt/nas` 映射进容器并开启 `rslave` 传播：NAS 比容器晚挂载上（开机顺序、NAS 重启）时，容器里也能马上看到，不用重启容器。
  也可以只在 `.env` 里映射两个子目录（`HUIJIAN_FILES_HOST_DIR=/mnt/nas/huijian/files`、`HUIJIAN_FILES=/files`，备份同理）。这种写法下，NAS 在容器启动后才挂上的话，需要重启容器才能看到。
- 直接运行二进制：在 `huijian.conf` 里写

  ```
  HUIJIAN_FILES=/mnt/nas/huijian/files
  HUIJIAN_BACKUP_DIR=/mnt/nas/huijian/backup
  TZ=Asia/Shanghai
  ```

**5. 验证**：

```bash
docker exec huijian huijian config      # 看附件目录、备份目录是否是 NAS 上的路径（直接运行时去掉 docker exec huijian）
docker exec huijian huijian backup      # 立即备份一次
ls /mnt/nas/huijian/backup/db           # 应该有 huijian-<日期>-<时间>-<实例>.db
```

发一条带附件的消息，`/mnt/nas/huijian/files/<年>/<月>/<日>/` 下会出现对应的文件夹。管理后台「设置 → 存储与备份」也能看到两个目录的状态和剩余空间。

**注意**

- 数据库始终留在服务器本地的数据目录里（SQLite 放在网络盘上容易损坏），备份目录里有每天的数据库快照。
- 附件和备份在 NAS 的同一个存储空间时，附件镜像用硬链接，不额外占空间，能防误删，防不了这块存储损坏。NAS 本身有 RAID / 快照时问题不大；要更稳可以把备份目录放到另一块盘，或设 `HUIJIAN_BACKUP_FILES=1` 总是复制。
- 备份目录里有管理令牌 `admin.token`，NAS 上这个文件夹只给自己的账号访问。
- `hard` 挂载在 NAS 中途掉线时，读写会等待 NAS 恢复，而不是返回错误。NAS 经常离线的话，可以改成 `soft,timeo=100,retrans=2`。

## 迁移到新服务器

1. 在新服务器上准备好配置（复制旧的 `huijian.conf` 或 `.env`，按新机器修改路径）。
2. 先**不要启动**服务端，执行恢复：
   ```bash
   huijian restore <备份目录>
   # docker：
   docker compose run --rm --entrypoint huijian huijian restore /backup
   ```
   默认选最新的、有消息的快照（`-db <文件名>` 可以指定），现有数据库会改名保留；附件只补缺失的，不会覆盖。0.8.0 起只补**这份数据库还引用着的**附件：备份里的附件镜像只增不删，里面还有删掉的消息的附件、补加密以前的明文附件，这些不会带回附件目录（恢复时会提示跳过了多少个）。它们仍留在备份目录里，确认不再需要旧快照后可以手动删除备份目录里的 `files/`，下次备份会按当前附件目录重新镜像。
3. 启动服务端。设备凭证都在数据库里，客户端只要改一下服务器地址（地址不变就什么都不用做）。

## 进入管理后台

管理后台只能在服务器上进入（0.9.0 起）：任何账号（包括第一个账号）都不能从回笺客户端进入，客户端里也没有「管理员」「允许管理」之类的开关。进入方式：

- **服务器上要一次性登录链接**（5 分钟有效、只能用一次）：
  ```bash
  huijian admin-link                          # 直接运行二进制
  docker exec huijian huijian admin-link      # docker
  ```
- **管理令牌登录**：登录页填数据目录里 `admin.token` 的内容（docker：`docker exec huijian cat /data/admin.token`），勾选「记住此浏览器」一年内免登录。
- **SSH 隧道**：管理端口建议只监听本机（docker 的 `HUIJIAN_ADMIN_BIND=127.0.0.1`，直接运行二进制时 `HUIJIAN_ADMIN_ADDR` 默认就是 `127.0.0.1:8791`），在自己电脑上：
  ```bash
  ssh -L 8791:127.0.0.1:8791 你的服务器
  # 然后在本地浏览器打开 admin-link 打印的 http://127.0.0.1:8791/auth/link?... ，或 http://127.0.0.1:8791 用令牌登录
  ```
  方式三（家里服务器 + 云服务器转发）可以用 `HUIJIAN_ADMIN_DENY` 拒绝来自转发机的访问。

管理端口上还有几个用 `Authorization: Bearer <管理令牌>` 调用的接口：`/api/releases`（发布客户端更新）、`/api/server-update`（推送服务端更新）、`/api/invites`（下面的邀请码命令用）。管理令牌等于整个后台的权限，**只在开发机（发布脚本）或服务器上使用**，不要放进客户端、CI 日志或别人能看到的地方；泄露后删掉 `admin.token` 重启服务端会生成新的。

### 运营命令（在服务器上执行）

不打开网页也能发邀请码。命令走本机管理端口，令牌从数据目录的 `admin.token` 读（或环境变量 `HUIJIAN_ADMIN_TOKEN`），所以要在服务器上执行；管理端口地址按 `-admin` 参数 > `HUIJIAN_ADMIN_ADDR`（监听 `0.0.0.0` 时连 `127.0.0.1`）> `HUIJIAN_ADMIN_URL` 的顺序确定。

```bash
huijian invite new [-n 数量] [-uses 每个可用次数] [-days 有效天数] [-note 备注]   # 默认 1 个、用 1 次、7 天；每行输出一个邀请码
huijian invite list        # 注册模式，以及每个码的状态（ok / used_up / expired / revoked）、已用 / 可用次数、过期日期、使用者、备注

# docker：前面加 docker exec
docker exec huijian huijian invite new -n 3 -note 实验室
docker exec huijian huijian invite list
```

没有建号命令：0.9.0 起账号只能由用户自己注册产生（注册时在用户自己的设备上生成加密钥匙，服务器拿不到密码和私钥）。

## 账号

一个账号 = 一个人，拥有自己的 pushkey、设备和消息历史，互相看不到。

**账号只能注册产生**（0.9.0 起）：用户在回笺客户端里注册（需要邀请码时填邀请码），注册完就是登录状态，加密钥匙在用户自己的设备上生成，注册的同时开启端到端加密。管理后台和命令行都不能建账号。没有图形界面的机器可以用命令行注册：`echo 密码 | huijian register -u 服务器地址 -invite 邀请码 -token-out 文件 用户名`（同样在本机生成钥匙）。

管理后台**只管理账号**：看不到任何账号的消息、pushkey、设备名和 IP，也不能切换到某个账号去操作。pushkey、设备、配对码只能由用户在自己的回笺客户端里管理。

- 「概览」页：全服务器的统计——账号总数（已加密 / 未加密的旧账号 / 停用）、今天 / 7 天 / 30 天活跃账号、近 30 天每日活跃账号 / 新消息 / 新账号、设备按平台和版本分布（标出较旧的）、存储占用和备份状态。统计只存计数：每天有哪些账号活跃过（保留 400 天）、每天全服务器的消息条数、附件大小和新账号数。
- 「账号」页：列出用户名、创建时间、最后活跃、设备数、消息数、占用空间、加密状态、状态。可以停用 / 启用、注销全部登录（吊销这个账号所有设备的 token，用户用密码重新登录即可）、删除账号（要输入用户名确认；消息、附件、pushkey、设备、加密钥匙全部删除，和别的账号共用的附件文件保留），以及注册模式。**第一个账号**（最早注册的；从旧版本升级的是原来的第一个账号）接收服务器自己的通知（备份失败等），不能停用、不能删除。
- 加密状态「未加密（旧账号，登录后自动开启）」只会出现在 0.9 以前建的旧账号上：用户用密码登录新版客户端时自动开启加密，在那之前发给它的消息会被拒收（服务器不保存明文，推送返回 403「账号还没开启加密」，系统通知直接丢弃）。
- 注册模式：关闭（不再产生新账号）/ **需要邀请码**（新部署默认）/ 开放。从旧版本升级时，原来开放注册的保持开放，原来关闭的保持关闭——**要给别人开账号，先在「邀请码」页把模式改成「需要邀请码」**。
- 「邀请码」页：批量生成（数量、每个可用次数默认 1、有效期默认 7 天、备注），列出码、备注、已用 / 可用次数、过期时间、使用者和时间、状态，可以作废。码可以随时复制，发给要注册的人，对方在回笺客户端注册时填写。账号删除后，使用记录显示「已删除账号」。
- 用户名和密码只有用户自己能在客户端里改，**后台不能改**（改了密码运营方就能登录进别人的账号）。还没有密码的旧账号（例如 0.5 以前的第一个账号），由这个账号任一台已登录的设备在客户端里设置。忘了密码：用恢复码或另一台已登录的设备解锁后重新设置；没有恢复码、也没有别的已登录设备时，只能请管理员删号后重新注册。
- 设备加入账号：以用户名密码登录为主（新设备用密码自动解锁加密钥匙，不需要别的设备在线批准）；配对码（已登录设备的「账户」窗口生成）是可选的便捷方式。将来计划加上新设备手机号验证（还没有实现）。同一台设备重新配对或登录时沿用原来的设备记录，不会重复出现。

## 配置项

**docker compose（`.env`）**

| 变量 | 默认值 | 说明 |
|---|---|---|
| `HUIJIAN_PUBLIC_URL` | 空 | 发送方和客户端使用的地址，例如 `http://1.2.3.4:8790` 或 `https://push.example.com`。留空时按浏览器访问的主机名自动推导 |
| `HUIJIAN_PUBLIC_PORT` | `8790` | 宿主机上的消息 API 端口 |
| `HUIJIAN_ADMIN_PORT` | `8791` | 宿主机上的管理后台端口 |
| `HUIJIAN_ADMIN_BIND` | `127.0.0.1` | 管理后台绑定的宿主机地址；`127.0.0.1` 表示只能本机 / SSH 隧道访问（推荐），`0.0.0.0` 对外开放（0.9.0 以前默认是 `0.0.0.0`） |
| `HUIJIAN_DATA_DIR` | 命名卷 `huijian-data` | 数据存放位置；填目录路径（例如 `./data`）则改为绑定挂载，目录需归 UID 10001 所有 |
| `HUIJIAN_TRUSTED_PROXY` | `172.16.0.0/12` | 采信这些来源传来的 `X-Real-IP`（同机 nginx 经 docker 网络转发时适用） |
| `GOPROXY` | 官方 | 构建镜像时的 Go 模块代理 |

**服务端（环境变量）**

| 变量 | 默认值 | 说明 |
|---|---|---|
| `HUIJIAN_DATA` | 见上表 | 数据目录：SQLite 数据库、管理令牌、客户端更新包 |
| `HUIJIAN_FILES` | 数据目录/files | 附件目录，可以放 NAS |
| `HUIJIAN_BACKUP_DIR` | 数据目录/backups | 备份目录；`off` 关闭 |
| `HUIJIAN_BACKUP_AT` / `HUIJIAN_BACKUP_KEEP` / `HUIJIAN_BACKUP_FILES` | `03:30` / `14` / `auto` | 备份时间、快照份数、附件镜像方式 |
| `TZ` | 系统 | 时区，影响备份时间和附件目录的日期 |
| `HUIJIAN_PUBLIC_ADDR` | `127.0.0.1:8790` | 消息 API 的监听地址 |
| `HUIJIAN_ADMIN_ADDR` | `127.0.0.1:8791` | 管理后台的监听地址 |
| `HUIJIAN_PUBLIC_URL` | 自动推导 | 同上 |
| `HUIJIAN_ADMIN_URL` | 自动推导 | 浏览器访问管理后台的地址（一次性登录链接的前缀）。默认取 `HUIJIAN_PUBLIC_URL` 或请求的主机名，加管理端口 |
| `HUIJIAN_PUBLIC_PORT` / `HUIJIAN_ADMIN_PORT` | 监听端口 | 对外端口（端口映射后的），用来推导页面和登录链接里的地址 |
| `HUIJIAN_INTERNAL_URL` | 空 | 可选的内网直连地址，会显示在配对提示里 |
| `HUIJIAN_TRUSTED_PROXY` | 空 | 反向代理的来源 IP 或 CIDR，逗号分隔。只有来自这些地址的请求，才会采信 `X-Real-IP` |
| `HUIJIAN_ADMIN_DENY` | 空 | 禁止访问管理后台的来源 IP 或 CIDR，例如转发用的云服务器 |
| `HUIJIAN_ADMIN_TOKEN` | 自动生成 | 管理令牌；不设置时读取或生成 `data/admin.token` |
| `HUIJIAN_MAX_UPLOAD_MB` | `512` | 单次请求体上限 |
| `HUIJIAN_PUSH_PER_MIN` | `60` | 每个 pushkey 每分钟最多发送多少次 |
| `HUIJIAN_LONGPOLL_MAX` | `600` | 长轮询最长挂起秒数（55–3600）。客户端会按网络自适应，等得越久越省电；反向代理的读超时要比它长 |
| `HUIJIAN_UPDATE_PUBKEY` | 空 | 可选。自建客户端更新渠道的 Ed25519 公钥；设置后，签名不对的更新包上传时就会被拒绝 |
| `HUIJIAN_SERVER_UPDATE` | `1` | 服务端一键更新（见「升级」）；`0` 关闭自动检查、一键更新、手动上传和推送 |
| `HUIJIAN_SERVER_UPDATE_REPO` | `HongYile/huijian` | 服务端更新从哪个 GitHub 仓库的 Releases 检查 |
| `HUIJIAN_SERVER_UPDATE_PUBKEY` | 内置公开渠道公钥 | 校验服务端更新的 Ed25519 公钥；用自己 fork 发布时改成自己的 |
| `HUIJIAN_SERVER_UPDATE_API` | `https://api.github.com` | GitHub API 地址，可换成镜像 |
| `HUIJIAN_SERVER_UPDATE_PROXY` | 空 | 服务端更新的下载代理（`http://`、`https://`、`socks5://`、`socks5h://`），只用于更新；管理后台里设置的优先 |
| `HUIJIAN_SERVER_UPDATE_MIRROR` | 空 | 下载镜像前缀，加在清单和程序的下载地址前面，例如 `https://ghproxy.example/` |
| `HUIJIAN_SERVER_UPDATE_GITHUB_TOKEN` | 空 | 可选的 GitHub 令牌（不需要任何权限），查询版本的 API 额度从每小时 60 次提到 5000 次；只发给 `api.github.com`（`HUIJIAN_SERVER_UPDATE_API` 换成别的地址时不会带上） |

旧版环境变量名 `BEACON_*` 仍然兼容。

## 手动整体打包

除了上面的自动备份，也可以把整个数据卷打包（docker compose 部署时是名为 `huijian_huijian-data` 的数据卷）：

```bash
docker run --rm -v huijian_huijian-data:/d -v "$PWD":/b alpine tar czf /b/huijian-backup.tgz -C /d .
```

数据库是 WAL 模式的 SQLite，也可以用 [Litestream](https://litestream.io) 持续复制。0.5.0 以前的附件在数据目录的 `blobs/` 下（按 sha256 存放），照常可用，不需要迁移。

## 升级

### 一键更新（0.6.0 起，推荐）

打开管理后台「设置 → 服务端更新」，有新版本时点「一键更新」。服务端启动 1 分钟后会自动检查一次，之后每 12 小时一次；发现新版本时会给账号发一条 P2 的「回笺服务端有新版本」消息。

点了之后服务端会：

1. 从 GitHub Releases（tag 为 `server-v<版本>`）下载本机平台的程序（目前提供 `linux-amd64`、`linux-arm64`）；
2. 校验大小、sha256 和 **Ed25519 签名**（公钥内置在程序里，和 Mac 客户端公开版同一把）——GitHub 或网络被劫持也装不进伪造的程序；
3. 试运行新程序，确认能在这台机器上跑；
4. **先备份数据库**（备份失败就取消更新，例如 NAS 不在线时；用 `HUIJIAN_BACKUP_DIR=off` 关闭了备份时跳过这一步）；
5. 把新程序放进数据目录的 `bin/`，平滑关闭后原地切换到新程序，大约半分钟，客户端会自动重连。

Docker 部署不需要任何额外配置：新程序在数据卷里，容器重启、`docker compose up -d` 重建后，镜像里的程序启动时会自动切到 `bin/` 里更新的版本。之后如果你用下面的方式升级了镜像、而镜像里的版本更新，就用镜像里的，下载的旧版本自动删除。

**自动回退**：新版本连续 3 次没能正常运行满 1 分钟（例如启动就崩溃），会自动回退到镜像里的版本，并在设置页显示「已回退」，这个版本以后不再自动切换。想手动回退：停掉服务，删除数据目录下的 `bin/` 再启动。

回退只换程序，**不回退数据库**：新版本如果已经升级了数据库结构，旧程序可能无法启动，这时用更新前自动做的备份恢复（`huijian restore`，见上文「迁移到新服务器」）。

`docker exec huijian huijian admin-link`、`backup`、`version` 等命令也会自动用下载的新版本执行。`bin/staged.json` 里保存着签名，每次切换前都会用内置公钥重新验签，改动它或替换程序文件都不会被执行。

相关配置：`HUIJIAN_SERVER_UPDATE=0` 关闭检查、一键更新、手动上传和推送（已经下载并切换过的版本照常使用，因为数据库可能已被它升级；要彻底回到镜像版本，删除 `bin/` 并确认数据库兼容）；`HUIJIAN_SERVER_UPDATE_REPO`、`HUIJIAN_SERVER_UPDATE_PUBKEY` 换成自己 fork 的仓库和发布公钥；`HUIJIAN_SERVER_UPDATE_API` 在访问不了 api.github.com 时换成镜像地址。

### 服务器访问 GitHub 慢（0.6.2 起）

下载很有耐心：只有连续 60 秒收不到数据才算失败，一次最长 2 小时；中断后再点「一键更新」会从断点继续（同一个版本才续传，最后整体校验 sha256 和大小）。下载完成后如果因为备份失败之类和文件无关的原因没装上，文件会留着，下次直接用，不用重新下载；磁盘写满时下载的部分会删掉。设置页会显示进度，例如「下载 0.6.2：3.1 / 13.4 MB · 120 KB/s」，更新期间页面自动刷新。

**下载代理**：国内服务器直连 GitHub 往往只有几十 KB/s，可以让更新走代理。代理只用于服务端更新（GitHub API、清单、程序下载），不影响 Bark 等其他请求。支持 `http://`、`https://`、`socks5://`、`socks5h://`，地址里可以带用户名和密码（页面上显示时会遮住）。按优先级：

1. 管理后台「设置 → 服务端更新 → 下载代理」里填写（存在数据库里，重启后仍然生效；点「清除」取消）；
2. 环境变量 `HUIJIAN_SERVER_UPDATE_PROXY`；
3. 标准的 `HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY`。它们必须是服务端进程的环境变量，写在 `huijian.conf` 里不生效，而且要重启服务才会改变；
4. 都没有就直连。

Docker 部署推荐用第 1 或第 2 种：在 `.env` 里设 `HUIJIAN_SERVER_UPDATE_PROXY`（`compose.yaml` 已经把它传进容器），不要设容器的 `HTTPS_PROXY`，免得影响其他出站请求。在管理后台设置的代理如果带用户名和密码，会以明文保存在数据库里，也会进入数据库备份。

任何一种代理格式不对时，更新请求会直接报错并在设置页提示，不会悄悄改成直连。

设置页会显示当前生效的代理和来源。代理在宿主机上（例如 Clash 监听 `127.0.0.1:7890`）时，容器里的地址要看网络模式：

- 容器用 host 网络（`network_mode: host`）：直接填 `http://127.0.0.1:7890`；
- 默认的 bridge 网络：容器里的 `127.0.0.1` 是容器自己，要填 `http://host.docker.internal:7890`，并在 `compose.yaml` 的服务下加上

  ```yaml
      extra_hosts: ["host.docker.internal:host-gateway"]
  ```

  同时代理软件要监听在 docker 网桥能访问的地址上（例如 Clash 打开「允许局域网连接」），而不只是 `127.0.0.1`。

**下载镜像**：`HUIJIAN_SERVER_UPDATE_MIRROR` 设成镜像前缀（例如 `https://ghproxy.example/`）后，清单和程序的下载地址变成「前缀 + 原地址」；API 请求不经过镜像（API 用 `HUIJIAN_SERVER_UPDATE_API` 换）。镜像不需要可信：清单里每个平台的 sha256 都有发布方的 Ed25519 签名，镜像或代理改动了任何一个字节，校验都会失败，什么也不会安装。

**GitHub API 限流**：未登录的 GitHub API 按出口 IP 每小时只给 60 次，代理（尤其是多人共用的节点）的出口常常已经用光，会返回 403。服务端遇到这种情况会自动改用直连再查一次（API 响应只有几 KB，直连再慢也够用），程序下载仍然走代理。直连也受限时，设置 `HUIJIAN_SERVER_UPDATE_GITHUB_TOKEN`（在 GitHub 设置里生成一个不勾选任何权限的令牌即可）。

**手动上传**：服务器完全下载不了时，在能访问 GitHub 的电脑上打开对应的 `server-v<版本>` 发布页，下载本平台的程序（设置页「当前版本」旁边写着平台，例如 `linux-amd64`）和 `update-server.json`，在「设置 → 服务端更新 → 手动上传」里选这两个文件上传。之后的步骤和一键更新完全一样：校验签名、sha256 和大小，版本必须比当前新，试运行、备份数据库，再平滑重启。

**从开发机推送**：自己编译、发布服务端的话，可以用管理令牌直接推送到自己的服务器，不经过 GitHub 下载：

```bash
HUIJIAN_ADMIN_URL=http://<服务器内网地址>:8791 HUIJIAN_ADMIN_TOKEN=<管理令牌> \
  huijian server-push -manifest server/bin/release/update-server.json
```

它先查询服务器的平台和版本，服务器已经是这个版本或更新时直接退出；否则上传清单里对应平台的程序，服务器校验通过后回复结果，然后平滑重启。接口在管理端口上（`GET` / `POST /api/server-update`，Bearer 管理令牌），公网端口没有。`server/release_github.sh` 发布成功后，如果 `mac/build.local.env` 里配置了 `HUIJIAN_ADMIN_URL`（以及 `HUIJIAN_ADMIN_TOKEN` 或 `HUIJIAN_ADMIN_TOKEN_CMD`，写法同 `mac/release.sh`），会自动执行这一步；推送失败只警告，不影响 GitHub 上的发布；`SERVER_PUSH=0` 跳过。

### 升级镜像

也可以照旧从源码重新构建镜像（离线环境、关闭了一键更新、或者想跟最新的提交时）：

```bash
cd huijian && git pull && cd deploy/docker && docker compose up -d --build
```

数据库结构会在启动时自动迁移。升级到 0.8.0 后：所有账号都加密，客户端用密码登录时自动开启；已经开启加密的账号，之后用普通 pushkey（curl 等）发来的消息也由服务器加密保存（没有开关），**开启以前的明文历史消息也会在启动时由服务器在后台补加密**（日志里有「补加密明文消息」）。不支持加密的旧客户端只看到占位文字，「账号」页标出还没加密的账号和还在补加密的明文条数。补加密不会改动之前的备份。

升级到 0.9.0 后：管理后台只管理账号（见上文「账号」），消息、Pushkey、设备页和配对码都去掉了；客户端不能再进入管理后台（「允许管理」和一键进入后台都去掉了），后台只能在服务器上进入（见上文「进入管理后台」）。docker 的管理端口默认只绑宿主机本机（`HUIJIAN_ADMIN_BIND` 默认从 `0.0.0.0` 改成 `127.0.0.1`；`.env` 里写了的值不变），以前直接从公网打开后台的，改用 SSH 隧道，或者在 `.env` 里明确写 `HUIJIAN_ADMIN_BIND=0.0.0.0`。后台和命令行都不能再建账号，后台也不能再改任何账号的用户名和密码：账号只能由用户在新版客户端里注册（注册即开启加密，旧客户端注册返回「请更新回笺客户端后注册」），升级前注册模式是「关闭」的，要给别人开账号先改成「需要邀请码」。**服务器不再保存明文**：账号还没开启加密时，发给它的明文推送返回 403，服务端的系统通知（备份失败等）直接丢弃——升级前先确认要收消息的账号（尤其是接收系统通知的第一个账号）都已经在客户端用密码登录过、开启了加密（「账号」页显示「已加密」）。**「只接受加密消息」已取消**：之前打开过它的账号，升级后也会接收普通 pushkey 发来的消息（客户端标「明文发送」：服务器收到时能看到内容，随后立即加密保存，数据库和备份里没有明文）。要完全不让服务器看到内容，请在客户端吊销普通 pushkey，只用加密发送密钥发送。删除账号后，它用过的 pushkey 字符串不能再被任何账号认领，账号 id 也不复用。客户端和服务端可以分别升级：用不了的功能会在客户端上注明「更新服务端后可用」或「更新客户端后可用」。

### 从「鸿雁 Hongyan」升级

本项目 0.7.0 起由「鸿雁」改名为「回笺」。直接运行二进制的部署不用改配置就能升级，docker 部署另有几处调整（见下文）：

- 环境变量和配置项的旧前缀 `HONGYAN_*` 继续有效（新前缀 `HUIJIAN_*` 优先）；配置文件 `hongyan.conf`、旧的默认数据目录照常读取；
- 数据库 `hongyan.db` 原名沿用（这样回退到旧版本也找得到数据）；NAS 目录里的旧标记文件 `.hongyan` 继续有效（会补写一个 `.huijian`）；
- 一键更新下载的旧文件名、命令行发件箱 `~/.hongyan/outbox` 继续使用；
- 服务端同时返回新旧两套响应头，老客户端在更新前照常工作；客户端也认旧的 `hongyan://message/<id>` 链接。

用 docker compose 部署的：

- `.env` 不用改：compose 里每个 `HUIJIAN_*` 都会退回读取同名的 `HONGYAN_*`（以后有空可以把前缀改成新的）；
- 服务名和容器名从 `hongyan` 改成了 `huijian`：升级时加 `--remove-orphans`，旧容器会被移除，否则它还占着端口，新容器起不来；
- 复制过 `compose.override.yaml`（例如 NAS 配置）的，把里面的服务名 `hongyan:` 改成 `huijian:`；
- 用 docker 命名卷存数据的（没有设 `HONGYAN_DATA_DIR=./data`），在 `.env` 里写上旧卷名，否则会挂上一个新的空卷：

```bash
cd deploy/docker
sed -i.bak 's/^\( *\)hongyan:/\1huijian:/' compose.override.yaml 2>/dev/null   # 有这个文件时
docker volume ls | grep hongyan                                # 找到旧的数据卷，例如 docker_hongyan-data
echo 'HUIJIAN_DATA_VOLUME=docker_hongyan-data' >> .env          # 填上一步看到的名字；附件、备份卷同理：HUIJIAN_FILES_VOLUME / HUIJIAN_BACKUP_VOLUME
docker compose up -d --build --remove-orphans
```

管理后台的登录状态会失效一次，用 `docker exec huijian huijian admin-link` 重新登录即可。

客户端改名后是新的 App（包名不同），需要重新安装并登录；登录后会接管这台设备原来的记录（接收规则、Bark 转发不变），旧 App 随之退出登录，可以直接卸载。旧 App 里如果提示有新版本，不要点更新（包名不同，装不上），直接安装新 App。

从 0.4.0 以前的版本升级：旧版 compose 把数据放在 `deploy/docker/data` 目录。升级前在 `.env` 里加上 `HUIJIAN_DATA_DIR=./data`，否则会挂载一个新的空数据卷（旧数据仍在 `./data` 里，不会丢）。
