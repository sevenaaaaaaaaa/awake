"""Local UI/integration fixture. Generated WAV only; no Telegram login or production mode."""
import asyncio
from pathlib import Path
import tempfile
import threading
from connector import Server
from test_connector import FakeClient, FixtureBackend, KEY, wav_bytes

if __name__ == "__main__":
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    with tempfile.TemporaryDirectory() as root:
        backend = FixtureBackend(FakeClient(wav_bytes()), Path(root))
        backend.scopes[KEY] = {"chat_ids": ["42"], "message_limit": 100}
        thread = threading.Thread(target=loop.run_forever, daemon=True)
        thread.start()
        server = Server(("127.0.0.1", 8766), backend, loop, "test-only-token")
        print("TEST FIXTURE ONLY: http://127.0.0.1:8766/", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            server.server_close()
            loop.call_soon_threadsafe(loop.stop)
            thread.join()
