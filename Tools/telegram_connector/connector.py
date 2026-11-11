#!/usr/bin/env python3
"""User-hosted, read-only Telegram audio connector. No central account or source catalog.

Login is deliberately confined to the host terminal; HTTP never accepts login codes.
The HTTP service exposes only explicitly created collections, with bearer authentication.
"""
from __future__ import annotations

import argparse
import asyncio
import concurrent.futures
import contextlib
import hashlib
import hmac
import json
import math
import os
from pathlib import Path
import queue
import re
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, urlsplit

EXTENSIONS = {"mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "alac", "ogg", "opus", "caf"}
MAX_BODY = 65536
CHUNK = 65536


class ConnectorError(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


def byte_range(value, size):
    """One RFC 9110 byte range. Reject multipart and unsatisfiable ranges."""
    if not value:
        return 0, size - 1, False
    match = re.fullmatch(r"bytes=(\d*)-(\d*)", value)
    if not match or not any(match.groups()) or size <= 0:
        raise ConnectorError("无效的字节范围", 416)
    first, last = match.groups()
    if first:
        start, end = int(first), min(int(last) if last else size - 1, size - 1)
    else:
        length = int(last)
        if length <= 0:
            raise ConnectorError("无效的字节范围", 416)
        start, end = max(0, size - length), size - 1
    if start >= size or end < start:
        raise ConnectorError("字节范围超出文件", 416)
    return start, end, True


def audio_row(message, chat_id, album):
    file = message.file
    if not file or getattr(message, "noforwards", False):
        return None
    name = file.name or ("audio" + (file.ext or ""))
    name = Path(name.replace("\\", "/")).name
    extension = name.rsplit(".", 1)[-1].lower()
    if extension not in EXTENSIONS or not file.size or file.size > 4 * 1024**3:
        return None
    duration = file.duration or 0
    if not math.isfinite(duration) or duration < 0:
        duration = 0
    username = getattr(message.chat, "username", None)
    origin = ""
    if username:
        origin = f"https://t.me/{username}/{message.id}"
    elif str(chat_id).startswith("-100"):
        origin = f"https://t.me/c/{str(chat_id)[4:]}/{message.id}"
    return {
        "locator": f"media/{chat_id}/{message.id}/{quote(name, safe='')}",
        "title": file.title or name.rsplit(".", 1)[0],
        "artist": file.performer or "未知艺人",
        "album": album,
        "duration": duration,
        "size": file.size,
        "codec": extension.upper(),
        "origin": origin,
    }


class TelegramBackend:
    def __init__(self, client, root):
        self.client, self.root = client, root
        self.scopes_path = root / "collections.json"
        self.scopes = json.loads(self.scopes_path.read_text()) if self.scopes_path.exists() else {}
        self.ads = {}
        self.scan_lock = asyncio.Lock()

    async def catalog(self):
        from telethon import functions, types, utils
        me = await self.client.get_me()
        chats = [{"id": str(me.id), "title": "收藏夹 · Saved Messages", "kind": "saved"}]
        dialogs = await self.client.get_dialogs(limit=1000)
        for dialog in dialogs:
            # Never index direct messages or groups. No join/invite API is exposed.
            if isinstance(dialog.entity, types.Channel) and dialog.entity.broadcast:
                if not getattr(dialog.entity, "noforwards", False):
                    chats.append({"id": str(dialog.id), "title": dialog.name, "kind": "channel"})
        available = {c["id"] for c in chats}
        result = await self.client(functions.messages.GetDialogFiltersRequest())
        folders = []
        for folder in result.filters:
            if not hasattr(folder, "include_peers"):
                continue
            explicit = {str(utils.get_peer_id(p)) for p in folder.include_peers + folder.pinned_peers}
            excluded = {str(utils.get_peer_id(p)) for p in getattr(folder, "exclude_peers", [])}
            # Apply channel-wide filters and exclusions, including archive/read/mute flags.
            selected = explicit & available
            for dialog in dialogs:
                cid = str(dialog.id)
                if cid not in available or cid in explicit or cid in excluded:
                    continue
                if not getattr(folder, "broadcasts", False):
                    continue
                if getattr(folder, "exclude_archived", False) and dialog.archived:
                    continue
                if getattr(folder, "exclude_read", False) and not dialog.unread_count:
                    continue
                mute = getattr(getattr(dialog.dialog, "notify_settings", None), "mute_until", None)
                if getattr(folder, "exclude_muted", False) and mute and mute.timestamp() > __import__("time").time():
                    continue
                selected.add(cid)
            selected -= excluded
            title = getattr(folder.title, "text", folder.title)
            folders.append({"id": str(folder.id), "title": str(title), "chat_ids": sorted(selected)})
        return {"chats": chats, "folders": folders, "dialog_limit": 1000}

    async def create(self, body):
        ids = body.get("chat_ids")
        limit = body.get("message_limit", 1000)
        if not isinstance(ids, list) or not 1 <= len(ids) <= 20 or any(not isinstance(x, str) for x in ids):
            raise ConnectorError("请选择 1–20 个频道或收藏夹")
        if type(limit) is not int or not 100 <= limit <= 2000:
            raise ConnectorError("每个来源的最近消息范围需要为 100–2000 条")
        catalog = await self.catalog()
        allowed = {c["id"] for c in catalog["chats"]}
        if not set(ids) <= allowed:
            raise ConnectorError("所选来源不可访问或启用了内容保护", 403)
        # Explicit list is a snapshot: changes to a Telegram folder never silently add channels.
        scope = {"chat_ids": sorted(set(ids)), "message_limit": limit}
        key = hashlib.sha256(json.dumps(scope, sort_keys=True).encode()).hexdigest()[:24]
        updated = dict(self.scopes)
        updated[key] = scope
        if len(updated) > 100:
            raise ConnectorError("连接器最多保存 100 个媒体库")
        temp = self.scopes_path.with_suffix(".tmp")
        temp.write_text(json.dumps(updated))
        temp.chmod(0o600)
        temp.replace(self.scopes_path)
        self.scopes = updated
        return {"path": f"v1/libraries/{key}/", "message_limit": limit}

    def scope(self, key):
        if key not in self.scopes:
            raise ConnectorError("媒体库不存在，请重新选择来源", 404)
        return self.scopes[key]

    async def entity(self, chat_id):
        from telethon import types
        entity = await self.client.get_entity(int(chat_id))
        me = await self.client.get_me()
        if entity.id != me.id and not (isinstance(entity, types.Channel) and entity.broadcast):
            raise ConnectorError("仅支持收藏夹和频道", 403)
        if getattr(entity, "noforwards", False):
            raise ConnectorError("频道启用了内容保护，无法作为播放源", 403)
        return entity

    async def tracks(self, key):
        scope = self.scope(key)
        async with self.scan_lock:
            rows = []
            for cid in scope["chat_ids"]:
                entity = await self.entity(cid)
                album = getattr(entity, "title", "收藏夹")
                async for message in self.client.iter_messages(entity, limit=scope["message_limit"]):
                    row = audio_row(message, cid, album)
                    if row:
                        rows.append(row)
            return {"tracks": rows, "message_limit": scope["message_limit"]}

    async def media(self, key, chat_id, message_id):
        scope = self.scope(key)
        if chat_id not in scope["chat_ids"]:
            raise ConnectorError("文件不在已选择的媒体库中", 403)
        entity = await self.entity(chat_id)
        message = await self.client.get_messages(entity, ids=message_id)
        if not message or not audio_row(message, chat_id, ""):
            raise ConnectorError("音频已删除、不可访问或受保护", 404)
        return message

    async def stream(self, message, start, length, output, stopped):
        remaining = length
        iterator = self.client.iter_download(message.media, offset=start, chunk_size=CHUNK, request_size=CHUNK)
        try:
            async for chunk in iterator:
                if stopped.is_set() or not remaining:
                    break
                data = bytes(chunk[:remaining])
                while not stopped.is_set():
                    try:
                        output.put_nowait(data)
                        break
                    except queue.Full:
                        await asyncio.sleep(0.02)
                remaining -= len(data)
                if not remaining:
                    break
            if remaining and not stopped.is_set():
                raise ConnectorError("Telegram 音频读取提前结束", 502)
        finally:
            await iterator.close()

    async def sponsored(self, key):
        from telethon import functions
        import time
        messages = []
        for cid in self.scope(key)["chat_ids"]:
            if not cid.startswith("-100"):
                continue
            entity = await self.entity(cid)
            cached = self.ads.get(cid)
            if not cached or time.monotonic() - cached[0] >= 300:
                result = await self.client(functions.messages.GetSponsoredMessagesRequest(peer=entity))
                ads = getattr(result, "messages", [])
                # Do not silently discard rich ads the current UI cannot faithfully display.
                if any(getattr(ad, "photo", None) or getattr(ad, "media", None) for ad in ads):
                    raise ConnectorError("该频道含当前连接器不支持的媒体赞助消息，请在 Telegram 官方客户端访问", 409)
                cached = (time.monotonic(), ads)
                self.ads[cid] = cached
            for ad in cached[1]:
                messages.append({"id": ad.random_id.hex(), "title": ad.title, "text": ad.message,
                                 "url": ad.url, "button": ad.button_text,
                                 "sponsor_info": getattr(ad, "sponsor_info", None) or "",
                                 "additional_info": getattr(ad, "additional_info", None) or ""})
        return {"messages": messages}

    async def viewed(self, key, ad_id):
        from telethon import functions
        allowed = {ad.random_id.hex() for cid in self.scope(key)["chat_ids"]
                   for ad in self.ads.get(cid, (0, []))[1]}
        if ad_id not in allowed:
            raise ConnectorError("赞助消息不存在", 404)
        await self.client(functions.messages.ViewSponsoredMessageRequest(random_id=bytes.fromhex(ad_id)))
        return {"ok": True}


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, backend, loop, token):
        super().__init__(address, Handler)
        self.backend, self.loop, self.token = backend, loop, token
        self.slots = threading.BoundedSemaphore(8)

    def call(self, coroutine, timeout=240):
        future = asyncio.run_coroutine_threadsafe(coroutine, self.loop)
        try:
            return future.result(timeout)
        except concurrent.futures.TimeoutError:
            future.cancel()
            raise ConnectorError("Telegram 请求超时，请稍后重试", 504)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "AwakeConnector/1"

    def setup(self):
        super().setup()
        self.connection.settimeout(30)

    def log_message(self, *_):
        pass  # No tokens, message IDs, or personal library paths in HTTP logs.

    def json(self, body, status=200):
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_GET(self):
        self.handle_api()

    def do_HEAD(self):
        self.handle_api()

    def do_POST(self):
        self.handle_api()

    def handle_api(self):
        if not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + self.server.token):
            self.close_connection = True
            return self.json({"error": "连接器访问令牌无效"}, 401)
        if not self.server.slots.acquire(blocking=False):
            self.close_connection = True
            return self.json({"error": "连接器繁忙，请稍后重试"}, 503)
        try:
            self.route()
        except ConnectorError as error:
            self.json({"error": str(error)}, error.status)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
        except Exception:
            # RPC errors can contain phone numbers/session details. Never forward them.
            self.json({"error": "Telegram 请求失败，请在连接器设备检查登录、权限和网络"}, 502)
        finally:
            self.server.slots.release()

    def body(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= MAX_BODY:
                raise ValueError()
            result = json.loads(self.rfile.read(length))
            if not isinstance(result, dict):
                raise ValueError()
            return result
        except (ValueError, json.JSONDecodeError):
            self.close_connection = True
            raise ConnectorError("请求 JSON 无效或超过 64 KB")

    def route(self):
        parsed = urlsplit(self.path)
        if parsed.query or parsed.fragment:
            raise ConnectorError("接口不接受查询参数")
        path = parsed.path.strip("/")
        b, call = self.server.backend, self.server.call
        if self.command == "GET" and path == "v1/catalog":
            return self.json(call(b.catalog()))
        if self.command == "POST" and path == "v1/libraries":
            return self.json(call(b.create(self.body())))
        match = re.fullmatch(r"v1/libraries/([a-f0-9]{24})/(tracks|sponsored|viewed|media/(-?\d+)/(\d+)/[^/]+)", path)
        if not match:
            raise ConnectorError("接口不存在", 404)
        key, action, cid, mid = match.groups()
        if action == "tracks" and self.command == "GET":
            return self.json(call(b.tracks(key)))
        if action == "sponsored" and self.command == "GET":
            return self.json(call(b.sponsored(key)))
        if action == "viewed" and self.command == "POST":
            return self.json(call(b.viewed(key, self.body().get("id", ""))))
        if not action.startswith("media/") or self.command not in {"GET", "HEAD"}:
            raise ConnectorError("请求方法不支持", 405)
        message = call(b.media(key, cid, int(mid)))
        size = message.file.size
        try:
            start, end, partial = byte_range(self.headers.get("Range"), size)
        except ConnectorError:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(206 if partial else 200)
        mime = message.file.mime_type or ""
        self.send_header("Content-Type", mime if re.fullmatch(r"[a-zA-Z0-9.+_-]+/[a-zA-Z0-9.+_-]+", mime) else "application/octet-stream")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "private, no-store")
        if partial:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if self.command == "HEAD":
            return
        output, stopped = queue.Queue(maxsize=2), threading.Event()
        future = asyncio.run_coroutine_threadsafe(b.stream(message, start, end - start + 1, output, stopped), self.server.loop)
        try:
            remaining = end - start + 1
            last_chunk = time.monotonic()
            while remaining:
                try:
                    data = output.get(timeout=0.5)
                except queue.Empty:
                    if time.monotonic() - last_chunk > 30:
                        raise TimeoutError("音频读取超时")
                    if future.done():
                        future.result()
                        raise ConnectionError("音频读取提前结束")
                    continue
                self.wfile.write(data)
                last_chunk = time.monotonic()
                remaining -= len(data)
        except Exception:
            # Headers have already been sent; abort, never append JSON to audio bytes.
            self.close_connection = True
        finally:
            stopped.set()
            future.cancel()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["login", "serve", "token"])
    parser.add_argument("--data-dir", type=Path, default=Path.home() / ".awake-telegram")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    os.umask(0o077)
    root = args.data_dir.expanduser()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    root.chmod(0o700)
    token_path = root / "access-token"
    if not token_path.exists():
        with token_path.open("x") as out:
            out.write(secrets.token_urlsafe(32))
    token_path.chmod(0o600)
    token = token_path.read_text().strip()
    if len(token) < 32 or not token.isascii():
        parser.error("连接器令牌无效；停止服务并删除 access-token 后重新运行以生成新令牌")
    if args.command == "token":
        print(token)  # Only printed when explicitly requested at the host terminal.
        return
    from telethon import TelegramClient
    try:
        api_id = int(os.environ["AWAKE_TELEGRAM_API_ID"])
        api_hash = os.environ["AWAKE_TELEGRAM_API_HASH"]
    except (KeyError, ValueError):
        parser.error("需要设置 AWAKE_TELEGRAM_API_ID 和 AWAKE_TELEGRAM_API_HASH")
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    client = TelegramClient(str(root / "account"), api_id, api_hash, flood_sleep_threshold=10)
    if args.command == "login":
        client.start()
        print("已登录。会话只保存在此设备；请勿分享数据目录。")
        loop.run_until_complete(client.disconnect())
        return
    loop.run_until_complete(client.connect())
    if not loop.run_until_complete(client.is_user_authorized()):
        loop.run_until_complete(client.disconnect())
        parser.error("请先在此设备执行 login，服务端不会通过 HTTP 请求验证码")
    backend = TelegramBackend(client, root)
    thread = threading.Thread(target=loop.run_forever, daemon=True)
    thread.start()
    server = Server((args.host, args.port), backend, loop, token)
    print(f"Awake Telegram 连接器正在监听 {args.host}:{args.port}；访问令牌请用 token 命令查看。")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        with contextlib.suppress(Exception):
            asyncio.run_coroutine_threadsafe(client.disconnect(), loop).result(10)
        loop.call_soon_threadsafe(loop.stop)


if __name__ == "__main__":
    main()
