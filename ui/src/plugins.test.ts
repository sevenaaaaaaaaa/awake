import test from "node:test";
import assert from "node:assert/strict";
import {
  base64ToBytes,
  bytesToBase64,
  configurePluginHost,
  instantiatePlugin,
  md5Bytes,
  normalizeMediaSource,
  normalizeSearch,
  registerPluginCode,
  resolvePluginTrack,
  searchPlugin,
  sha1Bytes,
  sha256Bytes,
  toPayload,
  validatePluginCode,
  type PluginHttpRequest,
  type PluginItem,
} from "./plugins.ts";

function hex(bytes: Uint8Array): string {
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function utf8(text: string): Uint8Array {
  return new TextEncoder().encode(text);
}

test("MD5 / SHA1 / SHA256 match the published test vectors", () => {
  // 这些向量是插件签名逻辑的地基：算错一位，所有签名类插件都会失败。
  assert.equal(hex(md5Bytes(utf8("abc"))), "900150983cd24fb0d6963f7d28e17f72");
  assert.equal(hex(md5Bytes(utf8(""))), "d41d8cd98f00b204e9800998ecf8427e");
  assert.equal(hex(sha1Bytes(utf8("abc"))), "a9993e364706816aba3e25717850c26c9cd0d89d");
  assert.equal(
    hex(sha256Bytes(utf8("abc"))),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  );
  // 长输入跨 block，考验填充与位长写入。
  assert.equal(
    hex(sha256Bytes(utf8("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
  );
});

test("CryptoJS subset produces the signatures plugins expect", () => {
  const exports = instantiatePlugin(`
    module.exports = {
      platform: "签名夹具",
      search(query) {
        const hmac = CryptoJS.HmacSHA256("The quick brown fox jumps over the lazy dog", "key");
        return {
          isEnd: true,
          data: [{
            id: "1",
            title: "签名 " + query,
            sign: hmac.toString(),
            md5: CryptoJS.MD5("abc").toString(),
            utf8: CryptoJS.enc.Utf8.stringify(CryptoJS.enc.Base64.parse("5L2g5aW9")),
          }],
        };
      },
    };
  `);
  const items = (exports.search("测试").data ?? []) as Array<Record<string, string>>;
  assert.equal(items[0].md5, "900150983cd24fb0d6963f7d28e17f72");
  assert.equal(items[0].utf8, "你好");
  // RFC 4231 风格的 HMAC-SHA256 已知向量。
  assert.equal(
    items[0].sign,
    "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8",
  );
});

test("Base64 helpers round-trip binary data", () => {
  const bytes = new Uint8Array([0, 1, 2, 250, 251, 255, 128]);
  assert.deepEqual([...base64ToBytes(bytesToBase64(bytes))], [...bytes]);
  assert.equal(bytesToBase64(utf8("Hello, World!")), "SGVsbG8sIFdvcmxkIQ==");
});

test("normalizeSearch accepts both shapes and drops entries without a title", () => {
  const musicfree = normalizeSearch({
    isEnd: false,
    data: [
      { id: 1, title: "A", artist: "X", duration: 200 },
      { id: "2", title: "  ", artist: "Y" },
      null,
      "junk",
      { id: 3, title: "B", duration: "bad" },
    ],
  });
  assert.equal(musicfree.isEnd, false);
  assert.equal(musicfree.items.length, 2);
  assert.equal(musicfree.items[0].title, "A");
  assert.equal(musicfree.items[1].duration, 0, "非法时长按 0 处理");

  const bare = normalizeSearch([{ id: 1, title: "Solo" }]);
  assert.equal(bare.isEnd, true, "裸数组视为没有下一页");
  assert.equal(bare.items.length, 1);
  assert.equal(normalizeSearch(undefined).items.length, 0);
});

test("normalizeMediaSource accepts string, {url}, and rejects unsafe addresses", () => {
  assert.deepEqual(normalizeMediaSource("https://cdn.example/a.mp3"), {
    url: "https://cdn.example/a.mp3",
    headers: [],
  });
  assert.deepEqual(
    normalizeMediaSource({
      url: "https://cdn.example/a.mp3",
      headers: { Referer: "https://a.example/", "X-Test": 1 },
    }),
    {
      url: "https://cdn.example/a.mp3",
      headers: [["Referer", "https://a.example/"]],
    },
  );
  for (const bad of [null, "", "file:///etc/passwd", { url: "ftp://x/y" }]) {
    assert.equal(normalizeMediaSource(bad), null, String(bad));
  }
});

test("validatePluginCode rejects scripts that are not MusicFree plugins", () => {
  assert.throws(() => validatePluginCode("const x = 1;"), /MusicFree/);
  const ok = validatePluginCode('module.exports = { platform: "P", search() {} };');
  assert.equal(ok.platform, "P");
  assert.equal(ok.hasSearch, true);
});

test("searchPlugin and resolvePluginTrack run through the sandbox", async () => {
  registerPluginCode(
    "test-source",
    `
    module.exports = {
      platform: "测试源",
      version: "0.1",
      async search(query, page) {
        return {
          isEnd: page >= 2,
          data: [
            { id: "s1", title: query + " 第" + page + "页", artist: "艺人", album: "专辑", duration: 180 },
          ],
        };
      },
      async getMediaSource(item, quality) {
        if (quality === "high") return { url: "https://cdn.example/" + item.id + ".flac", headers: { Referer: "https://a.example/" } };
        return null;
      },
    };
  `);
  const first = await searchPlugin("test-source", "夜航", 1);
  assert.equal(first.isEnd, false);
  assert.equal(first.items[0].title, "夜航 第1页");
  const second = await searchPlugin("test-source", "夜航", 2);
  assert.equal(second.isEnd, true);

  const payload = toPayload(first.items[0] as PluginItem);
  assert.equal(payload.title, "夜航 第1页");
  assert.deepEqual(payload.item, {
    id: "s1",
    title: "夜航 第1页",
    artist: "艺人",
    album: "专辑",
    duration: 180,
  });

  const resolved = await resolvePluginTrack("test-source", JSON.stringify(payload.item));
  assert.equal(resolved.url, "https://cdn.example/s1.flac");
  assert.deepEqual(resolved.headers, [["Referer", "https://a.example/"]]);

  await assert.rejects(
    resolvePluginTrack("test-source", "not json"),
    /重新搜索入库/,
  );
});

test("a plugin without getMediaSource fails with a readable message", async () => {
  registerPluginCode("no-media", "module.exports = { platform: 'X' };");
  await assert.rejects(
    resolvePluginTrack("no-media", JSON.stringify({ id: "1" })),
    /getMediaSource/,
  );
});

test("plugin fetch goes through the injected host proxy", async () => {
  const seen: PluginHttpRequest[] = [];
  configurePluginHost({
    readCode: async () => "",
    http: async (request) => {
      seen.push(request);
      const body = new TextEncoder().encode(
        JSON.stringify({ ok: true, echo: request.url }),
      );
      return {
        status: 200,
        url: request.url,
        headers: [["content-type", "application/json"]],
        body_base64: bytesToBase64(body),
      };
    },
  });
  registerPluginCode(
    "fetch-source",
    `
    module.exports = {
      platform: "通道夹具",
      async search(q) {
        const res = await fetch("https://api.example/search", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ q }),
        });
        const data = await res.json();
        return { isEnd: true, data: [{ id: data.echo, title: "通道 " + q }] };
      },
    };
  `,
  );
  const result = await searchPlugin("fetch-source", "夜航");
  assert.equal(result.items[0].title, "通道 夜航");
  assert.equal(seen.length, 1, "插件的一次 fetch 对应一次宿主调用");
  assert.equal(seen[0].method, "POST");
  assert.deepEqual(seen[0].headers, [["Content-Type", "application/json"]]);
  assert.equal(seen[0].body, JSON.stringify({ q: "夜航" }));
  assert.equal(seen[0].body_base64, null);
});
