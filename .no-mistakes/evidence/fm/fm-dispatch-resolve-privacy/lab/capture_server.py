import http.server, json, os, sys
OUT = sys.argv[2]; STATUS = int(os.environ.get("CAP_STATUS", "200"))
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); body = self.rfile.read(n)
        idx = len([f for f in os.listdir(OUT) if f.startswith("req")]) + 1
        with open(os.path.join(OUT, f"req{idx:02d}.raw"), "wb") as f:
            f.write(f"{self.command} {self.path} {self.request_version}\n".encode())
            for k, v in self.headers.items(): f.write(f"{k}: {v}\n".encode())
            f.write(b"\n" + body)
        st = int(open(os.path.join(OUT, "status")).read().strip()) if os.path.exists(os.path.join(OUT, "status")) else 200
        if st == 200:
            q = json.loads(body)["questions"]["rule"]["criteria"]; keys = list(q)
            probs = {k: (0.96 if k == "rule_2" else round(0.04/(len(keys)-1), 4)) for k in keys}
            resp = {"model": "jev-1.13.0", "answers": {"rule": {"type": "choice", "choice": "rule_2", "confidence": 0.9, "probabilities": probs}}, "usage": {"input_tokens": 120, "output_tokens": 60}}
        else:
            resp = {"type": "error", "error": {"type": "authentication_error", "message": "invalid api key"}}
        data = json.dumps(resp).encode()
        self.send_response(st); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
