import http.server, itertools, json, os, sys
out = sys.argv[1]
seq = itertools.count()
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length") or 0))
        name = "%03d%s.json" % (next(seq), self.path.split("?")[0].replace("/", "_"))
        with open(os.path.join(out, name), "wb") as f:
            f.write(body)
        reply = json.dumps({"type": "error", "error": {"type": "invalid_request_error", "message": "capture only"}}).encode()
        self.send_response(400)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)
    def do_GET(self):
        self.send_response(404)
        self.send_header("content-length", "0")
        self.end_headers()
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(out, "port"), "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
