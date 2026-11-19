#!/usr/bin/env python3
"""生成服务端更新清单 update-server.json（release_github.sh 和测试共用，保证格式一致）。
用法：server_manifest.py <huijian 可执行文件> <签名私钥> <版本> <构建号> <更新说明> <程序文件>...
程序文件名必须是 huijian-<版本>-<系统>-<架构>，例如 huijian-0.6.0-linux-arm64。输出 JSON 到标准输出。
"""
import json, os, re, subprocess, sys

hy, key, ver, build, notes = sys.argv[1:6]
notes = notes.strip()  # 与 huijian release 一致：签名前去掉首尾空白
plats = {}
for path in sys.argv[6:]:
    name = os.path.basename(path)
    m = re.fullmatch(re.escape("huijian-" + ver + "-") + r"([a-z0-9]+-[a-z0-9]+)", name)
    if not m:
        sys.exit(f"文件名不对：{name}，应为 huijian-{ver}-<系统>-<架构>")
    out = subprocess.run([hy, "release", "-dry", "-key", key, "-platform", "server-" + m.group(1), "-version", ver,
                          "-build", build, "-notes", notes, path], check=True, capture_output=True, text=True).stdout
    kv = dict(l.split(None, 1) for l in out.splitlines()[1:] if l.strip())
    plats[m.group(1)] = {"file": name, "size": os.path.getsize(path),
                         "sha256": kv["sha256"].strip(), "signature": kv["signature"].strip()}
print(json.dumps({"version": ver, "build": int(build), "notes": notes, "platforms": plats}, ensure_ascii=False, indent=1))
