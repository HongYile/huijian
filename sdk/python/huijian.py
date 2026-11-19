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
    （兼容旧名 HONGYAN_* / BEACON_*）

端到端加密：pushkey 用客户端「Pushkey」页复制的「加密发送密钥」（PK_xxx.e2e.<公钥>）时，标题、正文、附件
（含文件名）在本机加密后才发出，服务器只存密文。需要 cryptography 库（pip install cryptography）；
普通 pushkey 不需要任何第三方库。格式见 docs/e2ee.md，和服务端 Go 实现逐字节一致。
"""
from __future__ import annotations

import base64
import contextlib
import hashlib
import hmac
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
__version__ = "0.4.0"

class HuijianError(Exception):
    pass


def _env(name: str) -> str:
    # 改名前的 HONGYAN_* / BEACON_* 也认
    return os.environ.get("HUIJIAN_" + name) or os.environ.get("HONGYAN_" + name) or os.environ.get("BEACON_" + name) or ""


def _urls(url: str | None) -> list[str]:
    raw = url or _env("URL")
    return [u.strip().rstrip("/") for u in raw.split(",") if u.strip()]


def _multipart(fields: dict, files: list[str], encrypted: list[bytes] | None = None) -> tuple[bytes, str]:
    boundary = "----huijian" + uuid.uuid4().hex
    out: list[bytes] = []
    for k, v in fields.items():
        if v is None or v == "":
            continue
        out.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n'.encode())
        out.append(str(v).encode() + b"\r\n")
    for i, p in enumerate(files):
        if encrypted is not None:  # 真实文件名和类型在信封里
            name, ctype = f"encrypted-{i + 1}.bin", "application/octet-stream"
        else:
            name = os.path.basename(p).replace('"', "_")
            ctype = mimetypes.guess_type(name)[0] or "application/octet-stream"
        out.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{name}"\r\n'
                   f"Content-Type: {ctype}\r\n\r\n".encode())
        if encrypted is not None:
            out.append(encrypted[i])
        else:
            with open(p, "rb") as f:
                out.append(f.read())
        out.append(b"\r\n")
    out.append(f"--{boundary}--\r\n".encode())
    return b"".join(out), f"multipart/form-data; boundary={boundary}"


# ---------- 端到端加密（HPKE RFC 9180 base 模式：X25519 + HKDF-SHA256 + AES-256-GCM） ----------

_E2E_SEP = ".e2e."
_KEM = b"KEM\x00\x20"
_HPKE = b"HPKE\x00\x20\x00\x01\x00\x02"
_INFO_MESSAGE = b"huijian e2e v1 message"
_CHUNK = 64 << 10
_MAX_ENVELOPE = 120 << 10


def _b64e(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def _b64d(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def _crypto():
    try:
        from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    except ImportError:
        raise HuijianError("加密发送密钥需要 cryptography 库：pip install cryptography") from None
    return X25519PrivateKey, X25519PublicKey, AESGCM


def _lext(suite: bytes, salt: bytes, label: bytes, ikm: bytes) -> bytes:
    return hmac.new(salt, b"HPKE-v1" + suite + label + ikm, hashlib.sha256).digest()


def _lexp(suite: bytes, prk: bytes, label: bytes, info: bytes, n: int) -> bytes:
    full, t, out, i = n.to_bytes(2, "big") + b"HPKE-v1" + suite + label + info, b"", b"", 1
    while len(out) < n:
        t = hmac.new(prk, t + full + bytes([i]), hashlib.sha256).digest()
        out, i = out + t, i + 1
    return out[:n]


def _hpke_seal(pk_r: bytes, info: bytes, aad: bytes, pt: bytes, eph: bytes | None = None) -> tuple[bytes, bytes]:
    priv, pub, aesgcm = _crypto()
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
    e = priv.from_private_bytes(eph) if eph else priv.generate()
    enc = e.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    dh = e.exchange(pub.from_public_bytes(pk_r))
    shared = _lexp(_KEM, _lext(_KEM, b"", b"eae_prk", dh), b"shared_secret", enc + pk_r, 32)
    ctx = b"\x00" + _lext(_HPKE, b"", b"psk_id_hash", b"") + _lext(_HPKE, b"", b"info_hash", info)
    secret = _lext(_HPKE, shared, b"secret", b"")
    key, nonce = _lexp(_HPKE, secret, b"key", ctx, 32), _lexp(_HPKE, secret, b"base_nonce", ctx, 12)
    return enc, aesgcm(key).encrypt(nonce, pt, aad)


def _seal_message(pk: bytes, payload: bytes, eph: bytes | None = None) -> str:
    kid = hashlib.sha256(pk).digest()[:8].hex()
    aad = "hje1." + kid
    enc, ct = _hpke_seal(pk, _INFO_MESSAGE, aad.encode(), payload, eph)
    return aad + "." + _b64e(enc + ct)


def _encrypt_file(key: bytes, path: str) -> bytes:
    """附件分块加密：头 HJF1 + 块大小；每块 64 KB，nonce = 11 字节块序号 + 1 字节末块标记，附加数据 = 头"""
    aesgcm = _crypto()[2](key)
    hdr = b"HJF1" + _CHUNK.to_bytes(4, "big")
    out = [hdr]
    with open(path, "rb") as f:
        cur, i = f.read(_CHUNK), 0
        while True:
            nxt = f.read(_CHUNK) if len(cur) == _CHUNK else b""
            last = not nxt
            nonce = i.to_bytes(11, "big") + (b"\x01" if last else b"\x00")
            out.append(aesgcm.encrypt(nonce, cur, hdr))
            if last:
                return b"".join(out)
            cur, i = nxt, i + 1


def _split_send_keys(key: str) -> tuple[str, bytes | None]:
    """逗号分隔的 pushkey → (去掉公钥后的 pushkey, 公钥)；加密发送密钥必须属于同一个账号、不能和普通 pushkey 混用"""
    keys, pub, plain = [], None, False
    for k in (x.strip() for x in key.split(",")):
        if not k:
            continue
        pk, sep, p = k.partition(_E2E_SEP)
        keys.append(pk)
        if not sep:
            plain = True
            continue
        try:
            raw = _b64d(p)
        except ValueError:
            raw = b""
        if len(raw) != 32:
            raise HuijianError("加密发送密钥里的公钥格式不对")
        if pub is not None and raw != pub:
            raise HuijianError("多个加密发送密钥属于不同的账号：加密消息只能一次发给同一个账号")
        pub = raw
    if pub is not None and plain:
        raise HuijianError("加密发送密钥不能和普通 pushkey 混在一起发送")
    return ",".join(keys), pub


def _e2e_seal(pub: bytes, text: str, desp: str, type: str, files: list[str]) -> tuple[str, list[bytes]]:
    """把标题、正文、附件信息封进信封；返回信封和加密后的附件。截断规则和 huijian 命令行一致"""
    keys = [os.urandom(32) for _ in files]
    atts = [{"name": os.path.basename(p), "mime": mimetypes.guess_type(p)[0] or "application/octet-stream",
             "size": os.path.getsize(p), "key": _b64e(k)} for p, k in zip(files, keys)]
    text = text[:2000]
    body = desp.encode("utf-8")[: 64 << 10]
    while True:
        p = {"v": 1}
        if text:
            p["text"] = text
        d = body.decode("utf-8", "ignore")
        if d:
            p["desp"] = d
        if type:
            p["type"] = type
        if atts:
            p["atts"] = atts
        env = _seal_message(pub, json.dumps(p, ensure_ascii=False, separators=(",", ":")).encode())
        if len(env) <= _MAX_ENVELOPE:
            return env, [_encrypt_file(k, f) for k, f in zip(keys, files)]
        if not body:
            raise HuijianError("加密后的内容太长：标题或附件太多，请精简")
        body = body[: len(body) * 4 // 5]


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
        idem = "py_" + uuid.uuid4().hex[:24]  # 幂等键：换地址重试时服务端只记一条
        key, pub = _split_send_keys(key)
        if pub is not None:  # 加密发送密钥：标题、正文、附件都在本机加密，服务器只看到优先级、频道、线程
            env, enc_files = _e2e_seal(pub, text, desp, type, files)
            fields = {"pushkey": key, "e2e": env, "priority": priority, "topic": topic, "thread": thread, "idem": idem}
            body, ctype = _multipart(fields, files, enc_files)
        else:
            fields = {"pushkey": key, "text": text, "desp": desp, "priority": priority,
                      "topic": topic, "thread": thread, "type": type, "idem": idem}
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
