#!/usr/bin/env python3
"""生成 GitHub 更新源的签名清单 update-macos.json（release_github.sh 和自检共用，保证格式一致）。
用法：make_manifest.py <huijian 可执行文件> <签名私钥> <版本> <构建号> <更新说明> <zip 路径>  → 输出 JSON
"""
import json, os, subprocess, sys

hy, key, ver, build, notes, zp = sys.argv[1:7]
notes = notes.strip()  # 与 huijian release 一致：签名前去掉首尾空白
out = subprocess.run([hy, "release", "-dry", "-key", key, "-platform", "macos", "-version", ver,
                      "-build", build, "-notes", notes, zp], check=True, capture_output=True, text=True).stdout
kv = dict(l.split(None, 1) for l in out.splitlines()[1:] if l.strip())
print(json.dumps({"version": ver, "build": int(build), "notes": notes, "size": os.path.getsize(zp),
                  "sha256": kv["sha256"].strip(), "signature": kv["signature"].strip(),
                  "zip": os.path.basename(zp)}, ensure_ascii=False, indent=1))
