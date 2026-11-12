#!/usr/bin/env python3
"""本地 WebDAV 行为矩阵服务，用于覆盖真实 NAS 常见情况。

python3 Tools/webdav_matrix_server.py [port]   # 默认 8770

端点：
  /health            200 文本，用于探测
  /dav/              Basic 认证 + 207 目录树（含子目录与 mp3/flac/wav）
  /redirect/         301 -> /dav/（验证同源重定向）
  /digest/           Digest 认证（MD5/qop=auth）+ 207
  /html/             PROPFIND 返回 200 HTML（验证友好报错）
  /partial/          207 中混有一个 403 条目（验证跳过坏条目）
  /empty/            207 空目录

仅本机测试用；不处理真实文件内容，不用于生产。
"""
import base64
import hashlib
import http.server
import os
import socketserver
import sys
import urllib.parse

TLS = "--tls" in sys.argv
ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
PORT = int(ARGS[0]) if ARGS else (8771 if TLS else 8770)
BASIC_USER, BASIC_PASS = "u", "p"
DIGEST_USER, DIGEST_PASS = "u", "p"
DIGEST_REALM, DIGEST_NONCE, DIGEST_OPAQUE = "nas", "nonce-abc123", "opaque-xyz"

TREE = {
    "/dav/": ["Album/", "root.flac"],
    "/dav/Album/": ["Song.mp3", "Live 版.wav"],
}


def md5(text):
    return hashlib.md5(text.encode("utf-8")).hexdigest()


def xml_entry(href, is_dir=False, status="HTTP/1.1 200 OK"):
    size = 0 if is_dir else 1024
    collection = "<d:collection/>" if is_dir else ""
    return (
        "<d:response><d:href>%s</d:href><d:propstat><d:prop>"
        "<d:displayname>%s</d:displayname><d:resourcetype>%s</d:resourcetype>"
        "<d:getcontentlength>%d</d:getcontentlength></d:prop>"
        "<d:status>%s</d:status></d:propstat></d:response>"
        % (href, urllib.parse.unquote(href.rstrip("/").split("/")[-1]), collection, size, status)
    )


def multistatus(entries):
    return (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<d:multistatus xmlns:d="DAV:">%s</d:multistatus>' % "".join(entries)
    ).encode("utf-8")


def basic_ok(header):
    if not header or not header.startswith("Basic "):
        return False
    try:
        raw = base64.b64decode(header[6:]).decode("utf-8")
    except Exception:
        return False
    return raw == "%s:%s" % (BASIC_USER, BASIC_PASS)


def digest_ok(header, method):
    if not header or not header.startswith("Digest "):
        return False
    fields = {}
    for part in header[len("Digest "):].split(","):
        if "=" not in part:
            continue
        key, value = part.strip().split("=", 1)
        fields[key] = value.strip().strip('"')
    if fields.get("nonce") != DIGEST_NONCE:
        return False
    ha1 = md5("%s:%s:%s" % (fields.get("username", ""), DIGEST_REALM, DIGEST_PASS))
    ha2 = md5("%s:%s" % (method, fields.get("uri", "")))
    expected = md5(
        "%s:%s:%s:%s:auth:%s"
        % (ha1, DIGEST_NONCE, fields.get("nc", ""), fields.get("cnonce", ""), ha2)
    )
    return expected == fields.get("response") and fields.get("username") == DIGEST_USER


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        if os.environ.get("AWAKE_DAV_DEBUG"):
            sys.stderr.write("%s %s auth=%s\n" % (self.command, self.path, (self.headers.get("Authorization") or "-")[:24]))
            sys.stderr.flush()

    def send(self, status, body=b"", content_type="application/xml; charset=utf-8", headers=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def unauthorized_basic(self):
        self.send(401, b"", "text/plain", {"WWW-Authenticate": 'Basic realm="dav"'})

    def unauthorized_digest(self):
        self.send(
            401,
            b"",
            "text/plain",
            {
                "WWW-Authenticate": 'Digest realm="%s", qop="auth", nonce="%s", opaque="%s", algorithm=MD5'
                % (DIGEST_REALM, DIGEST_NONCE, DIGEST_OPAQUE)
            },
        )

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path in ("/health", "/"):
            self.send(200, b"Awake WebDAV matrix fixture", "text/plain")
        else:
            self.send(404, b"not found", "text/plain")

    def do_PROPFIND(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        path = urllib.parse.urlparse(self.path).path
        if path == "/dav/" or path.startswith("/dav/"):
            if not basic_ok(self.headers.get("Authorization", "")):
                return self.unauthorized_basic()
            if path not in TREE:
                return self.send(404, b"not found", "text/plain")
            entries = [xml_entry(path, True)]
            for name in TREE[path]:
                is_dir = name.endswith("/")
                entries.append(xml_entry(path + urllib.parse.quote(name), is_dir))
            return self.send(207, multistatus(entries))
        if path == "/redirect/":
            return self.send(301, b"", "text/plain", {"Location": "/dav/"})
        if path == "/cross/":
            return self.send(301, b"", "text/plain", {"Location": "http://localhost:%d/dav/" % PORT})
        if path.startswith("/redirect/"):
            return self.send(404, b"not found", "text/plain")
        if path == "/digest/":
            if not digest_ok(self.headers.get("Authorization", ""), "PROPFIND"):
                return self.unauthorized_digest()
            return self.send(
                207,
                multistatus([xml_entry("/digest/", True), xml_entry("/digest/Digest Song.mp3")]),
            )
        if path == "/html/":
            return self.send(
                200,
                b"<!DOCTYPE html><html><head><title>NAS</title></head><body>\xe5\x90\xaf\xe7\x94\xa8</body></html>",
                "text/html; charset=utf-8",
            )
        if path == "/partial/":
            return self.send(
                207,
                multistatus(
                    [
                        xml_entry("/partial/", True),
                        xml_entry("/partial/Blocked.mp3", False, "HTTP/1.1 403 Forbidden"),
                        xml_entry("/partial/Readable.mp3"),
                    ]
                ),
            )
        if path == "/empty/":
            return self.send(207, multistatus([xml_entry("/empty/", True)]))
        self.send(404, b"not found", "text/plain")

    def do_HEAD(self):
        self.do_GET()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def tls_context():
    """用 openssl 临时生成 127.0.0.1 自签名证书，验证客户端“允许自签名证书”开关。"""
    import ssl
    import subprocess
    import tempfile

    directory = tempfile.mkdtemp(prefix="awake-dav-tls-")
    cert = os.path.join(directory, "cert.pem")
    key = os.path.join(directory, "key.pem")
    subprocess.run(
        [
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "2",
            "-nodes", "-keyout", key, "-out", cert, "-subj", "/CN=127.0.0.1",
            "-addext", "subjectAltName=IP:127.0.0.1",
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    return context


if __name__ == "__main__":
    os.environ.setdefault("PYTHONUNBUFFERED", "1")
    with Server(("127.0.0.1", PORT), Handler) as server:
        scheme = "http"
        if TLS:
            server.socket = tls_context().wrap_socket(server.socket, server_side=True)
            scheme = "https"
        print("webdav matrix fixture on %s://127.0.0.1:%d" % (scheme, PORT), flush=True)
        server.serve_forever()
