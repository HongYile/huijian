#!/usr/bin/env python3
"""自检用的本地模拟服务：
  - 模拟 GitHub API：/repos/<repo>/releases/latest 与 /dl/<文件>（文件来自 <目录>）
  - HTTP 代理：转发绝对 URI 的请求，并记录经过代理的 URL
所有请求写入日志，并标记是否带 Authorization 头（发往 GitHub 的请求不应带设备 token）。
用法：mock_net.py <GitHub端口> <代理端口> <文件目录> <日志文件>
"""
import json, os, sys, threading, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GH, PX, DIR, LOG = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
lock = threading.Lock()

def log(line):
    with lock, open(LOG, "a") as f:
        f.write(line + "\n")

class GitHub(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        auth = "AUTH" if self.headers.get("Authorization") else "NOAUTH"
        log(f"GH {auth} {self.path}")
        if self.path.endswith("/releases/latest"):
            assets = [{"name": n, "browser_download_url": f"http://127.0.0.1:{GH}/dl/{n}"} for n in sorted(os.listdir(DIR))]
            body = json.dumps({"tag_name": "vtest", "assets": assets}).encode()
        elif self.path == "/zen":
            body = b"ok"
        elif self.path.startswith("/dl/"):
            p = os.path.join(DIR, os.path.basename(self.path))
            if not os.path.isfile(p):
                self.send_error(404); return
            body = open(p, "rb").read()
        else:
            self.send_error(404); return
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

class Proxy(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        log(f"PROXY {self.path}")
        if not self.path.startswith("http://"):
            self.send_error(400); return
        req = urllib.request.Request(self.path, headers={k: v for k, v in self.headers.items()
                                                         if k.lower() not in ("proxy-connection", "connection", "host")})
        try:
            with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=60) as r:
                body, code, hdrs = r.read(), r.status, r.headers
        except urllib.error.HTTPError as e:
            body, code, hdrs = e.read(), e.code, e.headers
        self.send_response(code)
        for k, v in hdrs.items():
            if k.lower() not in ("transfer-encoding", "connection", "content-length"):
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

for port, h in ((GH, GitHub), (PX, Proxy)):
    threading.Thread(target=ThreadingHTTPServer(("127.0.0.1", port), h).serve_forever, daemon=True).start()
threading.Event().wait()
