#!/usr/bin/env python3
"""fake_plex_server.py — 一个说 Plex 官方 XML 协议的本地假服务器。

用途：把「连上 Plex → 扫描 → 入库 → 曲库可见」整条链在模拟器里跑一遍。
真实 Plex 账号/服务器不可得的时候，这是唯一能自动复现这条链的办法；
配合 Tools/e2e_ios_plex_visibility.sh 使用。

只实现 Awake 用到的三个端点：
  GET /library/sections
  GET /library/sections/<key>/all?type=10&X-Plex-Container-Start=..&X-Plex-Container-Size=..
  GET /library/parts/<id>/<ver>/<name>        （返回一段可解码的 WAV）
  GET /library/metadata/<id>/thumb/<ver>      （返回 1x1 PNG，用于封面）

每个请求都追加到日志文件（系统安全临时文件，路径打印到 stdout 的 log=…），作为「客户端到底问了什么」的证据。

用法:
  python3 Tools/fake_plex_server.py [--port 32400]
"""
import io
import os
import struct
import sys
import tempfile
import threading
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
from pathlib import Path

TOKEN = "e2e-token"

# (ratingKey, title, artist, album, duration_ms, part key)
CATALOG = [
    ("101", "夜航·测试曲一", "Awake Lab", "夜航", 200000, "/library/parts/1/1700000001/one.wav"),
    ("102", "夜航·测试曲二", "Awake Lab", "夜航", 180000, "/library/parts/2/1700000002/two.wav"),
    ("103", "电波·测试曲三", "Signal Test", "电波", 240000, "/library/parts/3/1700000003/three.wav"),
]

LOG_PATH = ""
LOG_LOCK = threading.Lock()
LOG_FILE = None


def wav_bytes(seconds=3.0, rate=44100):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(rate)
        n = int(seconds * rate)
        frames = bytearray()
        period = max(1, rate // 220)
        for i in range(n):
            v = 8000 if (i // period) % 2 else -8000
            frames += struct.pack("<hh", v, v)
        w.writeframes(bytes(frames))
    return buf.getvalue()


AUDIO = wav_bytes()


def sections_xml():
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<MediaContainer size="2" allowSync="0" identifier="com.plexapp.plugins.library">'
        '<Directory allowSync="0" art="/:/resources/artist-fanart.jpg" librarySectionID="1" '
        'librarySectionTitle="音乐" librarySectionUUID="e2e-lib" ratingKey="1" key="1" '
        'type="artist" title="音乐" agent="tv.plex.agents.music" scanner="Plex Music" '
        'language="zh-CN" uuid="e2e-lib"/>'
        '<Directory allowSync="0" librarySectionID="2" librarySectionTitle="电影" ratingKey="2" '
        'key="2" type="movie" title="电影" agent="tv.plex.agents.movie" scanner="Plex Movie"/>'
        '</MediaContainer>'
    )


def tracks_xml(start, size):
    rows = CATALOG[start:start + size]
    body = []
    for index, (rk, title, artist, album, dur, part) in enumerate(CATALOG, start=1):
        body.append(
            f'<Track ratingKey="{rk}" key="/library/metadata/{rk}" guid="local://{rk}" '
            f'type="track" title="{title}" grandparentTitle="{artist}" parentTitle="{album}" '
            f'parentRatingKey="9{index}" grandparentRatingKey="8{index}" '
            f'index="{index}" parentIndex="1" year="2024" duration="{dur}" '
            f'parentThumb="/library/metadata/9{index}/thumb/1700000000" '
            f'grandparentThumb="/library/metadata/8{index}/thumb/1700000000" '
            f'addedAt="1700000000" updatedAt="1700000000">'
            f'<Media id="{rk}0" duration="{dur}" bitrate="900" audioChannels="2" '
            f'audioCodec="pcm" container="wav">'
            f'<Part id="{rk}1" key="{part}" duration="{dur}" file="/music/x.wav" '
            f'size="529244" container="wav"/>'
            f'</Media></Track>'
        )
    total = len(CATALOG)
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        f'<MediaContainer size="{len(rows)}" totalSize="{total}" offset="{start}" '
        f'identifier="com.plexapp.plugins.library">{"".join(body)}</MediaContainer>'
    )


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _log(self, note):
        if LOG_FILE is None:
            return
        with LOG_LOCK:
            LOG_FILE.write(note + "\n")
            LOG_FILE.flush()

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        token = self.headers.get("X-Plex-Token", "")
        self._log(f"GET {self.path} token={'yes' if token == TOKEN else 'MISSING/OTHER'}")
        if not token:
            self.send_response(401)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if u.path == "/library/sections":
            return self._xml(sections_xml())
        if u.path.startswith("/library/sections/") and u.path.endswith("/all"):
            start = int(q.get("X-Plex-Container-Start", ["0"])[0])
            size = int(q.get("X-Plex-Container-Size", ["500"])[0])
            return self._xml(tracks_xml(start, size))
        if u.path.startswith("/library/parts/"):
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(AUDIO)))
            self.send_header("Accept-Ranges", "bytes")
            self.end_headers()
            self.wfile.write(AUDIO)
            return
        if u.path.startswith("/library/metadata/") and "/thumb/" in u.path:
            png = bytes.fromhex("89504e470d0a1a0a") + b"\x00" * 64
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(png)))
            self.end_headers()
            self.wfile.write(png)
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _xml(self, text):
        data = text.encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/xml; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main():
    global LOG_FILE, LOG_PATH
    port = 32400
    if "--port" in sys.argv:
        port = int(sys.argv[sys.argv.index("--port") + 1])
    # 唯一的文件打开点：系统安全临时文件 API（不可预测、原子打开，防符号链接抢占）；
    # 实际路径打印到 stdout 供脚本解析，不再接受调用方指定任意路径。
    LOG_FILE = tempfile.NamedTemporaryFile(
        prefix="fake_plex_", suffix=".log", delete=False, mode="w", encoding="utf-8"
    )
    LOG_PATH = LOG_FILE.name
    print(f"fake plex on http://127.0.0.1:{port} token={TOKEN} log={LOG_PATH}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
