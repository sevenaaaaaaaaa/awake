"""Protocol tests use generated audio and an in-process backend, never a Telegram account."""
import asyncio
import contextlib
import http.client
import io
import json
from pathlib import Path
import queue
import tempfile
import threading
from types import SimpleNamespace as Obj
import unittest
import wave

from connector import CHUNK, ConnectorError, Server, TelegramBackend, audio_row, byte_range


KEY = "a" * 24


def wav_bytes():
    output = io.BytesIO()
    with wave.open(output, "wb") as audio:
        audio.setnchannels(2)
        audio.setsampwidth(2)
        audio.setframerate(48000)
        audio.writeframes(b"\x00\x00\x01\x00" * 48000)
    return output.getvalue()


class Download:
    def __init__(self, data, start):
        self.data, self.pos, self.closed = data, start, False
    def __aiter__(self):
        return self
    async def __anext__(self):
        if self.pos >= len(self.data):
            raise StopAsyncIteration
        chunk = self.data[self.pos:self.pos + CHUNK]
        self.pos += len(chunk)
        return chunk
    async def close(self):
        self.closed = True


class FakeClient:
    def __init__(self, data):
        self.data = data
        self.message = Obj(file=Obj(size=len(data), name="音乐.wav", ext=".wav", title="原始录音", performer="自己",
                                    duration=1, mime_type="audio/wav"), id=7, chat=Obj(username=None), noforwards=False, media=Obj())
    def iter_download(self, media, offset, **kwargs):
        self.download = Download(self.data, offset)
        return self.download
    async def get_messages(self, entity, ids):
        return self.message if ids == 7 else None


class FixtureBackend(TelegramBackend):
    async def catalog(self):
        return {"chats": [{"id": "42", "title": "收藏夹", "kind": "saved"},
                           {"id": "-100123", "title": "自有频道", "kind": "channel"}],
                "folders": [{"id": "2", "title": "音乐", "chat_ids": ["-100123"]}]}
    async def entity(self, chat_id):
        return Obj(title="自有频道", id=int(chat_id), noforwards=False)
    async def tracks(self, key):
        scope = self.scope(key)
        return {"tracks": [audio_row(self.client.message, cid, "自有频道") for cid in scope["chat_ids"]],
                "message_limit": scope["message_limit"]}
    async def sponsored(self, key):
        self.scope(key)
        return {"messages": []}


class RangeTests(unittest.TestCase):
    def test_ranges(self):
        self.assertEqual(byte_range(None, 10), (0, 9, False))
        self.assertEqual(byte_range("bytes=2-4", 10), (2, 4, True))
        self.assertEqual(byte_range("bytes=9-99", 10), (9, 9, True))
        self.assertEqual(byte_range("bytes=-3", 10), (7, 9, True))
        self.assertEqual(byte_range("bytes=3-", 10), (3, 9, True))
        for value in ["bytes=10-", "bytes=4-3", "bytes=1-2,4-5", "bytes=-0", "bytes=-", "items=0-1"]:
            with self.assertRaises(ConnectorError): byte_range(value, 10)

    def test_metadata_does_not_claim_hires_and_refuses_protected_messages(self):
        message = FakeClient(wav_bytes()).message
        row = audio_row(message, "-100123", "自有频道")
        self.assertEqual(row["title"], "原始录音")
        self.assertEqual(row["origin"], "https://t.me/c/123/7")
        self.assertNotIn("sample_rate", row)
        message.noforwards = True
        self.assertIsNone(audio_row(message, "-100123", "a"))
        message.noforwards = False
        message.file.name = "script.js"
        self.assertIsNone(audio_row(message, "-100123", "a"))


class BackendTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.backend = FixtureBackend(FakeClient(wav_bytes()), Path(self.temp.name))
    async def asyncTearDown(self):
        self.temp.cleanup()
    async def test_explicit_scopes_persist_and_validate(self):
        result = await self.backend.create({"chat_ids": ["42"], "message_limit": 100})
        key = result["path"].split("/")[2]
        restored = FixtureBackend(self.backend.client, Path(self.temp.name))
        self.assertEqual(restored.scope(key)["chat_ids"], ["42"])
        self.assertEqual((Path(self.temp.name) / "collections.json").stat().st_mode & 0o777, 0o600)
        for body in [{"chat_ids": []}, {"chat_ids": ["99"]}, {"chat_ids": [42]}, {"chat_ids": ["42"], "message_limit": True}]:
            with self.assertRaises(ConnectorError): await self.backend.create(body)
    async def test_media_scope_and_deleted_or_protected(self):
        self.backend.scopes[KEY] = {"chat_ids": ["42"], "message_limit": 100}
        for cid, mid in [("99", 7), ("42", 8)]:
            with self.assertRaises(ConnectorError): await self.backend.media(KEY, cid, mid)
        self.backend.client.message.noforwards = True
        with self.assertRaises(ConnectorError): await self.backend.media(KEY, "42", 7)
    async def test_stream_is_bounded_and_cancellable(self):
        output, stopped = queue.Queue(maxsize=2), threading.Event()
        task = asyncio.create_task(self.backend.stream(self.backend.client.message, 0, len(self.backend.client.data), output, stopped))
        await asyncio.sleep(0.1)
        self.assertLessEqual(output.qsize(), 2)
        stopped.set()
        await asyncio.wait_for(task, 1)
        self.assertTrue(self.backend.client.download.closed)

    async def test_actual_folder_shapes_exclude_groups_and_protected_channels(self):
        from telethon import types
        channel = types.Channel(id=123, title="Own channel", photo=types.ChatPhotoEmpty(), date=None, broadcast=True)
        protected = types.Channel(id=456, title="Protected", photo=types.ChatPhotoEmpty(), date=None, broadcast=True, noforwards=True)
        group = types.Channel(id=789, title="Group", photo=types.ChatPhotoEmpty(), date=None, megagroup=True)
        peer = types.InputPeerChannel(channel_id=123, access_hash=1)
        # Shared chat folders have no exclude_peers field.
        shared = types.DialogFilterChatlist(id=2, title=types.TextWithEntities("Music", []), pinned_peers=[], include_peers=[peer])
        dynamic = types.DialogFilter(id=3, title=types.TextWithEntities("All channels", []), pinned_peers=[], include_peers=[], exclude_peers=[], broadcasts=True)
        class CatalogClient:
            async def get_me(self): return Obj(id=42)
            async def get_dialogs(self, limit):
                return [Obj(id=-1000000000000-e.id, entity=e, name=e.title, archived=False, unread_count=1,
                            dialog=Obj(notify_settings=Obj(mute_until=None))) for e in [channel, protected, group]]
            async def __call__(self, request): return Obj(filters=[shared, dynamic])
        backend = TelegramBackend(CatalogClient(), Path(self.temp.name))
        result = await backend.catalog()
        self.assertEqual([c["id"] for c in result["chats"]], ["42", "-1000000000123"])
        self.assertEqual([f["chat_ids"] for f in result["folders"]], [["-1000000000123"], ["-1000000000123"]])

    async def test_sponsored_messages_cache_view_receipts_and_rich_content_gate(self):
        from telethon import types, functions
        ad = types.SponsoredMessage(url="https://t.me/example", title="Sponsor", message="Text", button_text="Open", random_id=b"test")
        class AdClient:
            def __init__(self): self.fetches = 0; self.views = 0; self.rich = False
            async def __call__(self, request):
                if isinstance(request, functions.messages.GetSponsoredMessagesRequest):
                    self.fetches += 1
                    ad.photo = Obj() if self.rich else None
                    return Obj(messages=[ad])
                self.views += 1
                return True
        client = AdClient()
        backend = FixtureBackend(client, Path(self.temp.name))
        backend.scopes[KEY] = {"chat_ids": ["-100123"], "message_limit": 100}
        rows = await TelegramBackend.sponsored(backend, KEY)
        await TelegramBackend.sponsored(backend, KEY)
        self.assertEqual(client.fetches, 1)
        await backend.viewed(KEY, rows["messages"][0]["id"])
        self.assertEqual(client.views, 1)
        with self.assertRaises(ConnectorError): await backend.viewed(KEY, "unknown")
        backend.ads.clear(); client.rich = True
        with self.assertRaises(ConnectorError): await TelegramBackend.sponsored(backend, KEY)


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.data = wav_bytes()
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        self.backend = FixtureBackend(FakeClient(self.data), Path(self.temp.name))
        self.backend.scopes[KEY] = {"chat_ids": ["42"], "message_limit": 100}
        self.loop_thread = threading.Thread(target=self.loop.run_forever)
        self.loop_thread.start()
        self.server = Server(("127.0.0.1", 0), self.backend, self.loop, "test-only-token")
        self.http_thread = threading.Thread(target=self.server.serve_forever)
        self.http_thread.start()
    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.http_thread.join()
        self.loop.call_soon_threadsafe(self.loop.stop); self.loop_thread.join(); self.loop.close()
        self.temp.cleanup()
    def request(self, path, method="GET", body=None, headers=None, auth=True):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=3)
        header = {"Authorization": "Bearer test-only-token"} if auth else {}
        header.update(headers or {})
        connection.request(method, path, body=body, headers=header)
        response = connection.getresponse()
        result = response.status, dict(response.getheaders()), response.read()
        connection.close()
        return result
    def test_auth_and_route_boundary(self):
        self.assertEqual(self.request("/v1/catalog", auth=False)[0], 401)
        self.assertEqual(self.request("/v1/catalog?token=test-only-token")[0], 400)
        self.assertEqual(self.request("/login", "POST", "{}")[0], 404)
        self.assertEqual(self.request("/v1/libraries", "POST", "[]")[0], 400)
        self.assertEqual(self.request(f"/v1/libraries/{KEY}/media/99/7/a.wav")[0], 403)
    def test_collection_tracks_and_full_audio(self):
        status, _, body = self.request("/v1/libraries", "POST", json.dumps({"chat_ids": ["42"], "message_limit": 100}))
        self.assertEqual(status, 200)
        root = "/" + json.loads(body)["path"]
        status, _, body = self.request(root + "tracks")
        self.assertEqual(status, 200)
        locator = json.loads(body)["tracks"][0]["locator"]
        status, headers, body = self.request(root + locator)
        self.assertEqual(status, 200)
        self.assertEqual(body, self.data)
        self.assertEqual(headers["Accept-Ranges"], "bytes")
    def test_audio_ranges_and_head(self):
        path = f"/v1/libraries/{KEY}/media/42/7/music.wav"
        for value, expected in [("bytes=44-99", self.data[44:100]), ("bytes=-40", self.data[-40:]), ("bytes=180000-", self.data[180000:])]:
            status, headers, body = self.request(path, headers={"Range": value})
            self.assertEqual(status, 206)
            self.assertEqual(body, expected)
            self.assertEqual(int(headers["Content-Length"]), len(expected))
        self.assertEqual(self.request(path, headers={"Range": f"bytes={len(self.data)}-"})[0], 416)
        status, headers, body = self.request(path, "HEAD")
        self.assertEqual(status, 200)
        self.assertEqual(int(headers["Content-Length"]), len(self.data))
        self.assertEqual(body, b"")


if __name__ == "__main__":
    unittest.main()
