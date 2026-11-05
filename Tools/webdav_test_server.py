#!/usr/bin/env python3
"""本地 WebDAV 测试服务：python3 Tools/webdav_test_server.py <root> [port]
仅实现 PROPFIND(Depth:1) 与静态 GET，够验证递归索引与远程取回。
用法示例：
  python3 Tools/webdav_test_server.py DemoMusic 8765
  AWAKE_DAV_URL=http://127.0.0.1:8765/dav swift test --filter WebDAVTests
"""
import http.server, socketserver, os, urllib.parse, datetime
import sys
ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "DemoMusic")
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8765
class H(http.server.SimpleHTTPRequestHandler):
    def translate_path(self, path):
        path = urllib.parse.unquote(urllib.parse.urlparse(path).path)
        rel = path[len("/dav/"):] if path.startswith("/dav/") else ""
        return os.path.normpath(os.path.join(ROOT, rel))
    def do_PROPFIND(self):
        p = self.translate_path(self.path)
        rel = os.path.relpath(p, ROOT)
        href_base = "/dav"
        def entry(name, full):
            st = os.stat(full)
            isdir = os.path.isdir(full)
            href = href_base + "/" + urllib.parse.quote(os.path.relpath(full, ROOT)) if full != ROOT else href_base + "/"
            if isdir and not href.endswith("/"): href += "/"
            size = 0 if isdir else st.st_size
            return f"""<d:response><d:href>{href}</d:href><d:propstat><d:prop><d:displayname>{name}</d:displayname><d:resourcetype>{'<d:collection/>' if isdir else ''}</d:resourcetype><d:getcontentlength>{size}</d:getcontentlength><d:getlastmodified>{datetime.datetime.fromtimestamp(st.st_mtime, datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S GMT')}</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"""
        parts = [entry(os.path.basename(p), p)]
        if os.path.isdir(p):
            for name in sorted(os.listdir(p)):
                parts.append(entry(name, os.path.join(p, name)))
        body = ('<?xml version="1.0" encoding="utf-8"?><d:multistatus xmlns:d="DAV:">' + "".join(parts) + "</d:multistatus>").encode()
        self.send_response(207)
        self.send_header("Content-Type", "application/xml; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", PORT), H) as s:
    s.serve_forever()