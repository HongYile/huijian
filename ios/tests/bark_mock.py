"""模拟 Bark 服务器：把收到的推送请求（表单）按行写成 JSON，返回 Bark 的成功响应。
用法：python3 tests/bark_mock.py <端口> <日志文件>
路径里的 key 为 badkey 时返回 400（模拟 key 不对），用来测试失败提示。"""
import json
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

port, log_path = int(sys.argv[1]), sys.argv[2]


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        form = {k: v[0] for k, v in urllib.parse.parse_qs(self.rfile.read(n).decode()).items()}
        key = self.path.strip("/").split("/")[0]
        with open(log_path, "a") as f:
            f.write(json.dumps({"key": key, "form": form}, ensure_ascii=False) + "\n")
        if key == "badkey":
            body, code = {"code": 400, "message": "failed to get device token"}, 400
        else:
            body, code = {"code": 200, "message": "success"}, 200
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


HTTPServer(("127.0.0.1", port), H).serve_forever()
