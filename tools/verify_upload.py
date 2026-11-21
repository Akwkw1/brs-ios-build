import http.server, socketserver, threading, os, uuid, urllib.request, urllib.parse

SRC = "../../fw-lite.bin"  # 相对 bradar/ios/tools/
DUMP = "/tmp/upload.raw"
if os.path.exists(DUMP): os.remove(DUMP)

def build(source, field, filename, boundary):
    """逐行对应 Sources/Net.swift Multipart.build(同一 CRLF 布局)"""
    head = ("--%s\r\n" % boundary
            + "Content-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\n" % (field, filename)
            + "Content-Type: application/octet-stream\r\n\r\n").encode()
    foot = ("\r\n--%s--\r\n" % boundary).encode()
    with open(source, "rb") as f:
        return head + f.read() + foot

class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers['Content-Length'])
        body = self.rfile.read(n)
        open(DUMP, 'wb').write(body)
        print("REQ  path=%s" % self.path)
        print("REQ  content-type=%s" % self.headers['Content-Type'])
        print("REQ  content-length=%d" % n)
        self.send_response(303); self.send_header('Location', '/'); self.end_headers()
    def log_message(self, *a): pass

socketserver.TCPServer.allow_reuse_address = True
srv = socketserver.TCPServer(('127.0.0.1', 8899), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()

boundary = "BlackRadar" + uuid.uuid4().hex + uuid.uuid4().hex[:8]
body = build(SRC, "f", "firmware.bin", boundary)
url = "http://127.0.0.1:8899/upload?dir=" + urllib.parse.quote("/update", safe="")
req = urllib.request.Request(url, data=body, method="POST",
        headers={"Content-Type": "multipart/form-data; boundary=%s" % boundary})
try:
    with urllib.request.urlopen(req) as resp:
        print("RESP status=%d" % resp.status)
except urllib.error.HTTPError as e:
    # 303 之后 urllib 会跟一个 GET,假服务器只实现 POST → 501。上传本身已成功。
    print("POST 已完成,303 之后的 GET 落到假服务器 -> %s(预期)" % e)
srv.shutdown()

raw = open(DUMP, 'rb').read()
he = raw.index(b'\r\n\r\n') + 4
te = raw.rindex(b'\r\n--')
payload = raw[he:te]
src = open(SRC, 'rb').read()
print("HEAD:", raw[:he].decode('utf-8', 'replace').replace('\r\n', ' | '))
print("ENVELOPE-FREE MATCH: %s  (%d vs %d bytes)" % (payload == src, len(payload), len(src)))
print("FIRST BYTES of payload: %s ... (ESP32 image magic 0xE9=%s)" %
      (payload[:4].hex(), payload[0] == 0xE9))
