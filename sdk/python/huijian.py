# SPDX-License-Identifier: MIT
# Copyright (c) 2026 HongYile。本文件按 MIT 许可，可复制进任何项目（含闭源、商业项目）；回笺服务端和客户端为 AGPL-3.0。
"""回笺 Huijian Python SDK —— 单文件、只用标准库。

用法：
    import huijian
    huijian.push("训练完成", desp="val_loss 0.231", files=["loss.png"], priority=4,
                pushkey="PK_xxx")        # 或设置环境变量 HUIJIAN_PUSHKEY

    with huijian.run("exp42", topic="train"):   # 自动发送 开始(P4) / 结束(P4) / 异常(P5 + traceback)
        train()

环境变量：
    HUIJIAN_URL      服务器地址，可逗号分隔，按顺序尝试，例如 https://push.example.com
    HUIJIAN_PUSHKEY  接收方 pushkey，可逗号分隔
    （兼容旧名 BEACON_URL / BEACON_PUSHKEY）
"""
from __future__ import annotations

import contextlib
import json
import mimetypes
import os
import socket
import time
import traceback
import urllib.error
import urllib.request
import uuid

__all__ = ["push", "run", "HuijianError"]
__version__ = "0.3.0"

class HuijianError(Exception):
    pass


def _env(name: str) -> str:
    # 改名前的 HONGYAN_* / BEACON_* 也认
    return os.environ.get("HUIJIAN_" + name) or os.environ.get("HONGYAN_" + name) or os.environ.get("BEACON_" + name) or ""


def _urls(url: str | None) -> list[str]:
    raw = url or _env("URL")
    return [u.strip().rstrip("/") for u in raw.split(",") if u.strip()]


def _multipart(fields: dict, files: list[str]) -> tuple[bytes, str]:
    boundary = "----huijian" + uuid.uuid4().hex
    out: list[bytes] = []
    for k, v in fields.items():
        if v is None or v == "":
            continue
        out.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n'.encode())
        out.append(str(v).encode() + b"\r\n")
    for p in files:
        name = os.path.basename(p).replace('"', "_")
        ctype = mimetypes.guess_type(name)[0] or "application/octet-stream"
        out.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{name}"\r\n'
                   f"Content-Type: {ctype}\r\n\r\n".encode())
        with open(p, "rb") as f:
            out.append(f.read())
        out.append(b"\r\n")
    out.append(f"--{boundary}--\r\n".encode())
    return b"".join(out), f"multipart/form-data; boundary={boundary}"


def push(text: str = "", desp: str = "", *, files: list[str] | None = None, priority: int | None = None,
         topic: str = "", thread: str = "", type: str = "", pushkey: str | None = None,
         url: str | None = None, timeout: float = 120, raise_on_error: bool = False) -> list[str] | None:
    """发送一条消息，返回消息 id 列表；失败时返回 None（raise_on_error=True 时抛异常）。

    训练脚本里默认不抛异常：通知失败不应该打断训练。
    """
    key = pushkey or _env("PUSHKEY")
    try:
        if not key:
            raise HuijianError("缺少 pushkey（参数 pushkey= 或环境变量 HUIJIAN_PUSHKEY）")
        files = [os.path.abspath(p) for p in (files or [])]
        for p in files:
            if not os.path.isfile(p):
                raise HuijianError(f"附件不存在: {p}")
        fields = {"pushkey": key, "text": text, "desp": desp, "priority": priority,
                  "topic": topic, "thread": thread, "type": type,
                  "idem": "py_" + uuid.uuid4().hex[:24]}  # 幂等键：换地址重试时服务端只记一条
        body, ctype = _multipart(fields, files)
        last = None
        for base in _urls(url):
            req = urllib.request.Request(base + "/message/push", data=body, method="POST",
                                         headers={"Content-Type": ctype, "User-Agent": "huijian-py/" + __version__})
            try:
                with urllib.request.urlopen(req, timeout=timeout) as r:
                    data = json.loads(r.read() or b"{}")
                if data.get("code") == 0:
                    return data.get("content", {}).get("result", [])
                last = HuijianError(f"{base}: {data}")
            except urllib.error.HTTPError as e:
                msg = e.read()[:300].decode("utf-8", "replace")
                last = HuijianError(f"{base}: HTTP {e.code} {msg}")
                if 400 <= e.code < 500 and e.code not in (408, 429):
                    break  # 参数或权限错误，换地址也没用
            except (urllib.error.URLError, socket.timeout, ConnectionError, OSError) as e:
                last = HuijianError(f"{base}: {e}")
        raise last or HuijianError("没有服务器地址（参数 url= 或环境变量 HUIJIAN_URL）")
    except HuijianError:
        if raise_on_error:
            raise
        import sys
        print(f"[huijian] 发送失败: {sys.exc_info()[1]}", file=sys.stderr)
        return None


@contextlib.contextmanager
def run(name: str, *, topic: str = "train", pushkey: str | None = None, url: str | None = None,
        notify_start: bool = True):
    """包住一次实验：开始发 P4，正常结束发 P4（附耗时），异常发 P5（附 traceback 末尾）。"""
    host = socket.gethostname()
    t0 = time.time()
    if notify_start:
        push(f"▶️ {name} 开始", f"主机 {host}", priority=4, topic=topic, thread=name, pushkey=pushkey, url=url)
    try:
        yield
    except BaseException as e:
        dt = time.time() - t0
        tb = "".join(traceback.format_exception(type(e), e, e.__traceback__))[-3000:]
        push(f"❌ {name} 异常退出：{type(e).__name__}", f"主机 {host}，运行 {dt/60:.1f} 分钟\n\n```\n{tb}\n```",
             priority=5, topic=topic, thread=name, pushkey=pushkey, url=url)
        raise
    else:
        dt = time.time() - t0
        push(f"✅ {name} 完成", f"主机 {host}，用时 {dt/60:.1f} 分钟", priority=4, topic=topic, thread=name,
             pushkey=pushkey, url=url)
