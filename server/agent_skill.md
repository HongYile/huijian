---
name: huijian
description: 通过回笺（Huijian）给用户发加密通知、向用户提问并等用户在手机/电脑上回复。长任务结束或失败、需要用户决定、用户说「通知我 / 问我 / 发到手机」时使用。
---

# 回笺：给用户发消息、问用户问题

（本文件由 huijian agent setup 安装，huijian agent setup -remove 会删除。）

你已经通过 MCP 接入了回笺（服务器名 `huijian`），有三个工具：

| 工具 | 用途 |
|:--|:--|
| `notify(title, body?, priority?)` | 发一条消息，不等回复。长任务完成、失败、阶段结果 |
| `ask(question, body?, choices?, timeout_seconds?)` | 问用户并等回复（默认最多等 30 分钟）。只在确实需要用户决定时用 |
| `check_replies()` | 取之后才到的回复：ask 超时后用户才回的，或 ask 拿到回复后用户又补充的 |

## 怎么用

- **标题说结论**：「训练完成，val_loss 0.198」好过「任务更新」。正文用 Markdown，关键数字放前两行。
- **优先级**：拿不准用 3；4 = 用户在等的结果（会响铃）；5 = 必须马上处理（免打扰也提醒），不要滥用。
- **ask 的选项**：`choices` 最多 4 个、每个最长 20 字。用户可以选选项再写补充，一起发送：回复第一行是选项，后面是补充，要连补充一起理解；用户也可以不选、只打字。
- **ask 拿到第一条回复就返回**，用户之后可能还会补充：继续做下一步之前、结束任务之前，调用一次 `check_replies`。
- **工具调用有时间上限的客户端**（例如 Cursor 命令行固定 60 秒）：`ask` 传 `timeout_seconds: 50`，超时后反复调用 `check_replies(wait_seconds: 50)`，直到拿到回复或你决定不等。
- **ask 超时**：用户可能在忙。按最稳妥的默认做法继续或停下，在之后的 notify 里说明；之后用 `check_replies` 看用户有没有回。
- 不要在消息里放密码、token、密钥。

## 没有 MCP 时（命令行）

```bash
huijian agent send -p 4 -d "正文" "标题"                 # 发消息
huijian agent ask -timeout 30m -choice 继续 -choice 停止 "问题"   # 问并等回复，回复打印到标准输出
huijian agent replies -wait 5                             # 取之后才到的回复（每行一条 JSON）
huijian agent status                                      # 会话和接入情况
```
