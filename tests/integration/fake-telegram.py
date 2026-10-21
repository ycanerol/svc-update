#!/usr/bin/python3 -I
"""Fake Telegram Bot API for tests: records sendMessage etc. in /srv/faketg/*.jsonl, serves injected updates."""
import glob, html, json, os, re, time, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
D = "/srv/faketg"
os.makedirs(D + "/inject", exist_ok=True)

def updates(offset):
    out = []
    for p in sorted(glob.glob(D + "/inject/*.json")):
        u = json.load(open(p))
        if offset is not None and offset >= 0 and u["update_id"] < offset:
            os.unlink(p); continue
        out.append(u)
    if offset == -1:
        out = out[-1:]
    return out

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        p = {k: v[0] for k, v in urllib.parse.parse_qs(self.rfile.read(n).decode()).items()}
        token, _, method = self.path[len("/bot"):].partition("/")
        if not token.startswith("123456:"):
            return self.reply(401, {"ok": False})
        if method == "getMe":
            r = {"id": 42, "is_bot": True, "username": "adama_test_bot"}
        elif method == "getUpdates":
            off = int(p["offset"]) if "offset" in p else None
            deadline = time.time() + min(int(p.get("timeout", 0)), 5)
            r = updates(off)
            while not r and time.time() < deadline:
                time.sleep(0.3); r = updates(off)
        else:
            if "text" in p:
                p["visible"] = html.unescape(re.sub(r"<[^>]+>", "", p["text"]))
            if "reply_markup" in p:
                p["reply_markup"] = json.loads(p["reply_markup"])
            with open(D + "/%s.jsonl" % method, "a") as f:
                f.write(json.dumps(p, ensure_ascii=False) + "\n")
            r = {"message_id": int(time.time() * 1000)} if method == "sendMessage" else True
        self.reply(200, {"ok": True, "result": r})

    def reply(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def log_message(self, *a):
        pass

ThreadingHTTPServer(("127.0.0.1", 8081), H).serve_forever()
