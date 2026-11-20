"use strict";
var AwakeSandbox = (() => {
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __defNormalProp = (obj, key, value) => key in obj ? __defProp(obj, key, { enumerable: true, configurable: true, writable: true, value }) : obj[key] = value;
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);
  var __publicField = (obj, key, value) => __defNormalProp(obj, typeof key !== "symbol" ? key + "" : key, value);

  // ui/src/plugins.ts
  var plugins_exports = {};
  __export(plugins_exports, {
    REGISTRY_LIMIT: () => REGISTRY_LIMIT,
    SandboxResponse: () => SandboxResponse,
    WordArray: () => WordArray,
    base64ToBytes: () => base64ToBytes,
    bytesFromWordArray: () => bytesFromWordArray,
    bytesToBase64: () => bytesToBase64,
    configurePluginHost: () => configurePluginHost,
    instantiatePlugin: () => instantiatePlugin,
    invalidatePlugin: () => invalidatePlugin,
    loadPlugin: () => loadPlugin,
    md5Bytes: () => md5Bytes,
    normalizeMediaSource: () => normalizeMediaSource,
    normalizeSearch: () => normalizeSearch,
    parsePluginRegistry: () => parsePluginRegistry,
    pluginFileNameFromURL: () => pluginFileNameFromURL,
    registerPluginCode: () => registerPluginCode,
    resolvePluginTrack: () => resolvePluginTrack,
    searchPlugin: () => searchPlugin,
    sha1Bytes: () => sha1Bytes,
    sha256Bytes: () => sha256Bytes,
    toPayload: () => toPayload,
    validatePluginCode: () => validatePluginCode
  });
  var WordArray = class _WordArray {
    constructor(words = [], sigBytes) {
      __publicField(this, "words");
      __publicField(this, "sigBytes");
      this.words = words;
      this.sigBytes = sigBytes ?? words.length * 4;
    }
    static create(words, sigBytes) {
      return new _WordArray(words, sigBytes);
    }
    toString(encoder = Hex) {
      return encoder.stringify(this);
    }
    concat(other) {
      const bytes = concatBytes(bytesFromWordArray(this), bytesFromWordArray(other));
      this.words = wordsFromBytes(bytes);
      this.sigBytes = bytes.length;
      return this;
    }
    clamp() {
      const bytes = bytesFromWordArray(this);
      this.words = wordsFromBytes(bytes);
      this.sigBytes = bytes.length;
    }
  };
  function wordsFromBytes(bytes) {
    const words = [];
    for (let i = 0; i < bytes.length; i++) {
      words[i >>> 2] = (words[i >>> 2] || 0) | bytes[i] << 24 - i % 4 * 8;
    }
    return words;
  }
  function bytesFromWordArray(value) {
    const out = new Uint8Array(value.sigBytes);
    for (let i = 0; i < value.sigBytes; i++) {
      out[i] = value.words[i >>> 2] >>> 24 - i % 4 * 8 & 255;
    }
    return out;
  }
  function concatBytes(a, b) {
    const out = new Uint8Array(a.length + b.length);
    out.set(a);
    out.set(b, a.length);
    return out;
  }
  function utf8Bytes(text) {
    return new TextEncoder().encode(text);
  }
  function utf8String(bytes) {
    return new TextDecoder().decode(bytes);
  }
  var BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  function bytesToBase64(bytes) {
    let out = "";
    for (let i = 0; i < bytes.length; i += 3) {
      const a = bytes[i];
      const b = i + 1 < bytes.length ? bytes[i + 1] : 0;
      const c = i + 2 < bytes.length ? bytes[i + 2] : 0;
      out += BASE64_ALPHABET[a >> 2];
      out += BASE64_ALPHABET[(a & 3) << 4 | b >> 4];
      out += i + 1 < bytes.length ? BASE64_ALPHABET[(b & 15) << 2 | c >> 6] : "=";
      out += i + 2 < bytes.length ? BASE64_ALPHABET[c & 63] : "=";
    }
    return out;
  }
  function base64ToBytes(text) {
    const clean = text.replace(/[^A-Za-z0-9+/=]/g, "");
    const out = [];
    for (let i = 0; i < clean.length; i += 4) {
      const c1 = BASE64_ALPHABET.indexOf(clean[i]);
      const c2 = BASE64_ALPHABET.indexOf(clean[i + 1]);
      const c3 = BASE64_ALPHABET.indexOf(clean[i + 2]);
      const c4 = BASE64_ALPHABET.indexOf(clean[i + 3]);
      if (c1 < 0 || c2 < 0) break;
      out.push(c1 << 2 | c2 >> 4);
      if (c3 >= 0) out.push((c2 & 15) << 4 | c3 >> 2);
      if (c4 >= 0) out.push((c3 & 3) << 6 | c4);
    }
    return new Uint8Array(out);
  }
  function bytesToHex(bytes) {
    let out = "";
    for (const byte of bytes) out += byte.toString(16).padStart(2, "0");
    return out;
  }
  function hexToBytes(text) {
    const clean = text.replace(/[^0-9a-fA-F]/g, "");
    const out = new Uint8Array(Math.floor(clean.length / 2));
    for (let i = 0; i < out.length; i++) {
      out[i] = parseInt(clean.slice(i * 2, i * 2 + 2), 16);
    }
    return out;
  }
  var Utf8 = {
    stringify: (value) => utf8String(bytesFromWordArray(value)),
    parse: (text) => new WordArray(wordsFromBytes(utf8Bytes(text)), utf8Bytes(text).length)
  };
  var Latin1 = {
    stringify: (value) => {
      const bytes = bytesFromWordArray(value);
      let out = "";
      for (const byte of bytes) out += String.fromCharCode(byte);
      return out;
    },
    parse: (text) => {
      const bytes = new Uint8Array(text.length);
      for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i) & 255;
      return new WordArray(wordsFromBytes(bytes), bytes.length);
    }
  };
  var Base64 = {
    stringify: (value) => bytesToBase64(bytesFromWordArray(value)),
    parse: (text) => {
      const bytes = base64ToBytes(text);
      return new WordArray(wordsFromBytes(bytes), bytes.length);
    }
  };
  var Hex = {
    stringify: (value) => bytesToHex(bytesFromWordArray(value)),
    parse: (text) => {
      const bytes = hexToBytes(text);
      return new WordArray(wordsFromBytes(bytes), bytes.length);
    }
  };
  function inputBytes(value) {
    return typeof value === "string" ? utf8Bytes(value) : bytesFromWordArray(value);
  }
  function resultWordArray(bytes) {
    return new WordArray(wordsFromBytes(bytes), bytes.length);
  }
  var MD5_SHIFT = [
    7,
    12,
    17,
    22,
    7,
    12,
    17,
    22,
    7,
    12,
    17,
    22,
    7,
    12,
    17,
    22,
    5,
    9,
    14,
    20,
    5,
    9,
    14,
    20,
    5,
    9,
    14,
    20,
    5,
    9,
    14,
    20,
    4,
    11,
    16,
    23,
    4,
    11,
    16,
    23,
    4,
    11,
    16,
    23,
    4,
    11,
    16,
    23,
    6,
    10,
    15,
    21,
    6,
    10,
    15,
    21,
    6,
    10,
    15,
    21,
    6,
    10,
    15,
    21
  ];
  var MD5_TABLE = (() => {
    const table = new Uint32Array(64);
    for (let i = 0; i < 64; i++) {
      table[i] = Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296) >>> 0;
    }
    return table;
  })();
  function md5Bytes(input) {
    const bitLength = input.length * 8;
    const paddedLength = (input.length + 8 >>> 6) + 1 << 6;
    const padded = new Uint8Array(paddedLength);
    padded.set(input);
    padded[input.length] = 128;
    const view = new DataView(padded.buffer);
    view.setUint32(paddedLength - 8, bitLength >>> 0, true);
    view.setUint32(paddedLength - 4, Math.floor(bitLength / 4294967296), true);
    let a0 = 1732584193;
    let b0 = 4023233417;
    let c0 = 2562383102;
    let d0 = 271733878;
    const block = new Uint32Array(16);
    for (let offset = 0; offset < paddedLength; offset += 64) {
      for (let i = 0; i < 16; i++) block[i] = view.getUint32(offset + i * 4, true);
      let a = a0;
      let b = b0;
      let c = c0;
      let d = d0;
      for (let i = 0; i < 64; i++) {
        let f;
        let g;
        if (i < 16) {
          f = b & c | ~b & d;
          g = i;
        } else if (i < 32) {
          f = d & b | ~d & c;
          g = (5 * i + 1) % 16;
        } else if (i < 48) {
          f = b ^ c ^ d;
          g = (3 * i + 5) % 16;
        } else {
          f = c ^ (b | ~d);
          g = 7 * i % 16;
        }
        f = f + a + MD5_TABLE[i] + block[g] >>> 0;
        a = d;
        d = c;
        c = b;
        const shift = MD5_SHIFT[i];
        b = b + (f << shift | f >>> 32 - shift) >>> 0;
      }
      a0 = a0 + a >>> 0;
      b0 = b0 + b >>> 0;
      c0 = c0 + c >>> 0;
      d0 = d0 + d >>> 0;
    }
    const out = new Uint8Array(16);
    const outView = new DataView(out.buffer);
    outView.setUint32(0, a0, true);
    outView.setUint32(4, b0, true);
    outView.setUint32(8, c0, true);
    outView.setUint32(12, d0, true);
    return out;
  }
  function rotateLeft(value, bits) {
    return (value << bits | value >>> 32 - bits) >>> 0;
  }
  function rotateRight(value, bits) {
    return (value >>> bits | value << 32 - bits) >>> 0;
  }
  function sha1Bytes(input) {
    const bitLength = input.length * 8;
    const paddedLength = (input.length + 8 >>> 6) + 1 << 6;
    const padded = new Uint8Array(paddedLength);
    padded.set(input);
    padded[input.length] = 128;
    const view = new DataView(padded.buffer);
    view.setUint32(paddedLength - 8, Math.floor(bitLength / 4294967296), false);
    view.setUint32(paddedLength - 4, bitLength >>> 0, false);
    let h0 = 1732584193;
    let h1 = 4023233417;
    let h2 = 2562383102;
    let h3 = 271733878;
    let h4 = 3285377520;
    const w = new Uint32Array(80);
    for (let offset = 0; offset < paddedLength; offset += 64) {
      for (let i = 0; i < 16; i++) w[i] = view.getUint32(offset + i * 4, false);
      for (let i = 16; i < 80; i++) {
        w[i] = rotateLeft(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
      }
      let a = h0;
      let b = h1;
      let c = h2;
      let d = h3;
      let e = h4;
      for (let i = 0; i < 80; i++) {
        let f;
        let k;
        if (i < 20) {
          f = b & c | ~b & d;
          k = 1518500249;
        } else if (i < 40) {
          f = b ^ c ^ d;
          k = 1859775393;
        } else if (i < 60) {
          f = b & c | b & d | c & d;
          k = 2400959708;
        } else {
          f = b ^ c ^ d;
          k = 3395469782;
        }
        const temp = rotateLeft(a, 5) + f + e + k + w[i] >>> 0;
        e = d;
        d = c;
        c = rotateLeft(b, 30);
        b = a;
        a = temp;
      }
      h0 = h0 + a >>> 0;
      h1 = h1 + b >>> 0;
      h2 = h2 + c >>> 0;
      h3 = h3 + d >>> 0;
      h4 = h4 + e >>> 0;
    }
    const out = new Uint8Array(20);
    const outView = new DataView(out.buffer);
    outView.setUint32(0, h0, false);
    outView.setUint32(4, h1, false);
    outView.setUint32(8, h2, false);
    outView.setUint32(12, h3, false);
    outView.setUint32(16, h4, false);
    return out;
  }
  var SHA256_K = new Uint32Array([
    1116352408,
    1899447441,
    3049323471,
    3921009573,
    961987163,
    1508970993,
    2453635748,
    2870763221,
    3624381080,
    310598401,
    607225278,
    1426881987,
    1925078388,
    2162078206,
    2614888103,
    3248222580,
    3835390401,
    4022224774,
    264347078,
    604807628,
    770255983,
    1249150122,
    1555081692,
    1996064986,
    2554220882,
    2821834349,
    2952996808,
    3210313671,
    3336571891,
    3584528711,
    113926993,
    338241895,
    666307205,
    773529912,
    1294757372,
    1396182291,
    1695183700,
    1986661051,
    2177026350,
    2456956037,
    2730485921,
    2820302411,
    3259730800,
    3345764771,
    3516065817,
    3600352804,
    4094571909,
    275423344,
    430227734,
    506948616,
    659060556,
    883997877,
    958139571,
    1322822218,
    1537002063,
    1747873779,
    1955562222,
    2024104815,
    2227730452,
    2361852424,
    2428436474,
    2756734187,
    3204031479,
    3329325298
  ]);
  function sha256Bytes(input) {
    const bitLength = input.length * 8;
    const paddedLength = (input.length + 8 >>> 6) + 1 << 6;
    const padded = new Uint8Array(paddedLength);
    padded.set(input);
    padded[input.length] = 128;
    const view = new DataView(padded.buffer);
    view.setUint32(paddedLength - 8, Math.floor(bitLength / 4294967296), false);
    view.setUint32(paddedLength - 4, bitLength >>> 0, false);
    const h = new Uint32Array([
      1779033703,
      3144134277,
      1013904242,
      2773480762,
      1359893119,
      2600822924,
      528734635,
      1541459225
    ]);
    const w = new Uint32Array(64);
    for (let offset = 0; offset < paddedLength; offset += 64) {
      for (let i = 0; i < 16; i++) w[i] = view.getUint32(offset + i * 4, false);
      for (let i = 16; i < 64; i++) {
        const s0 = rotateRight(w[i - 15], 7) ^ rotateRight(w[i - 15], 18) ^ w[i - 15] >>> 3;
        const s1 = rotateRight(w[i - 2], 17) ^ rotateRight(w[i - 2], 19) ^ w[i - 2] >>> 10;
        w[i] = w[i - 16] + s0 + w[i - 7] + s1 >>> 0;
      }
      let a = h[0];
      let b = h[1];
      let c = h[2];
      let d = h[3];
      let e = h[4];
      let f = h[5];
      let g = h[6];
      let hh = h[7];
      for (let i = 0; i < 64; i++) {
        const s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
        const ch = e & f ^ ~e & g;
        const temp1 = hh + s1 + ch + SHA256_K[i] + w[i] >>> 0;
        const s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
        const maj = a & b ^ a & c ^ b & c;
        const temp2 = s0 + maj >>> 0;
        hh = g;
        g = f;
        f = e;
        e = d + temp1 >>> 0;
        d = c;
        c = b;
        b = a;
        a = temp1 + temp2 >>> 0;
      }
      h[0] = h[0] + a >>> 0;
      h[1] = h[1] + b >>> 0;
      h[2] = h[2] + c >>> 0;
      h[3] = h[3] + d >>> 0;
      h[4] = h[4] + e >>> 0;
      h[5] = h[5] + f >>> 0;
      h[6] = h[6] + g >>> 0;
      h[7] = h[7] + hh >>> 0;
    }
    const out = new Uint8Array(32);
    const outView = new DataView(out.buffer);
    for (let i = 0; i < 8; i++) outView.setUint32(i * 4, h[i], false);
    return out;
  }
  function hmacBytes(hash, message, key) {
    const blockSize = 64;
    let blockKey = key.length > blockSize ? hash(key) : key;
    if (blockKey.length < blockSize) {
      const padded = new Uint8Array(blockSize);
      padded.set(blockKey);
      blockKey = padded;
    }
    const inner = new Uint8Array(blockSize + message.length);
    for (let i = 0; i < blockSize; i++) inner[i] = blockKey[i] ^ 54;
    inner.set(message, blockSize);
    const innerHash = hash(inner);
    const outer = new Uint8Array(blockSize + innerHash.length);
    for (let i = 0; i < blockSize; i++) outer[i] = blockKey[i] ^ 92;
    outer.set(innerHash, blockSize);
    return hash(outer);
  }
  var CryptoJS = {
    lib: { WordArray },
    enc: { Utf8, Latin1, Base64, Hex },
    MD5: (value) => resultWordArray(md5Bytes(inputBytes(value))),
    SHA1: (value) => resultWordArray(sha1Bytes(inputBytes(value))),
    SHA256: (value) => resultWordArray(sha256Bytes(inputBytes(value))),
    HmacMD5: (message, key) => resultWordArray(hmacBytes(md5Bytes, inputBytes(message), inputBytes(key))),
    HmacSHA1: (message, key) => resultWordArray(hmacBytes(sha1Bytes, inputBytes(message), inputBytes(key))),
    HmacSHA256: (message, key) => resultWordArray(hmacBytes(sha256Bytes, inputBytes(message), inputBytes(key))),
    AES: {
      decrypt: () => {
        throw new Error("\u5F53\u524D\u63D2\u4EF6\u6C99\u7BB1\u4E0D\u652F\u6301 AES \u89E3\u5BC6\uFF08\u5C11\u6570\u63D2\u4EF6\u7684\u52A0\u5BC6\u63A5\u53E3\uFF09\uFF0C\u8BF7\u6362\u7528\u4E0D\u4F9D\u8D56 AES \u7684\u63D2\u4EF6\u7248\u672C");
      },
      encrypt: () => {
        throw new Error("\u5F53\u524D\u63D2\u4EF6\u6C99\u7BB1\u4E0D\u652F\u6301 AES \u52A0\u5BC6\uFF08\u5C11\u6570\u63D2\u4EF6\u7684\u52A0\u5BC6\u63A5\u53E3\uFF09\uFF0C\u8BF7\u6362\u7528\u4E0D\u4F9D\u8D56 AES \u7684\u63D2\u4EF6\u7248\u672C");
      }
    }
  };
  var host = null;
  function configurePluginHost(next) {
    host = next;
  }
  var SandboxHeaders = class {
    constructor(pairs = []) {
      __publicField(this, "map", /* @__PURE__ */ new Map());
      for (const [name, value] of pairs) this.map.set(name.toLowerCase(), value);
    }
    get(name) {
      return this.map.get(name.toLowerCase()) ?? null;
    }
    has(name) {
      return this.map.has(name.toLowerCase());
    }
    forEach(callback) {
      this.map.forEach((value, key) => callback(value, key));
    }
  };
  function normalizeHeaders(input) {
    const pairs = [];
    if (!input) return pairs;
    if (Array.isArray(input)) {
      for (const entry of input) {
        if (Array.isArray(entry) && entry.length >= 2) {
          pairs.push([String(entry[0]), String(entry[1])]);
        }
      }
      return pairs;
    }
    if (typeof input === "object") {
      const maybeHeaders = input;
      if (typeof maybeHeaders.forEach === "function" && !(input instanceof Map)) {
        try {
          maybeHeaders.forEach((value, key) => pairs.push([String(key), String(value)]));
          if (pairs.length) return pairs;
        } catch {
        }
      }
      for (const [key, value] of Object.entries(input)) {
        if (typeof value === "string") pairs.push([key, value]);
      }
    }
    return pairs;
  }
  function bodyBytes(body) {
    if (body === void 0 || body === null) return {};
    if (typeof body === "string") return { text: body };
    if (typeof URLSearchParams !== "undefined" && body instanceof URLSearchParams) {
      return { text: body.toString() };
    }
    if (body instanceof ArrayBuffer) return { base64: bytesToBase64(new Uint8Array(body)) };
    if (ArrayBuffer.isView(body)) {
      return {
        base64: bytesToBase64(new Uint8Array(body.buffer, body.byteOffset, body.byteLength))
      };
    }
    if (typeof FormData !== "undefined" && body instanceof FormData) {
      throw new Error("\u63D2\u4EF6\u6C99\u7BB1\u6682\u4E0D\u652F\u6301 FormData \u8BF7\u6C42\u4F53\uFF0C\u8BF7\u6539\u7528\u5B57\u7B26\u4E32\u6216 JSON");
    }
    return { text: String(body) };
  }
  var SandboxResponse = class {
    constructor(proxy) {
      __publicField(this, "ok");
      __publicField(this, "status");
      __publicField(this, "url");
      __publicField(this, "headers");
      __publicField(this, "bytes");
      this.status = proxy.status;
      this.ok = proxy.status >= 200 && proxy.status < 300;
      this.url = proxy.url;
      this.headers = new SandboxHeaders(proxy.headers);
      this.bytes = base64ToBytes(proxy.body_base64);
    }
    text() {
      return utf8String(this.bytes);
    }
    json() {
      return JSON.parse(this.text());
    }
    arrayBuffer() {
      return this.bytes.buffer.slice(
        this.bytes.byteOffset,
        this.bytes.byteOffset + this.bytes.byteLength
      );
    }
  };
  async function sandboxFetch(input, init = {}) {
    if (!host) {
      throw new Error("\u63D2\u4EF6\u5BBF\u4E3B\u5C1A\u672A\u8FDE\u63A5\uFF1A\u8BF7\u91CD\u542F Awake \u684C\u9762\u5E94\u7528\u540E\u91CD\u8BD5");
    }
    const body = bodyBytes(init.body);
    const proxy = await host.http({
      url: String(input),
      method: init.method || "GET",
      headers: normalizeHeaders(init.headers),
      body: body.text ?? null,
      body_base64: body.base64 ?? null
    });
    return new SandboxResponse(proxy);
  }
  var silentConsole = {
    log: () => {
    },
    info: () => {
    },
    warn: () => {
    },
    error: () => {
    },
    debug: () => {
    }
  };
  var loaded = /* @__PURE__ */ new Map();
  function invalidatePlugin(sourceId) {
    loaded.delete(sourceId);
  }
  function instantiatePlugin(code) {
    const module = { exports: {} };
    const requireShim = (name) => {
      if (name === "crypto-js") return CryptoJS;
      throw new Error(`\u63D2\u4EF6\u6C99\u7BB1\u4E0D\u652F\u6301 require("${name}")\uFF0C\u53EF\u7528\u7684\u53EA\u6709 crypto-js \u4E0E fetch`);
    };
    const factory = new Function(
      "module",
      "exports",
      "fetch",
      "CryptoJS",
      "console",
      "require",
      "setTimeout",
      "clearTimeout",
      "queueMicrotask",
      code
    );
    factory(
      module,
      module.exports,
      sandboxFetch,
      CryptoJS,
      silentConsole,
      requireShim,
      setTimeout,
      clearTimeout,
      queueMicrotask
    );
    const exports = module.exports;
    if (!exports || typeof exports !== "object") {
      throw new Error("\u63D2\u4EF6\u6CA1\u6709\u5BFC\u51FA\u5BF9\u8C61\uFF1A\u8BF7\u786E\u8BA4\u8FD9\u662F\u4E00\u4E2A MusicFree \u517C\u5BB9\u63D2\u4EF6");
    }
    return exports;
  }
  function validatePluginCode(code) {
    const exports = instantiatePlugin(code);
    const platform = typeof exports.platform === "string" ? exports.platform.trim() : "";
    const hasSearch = typeof exports.search === "function";
    if (!platform && !hasSearch) {
      throw new Error("\u8FD9\u4E0D\u662F MusicFree \u517C\u5BB9\u63D2\u4EF6\uFF1A\u7F3A\u5C11 platform \u4E0E search");
    }
    return { platform, hasSearch };
  }
  async function loadPlugin(sourceId) {
    const cached = loaded.get(sourceId);
    if (cached) return cached;
    const promise = (async () => {
      if (!host) {
        throw new Error("\u63D2\u4EF6\u5BBF\u4E3B\u5C1A\u672A\u8FDE\u63A5\uFF1A\u8BF7\u91CD\u542F Awake \u684C\u9762\u5E94\u7528\u540E\u91CD\u8BD5");
      }
      const code = await host.readCode(sourceId);
      const exports = instantiatePlugin(code);
      return {
        sourceId,
        platform: typeof exports.platform === "string" ? exports.platform : "",
        exports
      };
    })();
    loaded.set(sourceId, promise);
    promise.catch(() => loaded.delete(sourceId));
    return promise;
  }
  function registerPluginCode(sourceId, code) {
    const exports = instantiatePlugin(code);
    const entry = {
      sourceId,
      platform: typeof exports.platform === "string" ? exports.platform : "",
      exports
    };
    loaded.set(sourceId, Promise.resolve(entry));
    return entry;
  }
  function normalizeSearch(raw) {
    const record = raw;
    const list = Array.isArray(record) ? record : Array.isArray(record?.data) ? record.data : [];
    const items = [];
    for (const entry of list) {
      if (!entry || typeof entry !== "object") continue;
      const item = entry;
      const title = typeof item.title === "string" ? item.title.trim() : "";
      if (!title) continue;
      const duration = Number(item.duration);
      items.push({
        id: typeof item.id === "string" || typeof item.id === "number" ? item.id : null,
        title,
        artist: typeof item.artist === "string" ? item.artist : "",
        album: typeof item.album === "string" ? item.album : "",
        duration: Number.isFinite(duration) && duration > 0 ? duration : 0,
        artwork: typeof item.artwork === "string" ? item.artwork : "",
        raw: item
      });
    }
    const isEnd = Array.isArray(record) ? true : record?.isEnd !== false;
    return { isEnd, items };
  }
  async function searchPlugin(sourceId, query, page = 1) {
    const plugin = await loadPlugin(sourceId);
    const search = plugin.exports.search;
    if (typeof search !== "function") {
      throw new Error("\u8FD9\u4E2A\u63D2\u4EF6\u6CA1\u6709\u5B9E\u73B0 search\uFF0C\u53EA\u80FD\u7528\u6765\u89E3\u6790\u56FA\u5B9A\u6765\u6E90");
    }
    const raw = await search(query, page, "music");
    return normalizeSearch(raw);
  }
  function normalizeMediaSource(raw) {
    if (!raw) return null;
    if (typeof raw === "string") {
      return /^https?:\/\//i.test(raw) ? { url: raw, headers: [] } : null;
    }
    if (typeof raw !== "object") return null;
    const record = raw;
    const url = typeof record.url === "string" ? record.url : "";
    if (!/^https?:\/\//i.test(url)) return null;
    const headers = [];
    const rawHeaders = record.headers;
    if (rawHeaders && typeof rawHeaders === "object") {
      for (const [name, value] of Object.entries(rawHeaders)) {
        if (typeof value === "string" && value) headers.push([name, value]);
      }
    }
    return { url, headers };
  }
  var QUALITY_FALLBACK = ["standard", "high", "super"];
  async function resolvePluginTrack(sourceId, locator) {
    const plugin = await loadPlugin(sourceId);
    const getMediaSource = plugin.exports.getMediaSource;
    if (typeof getMediaSource !== "function") {
      throw new Error("\u8FD9\u4E2A\u63D2\u4EF6\u6CA1\u6709\u5B9E\u73B0 getMediaSource\uFF0C\u65E0\u6CD5\u64AD\u653E");
    }
    let item;
    try {
      item = JSON.parse(locator);
    } catch {
      throw new Error("\u66F2\u76EE\u6570\u636E\u4E0D\u662F\u6709\u6548\u7684\u63D2\u4EF6\u6761\u76EE\uFF0C\u8BF7\u91CD\u65B0\u641C\u7D22\u5165\u5E93");
    }
    let lastError = null;
    for (const quality of QUALITY_FALLBACK) {
      try {
        const resolved = normalizeMediaSource(await getMediaSource(item, quality));
        if (resolved) return resolved;
      } catch (error) {
        lastError = error;
      }
    }
    if (lastError) {
      throw new Error(
        `\u63D2\u4EF6\u89E3\u6790\u5931\u8D25\uFF1A${String(lastError).replace(/^Error: /, "")}`
      );
    }
    throw new Error("\u63D2\u4EF6\u6CA1\u6709\u8FD4\u56DE\u53EF\u64AD\u653E\u7684\u5730\u5740\uFF08\u8BE5\u66F2\u76EE\u53EF\u80FD\u9700\u8981\u767B\u5F55\u6216\u5DF2\u5931\u6548\uFF09");
  }
  function toPayload(item) {
    return {
      title: item.title,
      artist: item.artist,
      album: item.album,
      duration: item.duration,
      artwork: item.artwork,
      item: jsonSafe(item.raw)
    };
  }
  function jsonSafe(value) {
    try {
      return JSON.parse(JSON.stringify(value));
    } catch {
      throw new Error("\u63D2\u4EF6\u8FD4\u56DE\u7684\u66F2\u76EE\u6570\u636E\u65E0\u6CD5\u5E8F\u5217\u5316\uFF08\u53EF\u80FD\u5305\u542B\u5FAA\u73AF\u5F15\u7528\uFF09");
    }
  }
  var REGISTRY_LIMIT = 200;
  function parsePluginRegistry(input) {
    const raw = Array.isArray(input) ? input : input && typeof input === "object" ? input.plugins ?? input.data ?? input.list : null;
    if (!Array.isArray(raw)) throw new Error("\u8FD9\u4E0D\u662F\u63D2\u4EF6\u6E90\uFF1A\u627E\u4E0D\u5230\u63D2\u4EF6\u5217\u8868");
    const out = [];
    const seen = /* @__PURE__ */ new Set();
    for (const item of raw) {
      if (!item || typeof item !== "object") continue;
      const rec = item;
      const name = typeof rec.name === "string" ? rec.name.trim() : "";
      const url = typeof rec.url === "string" ? rec.url.trim() : "";
      if (!name || !url) continue;
      if (!/^https?:\/\//i.test(url)) continue;
      if (seen.has(url)) continue;
      seen.add(url);
      const version = typeof rec.version === "string" ? rec.version.trim() : void 0;
      out.push(version ? { name, url, version } : { name, url });
      if (out.length >= REGISTRY_LIMIT) break;
    }
    if (!out.length) throw new Error("\u63D2\u4EF6\u6E90\u91CC\u6CA1\u6709\u53EF\u7528\u7684\u63D2\u4EF6");
    return out;
  }
  function pluginFileNameFromURL(url) {
    try {
      const path = new URL(url).pathname;
      const last = path.split("/").filter(Boolean).pop() ?? "";
      return /^[\w.-]+\.js$/i.test(last) ? last : "plugin.js";
    } catch {
      return "plugin.js";
    }
  }
  return __toCommonJS(plugins_exports);
})();
