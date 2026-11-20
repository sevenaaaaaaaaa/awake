/**
 * 网络音乐插件沙箱（枪弹分离 / MusicFree 兼容）。
 *
 * 「枪弹分离」= 播放器是枪、插件是弹：插件是一个独立 JS 文件，导出
 * `platform` / `search` / `getMediaSource` / `getAlbumInfo` / `getLyric` 等函数。
 * 本模块负责把插件脚本装进一个受控作用域里运行：
 *
 * - `fetch` 由注入的 HTTP 通道代发（桌面端接到后端 `plugin_http` 命令；
 *   WebView 直连会被 CORS 拦住），地址/方法/头/体都有上限；
 * - 提供插件常用的 `CryptoJS` 子集（MD5 / SHA1 / SHA256 / HMAC + Utf8/Base64/Hex 编码），
 *   绝大多数签名类插件不需要再装依赖；
 * - `require("crypto-js")` 兼容旧写法。
 *
 * 插件代码由用户显式导入，信任级别等同于用户自己安装的应用；
 * 只导入你信任来源的插件文件。
 */

// ---------------------------------------------------------------- WordArray
// CryptoJS 的最小 WordArray 实现：插件最常见的用法是
// `CryptoJS.MD5(str).toString()` / `.toString(CryptoJS.enc.Base64)`。

export interface Encoder {
  stringify(value: WordArray): string;
}

export class WordArray {
  words: number[];
  sigBytes: number;
  constructor(words: number[] = [], sigBytes?: number) {
    this.words = words;
    this.sigBytes = sigBytes ?? words.length * 4;
  }
  static create(words: number[], sigBytes?: number): WordArray {
    return new WordArray(words, sigBytes);
  }
  toString(encoder: Encoder = Hex): string {
    return encoder.stringify(this);
  }
  concat(other: WordArray): WordArray {
    const bytes = concatBytes(bytesFromWordArray(this), bytesFromWordArray(other));
    this.words = wordsFromBytes(bytes);
    this.sigBytes = bytes.length;
    return this;
  }
  clamp(): void {
    const bytes = bytesFromWordArray(this);
    this.words = wordsFromBytes(bytes);
    this.sigBytes = bytes.length;
  }
}

function wordsFromBytes(bytes: Uint8Array): number[] {
  const words: number[] = [];
  for (let i = 0; i < bytes.length; i++) {
    words[i >>> 2] = (words[i >>> 2] || 0) | (bytes[i] << (24 - (i % 4) * 8));
  }
  return words;
}

export function bytesFromWordArray(value: WordArray): Uint8Array {
  const out = new Uint8Array(value.sigBytes);
  for (let i = 0; i < value.sigBytes; i++) {
    out[i] = (value.words[i >>> 2] >>> (24 - (i % 4) * 8)) & 0xff;
  }
  return out;
}

function concatBytes(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a);
  out.set(b, a.length);
  return out;
}

function utf8Bytes(text: string): Uint8Array {
  return new TextEncoder().encode(text);
}

function utf8String(bytes: Uint8Array): string {
  return new TextDecoder().decode(bytes);
}

const BASE64_ALPHABET =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

export function bytesToBase64(bytes: Uint8Array): string {
  let out = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i];
    const b = i + 1 < bytes.length ? bytes[i + 1] : 0;
    const c = i + 2 < bytes.length ? bytes[i + 2] : 0;
    out += BASE64_ALPHABET[a >> 2];
    out += BASE64_ALPHABET[((a & 3) << 4) | (b >> 4)];
    out += i + 1 < bytes.length ? BASE64_ALPHABET[((b & 15) << 2) | (c >> 6)] : "=";
    out += i + 2 < bytes.length ? BASE64_ALPHABET[c & 63] : "=";
  }
  return out;
}

export function base64ToBytes(text: string): Uint8Array {
  const clean = text.replace(/[^A-Za-z0-9+/=]/g, "");
  const out: number[] = [];
  for (let i = 0; i < clean.length; i += 4) {
    const c1 = BASE64_ALPHABET.indexOf(clean[i]);
    const c2 = BASE64_ALPHABET.indexOf(clean[i + 1]);
    const c3 = BASE64_ALPHABET.indexOf(clean[i + 2]);
    const c4 = BASE64_ALPHABET.indexOf(clean[i + 3]);
    if (c1 < 0 || c2 < 0) break;
    out.push((c1 << 2) | (c2 >> 4));
    if (c3 >= 0) out.push(((c2 & 15) << 4) | (c3 >> 2));
    if (c4 >= 0) out.push(((c3 & 3) << 6) | c4);
  }
  return new Uint8Array(out);
}

function bytesToHex(bytes: Uint8Array): string {
  let out = "";
  for (const byte of bytes) out += byte.toString(16).padStart(2, "0");
  return out;
}

function hexToBytes(text: string): Uint8Array {
  const clean = text.replace(/[^0-9a-fA-F]/g, "");
  const out = new Uint8Array(Math.floor(clean.length / 2));
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(clean.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

const Utf8 = {
  stringify: (value: WordArray) => utf8String(bytesFromWordArray(value)),
  parse: (text: string) => new WordArray(wordsFromBytes(utf8Bytes(text)), utf8Bytes(text).length),
};
const Latin1 = {
  stringify: (value: WordArray) => {
    const bytes = bytesFromWordArray(value);
    let out = "";
    for (const byte of bytes) out += String.fromCharCode(byte);
    return out;
  },
  parse: (text: string) => {
    const bytes = new Uint8Array(text.length);
    for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i) & 0xff;
    return new WordArray(wordsFromBytes(bytes), bytes.length);
  },
};
const Base64 = {
  stringify: (value: WordArray) => bytesToBase64(bytesFromWordArray(value)),
  parse: (text: string) => {
    const bytes = base64ToBytes(text);
    return new WordArray(wordsFromBytes(bytes), bytes.length);
  },
};
const Hex = {
  stringify: (value: WordArray) => bytesToHex(bytesFromWordArray(value)),
  parse: (text: string) => {
    const bytes = hexToBytes(text);
    return new WordArray(wordsFromBytes(bytes), bytes.length);
  },
};

function inputBytes(value: string | WordArray): Uint8Array {
  return typeof value === "string" ? utf8Bytes(value) : bytesFromWordArray(value);
}

function resultWordArray(bytes: Uint8Array): WordArray {
  return new WordArray(wordsFromBytes(bytes), bytes.length);
}

// ---------------------------------------------------------------- MD5 / SHA
const MD5_SHIFT = [
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5,
  9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11,
  16, 23, 4, 11, 16, 23, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10,
  15, 21,
];
const MD5_TABLE = (() => {
  const table = new Uint32Array(64);
  for (let i = 0; i < 64; i++) {
    table[i] = Math.floor(Math.abs(Math.sin(i + 1)) * 0x100000000) >>> 0;
  }
  return table;
})();

export function md5Bytes(input: Uint8Array): Uint8Array {
  const bitLength = input.length * 8;
  const paddedLength = (((input.length + 8) >>> 6) + 1) << 6;
  const padded = new Uint8Array(paddedLength);
  padded.set(input);
  padded[input.length] = 0x80;
  const view = new DataView(padded.buffer);
  view.setUint32(paddedLength - 8, bitLength >>> 0, true);
  view.setUint32(paddedLength - 4, Math.floor(bitLength / 0x100000000), true);
  let a0 = 0x67452301;
  let b0 = 0xefcdab89;
  let c0 = 0x98badcfe;
  let d0 = 0x10325476;
  const block = new Uint32Array(16);
  for (let offset = 0; offset < paddedLength; offset += 64) {
    for (let i = 0; i < 16; i++) block[i] = view.getUint32(offset + i * 4, true);
    let a = a0;
    let b = b0;
    let c = c0;
    let d = d0;
    for (let i = 0; i < 64; i++) {
      let f: number;
      let g: number;
      if (i < 16) {
        f = (b & c) | (~b & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | (~d & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | ~d);
        g = (7 * i) % 16;
      }
      f = (f + a + MD5_TABLE[i] + block[g]) >>> 0;
      a = d;
      d = c;
      c = b;
      const shift = MD5_SHIFT[i];
      b = (b + ((f << shift) | (f >>> (32 - shift)))) >>> 0;
    }
    a0 = (a0 + a) >>> 0;
    b0 = (b0 + b) >>> 0;
    c0 = (c0 + c) >>> 0;
    d0 = (d0 + d) >>> 0;
  }
  const out = new Uint8Array(16);
  const outView = new DataView(out.buffer);
  outView.setUint32(0, a0, true);
  outView.setUint32(4, b0, true);
  outView.setUint32(8, c0, true);
  outView.setUint32(12, d0, true);
  return out;
}

function rotateLeft(value: number, bits: number): number {
  return ((value << bits) | (value >>> (32 - bits))) >>> 0;
}

function rotateRight(value: number, bits: number): number {
  return ((value >>> bits) | (value << (32 - bits))) >>> 0;
}

export function sha1Bytes(input: Uint8Array): Uint8Array {
  const bitLength = input.length * 8;
  const paddedLength = (((input.length + 8) >>> 6) + 1) << 6;
  const padded = new Uint8Array(paddedLength);
  padded.set(input);
  padded[input.length] = 0x80;
  const view = new DataView(padded.buffer);
  view.setUint32(paddedLength - 8, Math.floor(bitLength / 0x100000000), false);
  view.setUint32(paddedLength - 4, bitLength >>> 0, false);
  let h0 = 0x67452301;
  let h1 = 0xefcdab89;
  let h2 = 0x98badcfe;
  let h3 = 0x10325476;
  let h4 = 0xc3d2e1f0;
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
      let f: number;
      let k: number;
      if (i < 20) {
        f = (b & c) | (~b & d);
        k = 0x5a827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ed9eba1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8f1bbcdc;
      } else {
        f = b ^ c ^ d;
        k = 0xca62c1d6;
      }
      const temp = (rotateLeft(a, 5) + f + e + k + w[i]) >>> 0;
      e = d;
      d = c;
      c = rotateLeft(b, 30);
      b = a;
      a = temp;
    }
    h0 = (h0 + a) >>> 0;
    h1 = (h1 + b) >>> 0;
    h2 = (h2 + c) >>> 0;
    h3 = (h3 + d) >>> 0;
    h4 = (h4 + e) >>> 0;
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

const SHA256_K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);

export function sha256Bytes(input: Uint8Array): Uint8Array {
  const bitLength = input.length * 8;
  const paddedLength = (((input.length + 8) >>> 6) + 1) << 6;
  const padded = new Uint8Array(paddedLength);
  padded.set(input);
  padded[input.length] = 0x80;
  const view = new DataView(padded.buffer);
  view.setUint32(paddedLength - 8, Math.floor(bitLength / 0x100000000), false);
  view.setUint32(paddedLength - 4, bitLength >>> 0, false);
  const h = new Uint32Array([
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c,
    0x1f83d9ab, 0x5be0cd19,
  ]);
  const w = new Uint32Array(64);
  for (let offset = 0; offset < paddedLength; offset += 64) {
    for (let i = 0; i < 16; i++) w[i] = view.getUint32(offset + i * 4, false);
    for (let i = 16; i < 64; i++) {
      const s0 = rotateRight(w[i - 15], 7) ^ rotateRight(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      const s1 = rotateRight(w[i - 2], 17) ^ rotateRight(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
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
      const ch = (e & f) ^ (~e & g);
      const temp1 = (hh + s1 + ch + SHA256_K[i] + w[i]) >>> 0;
      const s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const temp2 = (s0 + maj) >>> 0;
      hh = g;
      g = f;
      f = e;
      e = (d + temp1) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) >>> 0;
    }
    h[0] = (h[0] + a) >>> 0;
    h[1] = (h[1] + b) >>> 0;
    h[2] = (h[2] + c) >>> 0;
    h[3] = (h[3] + d) >>> 0;
    h[4] = (h[4] + e) >>> 0;
    h[5] = (h[5] + f) >>> 0;
    h[6] = (h[6] + g) >>> 0;
    h[7] = (h[7] + hh) >>> 0;
  }
  const out = new Uint8Array(32);
  const outView = new DataView(out.buffer);
  for (let i = 0; i < 8; i++) outView.setUint32(i * 4, h[i], false);
  return out;
}

function hmacBytes(
  hash: (bytes: Uint8Array) => Uint8Array,
  message: Uint8Array,
  key: Uint8Array,
): Uint8Array {
  const blockSize = 64;
  let blockKey = key.length > blockSize ? hash(key) : key;
  if (blockKey.length < blockSize) {
    const padded = new Uint8Array(blockSize);
    padded.set(blockKey);
    blockKey = padded;
  }
  const inner = new Uint8Array(blockSize + message.length);
  for (let i = 0; i < blockSize; i++) inner[i] = blockKey[i] ^ 0x36;
  inner.set(message, blockSize);
  const innerHash = hash(inner);
  // 外层长度必须按摘要长度分配：MD5 16 / SHA1 20 / SHA256 32，
  // 写死 32 会给 MD5 / SHA1 补零，签名直接算错。
  const outer = new Uint8Array(blockSize + innerHash.length);
  for (let i = 0; i < blockSize; i++) outer[i] = blockKey[i] ^ 0x5c;
  outer.set(innerHash, blockSize);
  return hash(outer);
}

/** 插件侧可用的 CryptoJS 子集。 */
const CryptoJS = {
  lib: { WordArray },
  enc: { Utf8, Latin1, Base64, Hex },
  MD5: (value: string | WordArray) => resultWordArray(md5Bytes(inputBytes(value))),
  SHA1: (value: string | WordArray) => resultWordArray(sha1Bytes(inputBytes(value))),
  SHA256: (value: string | WordArray) => resultWordArray(sha256Bytes(inputBytes(value))),
  HmacMD5: (message: string | WordArray, key: string | WordArray) =>
    resultWordArray(hmacBytes(md5Bytes, inputBytes(message), inputBytes(key))),
  HmacSHA1: (message: string | WordArray, key: string | WordArray) =>
    resultWordArray(hmacBytes(sha1Bytes, inputBytes(message), inputBytes(key))),
  HmacSHA256: (message: string | WordArray, key: string | WordArray) =>
    resultWordArray(hmacBytes(sha256Bytes, inputBytes(message), inputBytes(key))),
  AES: {
    decrypt: () => {
      throw new Error("当前插件沙箱不支持 AES 解密（少数插件的加密接口），请换用不依赖 AES 的插件版本");
    },
    encrypt: () => {
      throw new Error("当前插件沙箱不支持 AES 加密（少数插件的加密接口），请换用不依赖 AES 的插件版本");
    },
  },
};

// ---------------------------------------------------------------- fetch 代理
export interface PluginHttpRequest {
  url: string;
  method: string;
  headers: [string, string][];
  body: string | null;
  body_base64: string | null;
}

export interface PluginHttpResponse {
  status: number;
  url: string;
  headers: [string, string][];
  body_base64: string;
}

export type PluginHttpProxy = (
  request: PluginHttpRequest,
) => Promise<PluginHttpResponse>;

/** 桌面端注入的宿主能力：读插件文件 + 代发 HTTP。 */
export interface PluginHost {
  readCode: (sourceId: string) => Promise<string>;
  http: PluginHttpProxy;
}

let host: PluginHost | null = null;

/**
 * 接上宿主（桌面端启动时调用）：`readCode` 读数据目录里的插件文件，
 * `http` 走后端 `plugin_http` 命令。没接上时给出明确错误，而不是静默失败。
 */
export function configurePluginHost(next: PluginHost): void {
  host = next;
}

class SandboxHeaders {
  private map = new Map<string, string>();
  constructor(pairs: [string, string][] = []) {
    for (const [name, value] of pairs) this.map.set(name.toLowerCase(), value);
  }
  get(name: string): string | null {
    return this.map.get(name.toLowerCase()) ?? null;
  }
  has(name: string): boolean {
    return this.map.has(name.toLowerCase());
  }
  forEach(callback: (value: string, key: string) => void): void {
    this.map.forEach((value, key) => callback(value, key));
  }
}

function normalizeHeaders(input: unknown): [string, string][] {
  const pairs: [string, string][] = [];
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
    const maybeHeaders = input as { forEach?: (cb: (v: string, k: string) => void) => void };
    if (typeof maybeHeaders.forEach === "function" && !(input instanceof Map)) {
      try {
        maybeHeaders.forEach((value, key) => pairs.push([String(key), String(value)]));
        if (pairs.length) return pairs;
      } catch {
        /* 退回普通对象遍历 */
      }
    }
    for (const [key, value] of Object.entries(input as Record<string, unknown>)) {
      if (typeof value === "string") pairs.push([key, value]);
    }
  }
  return pairs;
}

function bodyBytes(body: unknown): { text?: string; base64?: string } {
  if (body === undefined || body === null) return {};
  if (typeof body === "string") return { text: body };
  if (typeof URLSearchParams !== "undefined" && body instanceof URLSearchParams) {
    return { text: body.toString() };
  }
  if (body instanceof ArrayBuffer) return { base64: bytesToBase64(new Uint8Array(body)) };
  if (ArrayBuffer.isView(body)) {
    return {
      base64: bytesToBase64(new Uint8Array(body.buffer, body.byteOffset, body.byteLength)),
    };
  }
  if (typeof FormData !== "undefined" && body instanceof FormData) {
    throw new Error("插件沙箱暂不支持 FormData 请求体，请改用字符串或 JSON");
  }
  return { text: String(body) };
}

export class SandboxResponse {
  ok: boolean;
  status: number;
  url: string;
  headers: SandboxHeaders;
  private bytes: Uint8Array;
  constructor(proxy: PluginHttpResponse) {
    this.status = proxy.status;
    this.ok = proxy.status >= 200 && proxy.status < 300;
    this.url = proxy.url;
    this.headers = new SandboxHeaders(proxy.headers);
    this.bytes = base64ToBytes(proxy.body_base64);
  }
  text(): string {
    return utf8String(this.bytes);
  }
  json(): unknown {
    return JSON.parse(this.text());
  }
  arrayBuffer(): ArrayBuffer {
    return this.bytes.buffer.slice(
      this.bytes.byteOffset,
      this.bytes.byteOffset + this.bytes.byteLength,
    ) as ArrayBuffer;
  }
}

async function sandboxFetch(
  input: string,
  init: {
    method?: string;
    headers?: unknown;
    body?: unknown;
    [key: string]: unknown;
  } = {},
): Promise<SandboxResponse> {
  if (!host) {
    throw new Error("插件宿主尚未连接：请重启 Awake 桌面应用后重试");
  }
  const body = bodyBytes(init.body);
  const proxy = await host.http({
    url: String(input),
    method: init.method || "GET",
    headers: normalizeHeaders(init.headers),
    body: body.text ?? null,
    body_base64: body.base64 ?? null,
  });
  return new SandboxResponse(proxy);
}

const silentConsole = {
  log: () => {},
  info: () => {},
  warn: () => {},
  error: () => {},
  debug: () => {},
};

/** 即时可用的插件代码，测试里传入夹具时不需要读盘。 */
export interface LoadedPlugin {
  sourceId: string;
  platform: string;
  exports: Record<string, any>;
}

const loaded = new Map<string, Promise<LoadedPlugin>>();

export function invalidatePlugin(sourceId: string): void {
  loaded.delete(sourceId);
}

/**
 * 装入插件代码。`new Function` 作用域里只有 module/exports/fetch/CryptoJS/console/timers/require，
 * 以及浏览器全局对象；插件拿不到 Tauri IPC（防止插件直接调用后端命令）。
 */
export function instantiatePlugin(code: string): Record<string, any> {
  const module: { exports: Record<string, any> } = { exports: {} };
  const requireShim = (name: string) => {
    if (name === "crypto-js") return CryptoJS;
    throw new Error(`插件沙箱不支持 require("${name}")，可用的只有 crypto-js 与 fetch`);
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
    code,
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
    queueMicrotask,
  );
  const exports = module.exports;
  if (!exports || typeof exports !== "object") {
    throw new Error("插件没有导出对象：请确认这是一个 MusicFree 兼容插件");
  }
  return exports;
}

/** 导入前校验：能执行、有 platform 或 search。返回 platform 名供展示。 */
export function validatePluginCode(code: string): { platform: string; hasSearch: boolean } {
  const exports = instantiatePlugin(code);
  const platform = typeof exports.platform === "string" ? exports.platform.trim() : "";
  const hasSearch = typeof exports.search === "function";
  if (!platform && !hasSearch) {
    throw new Error("这不是 MusicFree 兼容插件：缺少 platform 与 search");
  }
  return { platform, hasSearch };
}

export async function loadPlugin(sourceId: string): Promise<LoadedPlugin> {
  const cached = loaded.get(sourceId);
  if (cached) return cached;
  const promise = (async () => {
    if (!host) {
      throw new Error("插件宿主尚未连接：请重启 Awake 桌面应用后重试");
    }
    const code = await host.readCode(sourceId);
    const exports = instantiatePlugin(code);
    return {
      sourceId,
      platform: typeof exports.platform === "string" ? exports.platform : "",
      exports,
    };
  })();
  loaded.set(sourceId, promise);
  promise.catch(() => loaded.delete(sourceId));
  return promise;
}

/**
 * 直接把一份代码登记成某个来源的插件实例（不读盘）。
 * 导入前的试运行与测试都走这里；正式使用仍然由 loadPlugin 从数据目录读取。
 */
export function registerPluginCode(sourceId: string, code: string): LoadedPlugin {
  const exports = instantiatePlugin(code);
  const entry: LoadedPlugin = {
    sourceId,
    platform: typeof exports.platform === "string" ? exports.platform : "",
    exports,
  };
  loaded.set(sourceId, Promise.resolve(entry));
  return entry;
}

/** 搜索结果规范化：MusicFree 的 search 返回 { isEnd, data }，也有直接返回数组的。 */
export interface PluginItem {
  id: string | number | null;
  title: string;
  artist: string;
  album: string;
  duration: number;
  artwork: string;
  raw: Record<string, unknown>;
}

export function normalizeSearch(raw: unknown): { isEnd: boolean; items: PluginItem[] } {
  const record = raw as { isEnd?: unknown; data?: unknown } | unknown[] | null;
  const list = Array.isArray(record)
    ? record
    : Array.isArray((record as { data?: unknown })?.data)
      ? ((record as { data: unknown[] }).data as unknown[])
      : [];
  const items: PluginItem[] = [];
  for (const entry of list) {
    if (!entry || typeof entry !== "object") continue;
    const item = entry as Record<string, unknown>;
    const title = typeof item.title === "string" ? item.title.trim() : "";
    if (!title) continue;
    const duration = Number(item.duration);
    items.push({
      id:
        typeof item.id === "string" || typeof item.id === "number" ? item.id : null,
      title,
      artist: typeof item.artist === "string" ? item.artist : "",
      album: typeof item.album === "string" ? item.album : "",
      duration: Number.isFinite(duration) && duration > 0 ? duration : 0,
      artwork: typeof item.artwork === "string" ? item.artwork : "",
      raw: item,
    });
  }
  const isEnd =
    Array.isArray(record) ? true : (record as { isEnd?: unknown })?.isEnd !== false;
  return { isEnd, items };
}

export async function searchPlugin(
  sourceId: string,
  query: string,
  page = 1,
): Promise<{ isEnd: boolean; items: PluginItem[] }> {
  const plugin = await loadPlugin(sourceId);
  const search = plugin.exports.search;
  if (typeof search !== "function") {
    throw new Error("这个插件没有实现 search，只能用来解析固定来源");
  }
  const raw = await search(query, page, "music");
  return normalizeSearch(raw);
}

export interface ResolvedMedia {
  url: string;
  headers: [string, string][];
}

/** getMediaSource 的返回可以是字符串，也可以是 { url, headers }。 */
export function normalizeMediaSource(raw: unknown): ResolvedMedia | null {
  if (!raw) return null;
  if (typeof raw === "string") {
    return /^https?:\/\//i.test(raw) ? { url: raw, headers: [] } : null;
  }
  if (typeof raw !== "object") return null;
  const record = raw as { url?: unknown; headers?: unknown };
  const url = typeof record.url === "string" ? record.url : "";
  if (!/^https?:\/\//i.test(url)) return null;
  const headers: [string, string][] = [];
  const rawHeaders = record.headers;
  if (rawHeaders && typeof rawHeaders === "object") {
    for (const [name, value] of Object.entries(rawHeaders as Record<string, unknown>)) {
      if (typeof value === "string" && value) headers.push([name, value]);
    }
  }
  return { url, headers };
}

const QUALITY_FALLBACK = ["standard", "high", "super"] as const;

/** 用插件把一条曲目解析成可播放的直连地址（播放前由前端调用）。 */
export async function resolvePluginTrack(
  sourceId: string,
  locator: string,
): Promise<ResolvedMedia> {
  const plugin = await loadPlugin(sourceId);
  const getMediaSource = plugin.exports.getMediaSource;
  if (typeof getMediaSource !== "function") {
    throw new Error("这个插件没有实现 getMediaSource，无法播放");
  }
  let item: Record<string, unknown>;
  try {
    item = JSON.parse(locator);
  } catch {
    throw new Error("曲目数据不是有效的插件条目，请重新搜索入库");
  }
  let lastError: unknown = null;
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
      `插件解析失败：${String(lastError).replace(/^Error: /, "")}`,
    );
  }
  throw new Error("插件没有返回可播放的地址（该曲目可能需要登录或已失效）");
}

/** 入库载荷：把搜索结果换成后端 save_plugin_tracks 的字段。 */
export interface PluginTrackPayload {
  title: string;
  artist: string;
  album: string;
  duration: number;
  artwork: string;
  item: Record<string, unknown>;
}

export function toPayload(item: PluginItem): PluginTrackPayload {
  return {
    title: item.title,
    artist: item.artist,
    album: item.album,
    duration: item.duration,
    artwork: item.artwork,
    item: jsonSafe(item.raw),
  };
}

/** 插件返回的原始对象可能带 undefined / 函数 / 循环引用；入库前先洗成纯 JSON。 */
function jsonSafe(value: Record<string, unknown>): Record<string, unknown> {
  try {
    return JSON.parse(JSON.stringify(value)) as Record<string, unknown>;
  } catch {
    throw new Error("插件返回的曲目数据无法序列化（可能包含循环引用）");
  }
}

// ---------------------------------------------------------------- 插件源（registry）
//
// MusicFree / 枪弹分离 的插件市场是一个 JSON：{ "plugins": [ { name, url, version } ] }。
// 直接让用户一个个下载 .js 太原始；这里把它规整成稳定的形状，UI 只负责展示与点击。
//
// 兼容三种常见外层：{ plugins: [...] }、{ data: [...] }、裸数组。
// 只接受 http(s) 的绝对地址；重名不算重（不同源的插件可能同名），按 url 去重。

export interface PluginRegistryEntry {
  name: string;
  url: string;
  version?: string;
}

export const REGISTRY_LIMIT = 200;

export function parsePluginRegistry(input: unknown): PluginRegistryEntry[] {
  const raw = Array.isArray(input)
    ? input
    : input && typeof input === "object"
      ? ((input as Record<string, unknown>).plugins ??
         (input as Record<string, unknown>).data ??
         (input as Record<string, unknown>).list)
      : null;
  if (!Array.isArray(raw)) throw new Error("这不是插件源：找不到插件列表");
  const out: PluginRegistryEntry[] = [];
  const seen = new Set<string>();
  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const rec = item as Record<string, unknown>;
    const name = typeof rec.name === "string" ? rec.name.trim() : "";
    const url = typeof rec.url === "string" ? rec.url.trim() : "";
    if (!name || !url) continue;
    if (!/^https?:\/\//i.test(url)) continue;
    if (seen.has(url)) continue;
    seen.add(url);
    const version = typeof rec.version === "string" ? rec.version.trim() : undefined;
    out.push(version ? { name, url, version } : { name, url });
    if (out.length >= REGISTRY_LIMIT) break;
  }
  if (!out.length) throw new Error("插件源里没有可用的插件");
  return out;
}

/** 从插件地址推出一个文件名，写进来源时用；推不出就叫 plugin.js。 */
export function pluginFileNameFromURL(url: string): string {
  try {
    const path = new URL(url).pathname;
    const last = path.split("/").filter(Boolean).pop() ?? "";
    return /^[\w.-]+\.js$/i.test(last) ? last : "plugin.js";
  } catch {
    return "plugin.js";
  }
}

