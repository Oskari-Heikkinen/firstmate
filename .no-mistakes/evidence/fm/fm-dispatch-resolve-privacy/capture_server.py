#!/usr/bin/env python3
"""Local stand-in for https://api.typesafe.ai: records every request exactly as
received on the wire (method, path, headers, body) and answers from a mode file."""
import http.server, json, os, sys
LOG = os.environ["CAPTURE_LOG"]; MODE = os.environ["CAPTURE_MODE"]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); body = self.rfile.read(n).decode()
        with open(LOG, "a") as f:
            f.write(json.dumps({"method": "POST", "path": self.path, "headers": dict(self.headers), "body": body}) + "\n")
        mode = open(MODE).read().strip()
        if mode == "ok":
            code, resp = 200, {"model": "jev-1.13.0", "answers": {"rule": {"type": "choice", "choice": "rule_2", "confidence": 0.91,
                "probabilities": {"rule_1": 0.03, "rule_2": 0.91, "rule_3": 0.03, "default": 0.03}}}, "usage": {"input_tokens": 300, "output_tokens": 40}}
        elif mode == "429":
            code, resp = 429, {"error": "rate limited"}
        else:
            code, resp = 500, {"error": "internal"}
        out = json.dumps(resp).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
