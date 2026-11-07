<script setup lang="ts">
import { computed, onMounted, ref, watch } from "vue";
import { invoke, convertFileSrc } from "@tauri-apps/api/core";

interface Track {
  id: string;
  title: string;
  artist: string;
  album_artist: string;
  album: string;
  genre: string;
  year: number | null;
  track_number: number | null;
  disc_number: number | null;
  duration: number;
  sample_rate: number;
  bit_depth: number;
  channels: number;
  codec: string;
  source_id: string;
  locator: string;
  file_size: number;
  artwork_path: string | null;
  play_count: number;
  favorite: boolean;
  is_remote: boolean;
}

interface Album {
  id: string;
  title: string;
  artist: string;
  year: number | null;
  artwork_path: string | null;
  tracks: Track[];
}

interface MediaSource {
  id: string;
  kind: string;
  name: string;
  url: string;
  track_count: number;
}

type View = "albums" | "songs";

const tracks = ref<Track[]>([]);
const albums = ref<Album[]>([]);
const sources = ref<MediaSource[]>([]);
const view = ref<View>("albums");
const openAlbum = ref<Album | null>(null);
const scanning = ref(false);
const scanMsg = ref("");
const status = ref("");
const playing = ref(false);
const nowPlaying = ref<Track | null>(null);
const eqOpen = ref(false);
const gains = ref<number[]>(new Array(31).fill(0));
const tint = ref("210, 190, 255");

const BAND_FREQS = [
  20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160,
  200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600,
  2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000,
];

const DEMO_PATH = "../DemoMusic";

function artUrl(path: string | null): string | null {
  if (!path) return null;
  return convertFileSrc(path);
}

function fmtDuration(secs: number): string {
  if (!secs || secs <= 0) return "–:––";
  const m = Math.floor(secs / 60);
  const s = Math.floor(secs % 60);
  return `${m}:${s.toString().padStart(2, "0")}`;
}

function qualityOf(t: Track): string {
  if (t.codec?.toUpperCase() === "DSD") {
    return `DSD ${(t.sample_rate / 1000000).toFixed(1)} MHz`;
  }
  const khz = t.sample_rate >= 1000 ? (t.sample_rate / 1000).toFixed(1) : String(t.sample_rate);
  return `${t.codec || "PCM"} ${t.bit_depth}-bit / ${khz} kHz`;
}

function isHires(t: Track): boolean {
  return t.sample_rate > 48000 || t.bit_depth > 16;
}

async function refresh() {
  const lib = await invoke<{ tracks: Track[]; albums: Album[]; sources: MediaSource[] }>(
    "load_library"
  );
  tracks.value = lib.tracks;
  albums.value = lib.albums;
  sources.value = lib.sources;
}

async function doScan(path = DEMO_PATH) {
  scanning.value = true;
  scanMsg.value = "正在扫描…";
  try {
    const res = await invoke<{ tracks: Track[]; albums: Album[]; elapsed_ms: number }>(
      "scan_library",
      { req: { path, name: "演示曲库" } }
    );
    tracks.value = res.tracks;
    albums.value = res.albums;
    scanMsg.value = `扫描完成：${res.tracks.length} 首 / ${res.albums.length} 张专辑 · ${res.elapsed_ms} ms`;
    await refresh();
  } catch (e) {
    scanMsg.value = String(e);
  } finally {
    scanning.value = false;
  }
}

async function play(t: Track) {
  status.value = "正在解码…";
  nowPlaying.value = t;
  try {
    await invoke("play_track", {
      req: { source_id: t.source_id, locator: t.locator, gains: gains.value },
    });
    playing.value = true;
    status.value = `播放中 · ${qualityOf(t)}`;
  } catch (e) {
    playing.value = false;
    status.value = String(e);
  }
}

async function stop() {
  await invoke("stop_playback");
  playing.value = false;
  status.value = "已停止";
}

async function togglePlay() {
  if (playing.value) await stop();
  else if (nowPlaying.value) await play(nowPlaying.value);
}

function selectAlbum(a: Album) {
  openAlbum.value = a;
  if (a.tracks[0]?.artwork_path) void applyTint(a.tracks[0].artwork_path);
}

// 从封面提取主色，驱动界面色调
async function applyTint(artPath: string) {
  try {
    const src = convertFileSrc(artPath);
    const img = new Image();
    img.crossOrigin = "anonymous";
    await new Promise<void>((resolve, reject) => {
      img.onload = () => resolve();
      img.onerror = () => reject(new Error("load fail"));
      img.src = src;
    });
    const canvas = document.createElement("canvas");
    canvas.width = 24;
    canvas.height = 24;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.drawImage(img, 0, 0, 24, 24);
    const data = ctx.getImageData(0, 0, 24, 24).data;
    let r = 0, g = 0, b = 0, n = 0;
    for (let i = 0; i < data.length; i += 4) {
      const rr = data[i], gg = data[i + 1], bb = data[i + 2];
      const max = Math.max(rr, gg, bb), min = Math.min(rr, gg, bb);
      if (max - min < 24) continue;
      r += rr; g += gg; b += bb; n++;
    }
    if (n === 0) {
      r = 160; g = 150; b = 200; n = 1;
    }
    tint.value = `${Math.round(r / n)}, ${Math.round(g / n)}, ${Math.round(b / n)}`;
  } catch {
    /* 取色失败不影响界面 */
  }
}

function resetEq() {
  gains.value = new Array(31).fill(0);
  void invoke("set_eq_curve", { req: { gains: gains.value, preamp: 0 } });
}

function applyEqPreset(kind: "low" | "vocal" | "flat") {
  const g = new Array(31).fill(0);
  if (kind === "low") {
    for (let i = 0; i < 31; i++) {
      if (BAND_FREQS[i] <= 120) g[i] = 4;
      else if (BAND_FREQS[i] >= 8000) g[i] = -2;
    }
  } else if (kind === "vocal") {
    for (let i = 0; i < 31; i++) {
      if (BAND_FREQS[i] >= 1000 && BAND_FREQS[i] <= 4000) g[i] = 3;
      else if (BAND_FREQS[i] >= 10000) g[i] = -3;
    }
  }
  gains.value = g;
  void invoke("set_eq_curve", { req: { gains: g, preamp: 0 } });
}

const currentList = computed<Track[]>(() =>
  openAlbum.value ? openAlbum.value.tracks : tracks.value
);

const totalDuration = computed(() =>
  currentList.value.reduce((sum, t) => sum + (t.duration || 0), 0)
);

// 交通灯默认隐去，鼠标进入窗口顶部 56px 时浮现，离开即收回。
// 这样顶栏不占任何视觉空间，又能随时拿到窗口控制。
let lightsVisible = false;
async function syncTrafficLights(visible: boolean) {
  if (visible === lightsVisible) return;
  lightsVisible = visible;
  await invoke("set_traffic_lights", { visible }).catch(() => {});
}

function onWindowMouseMove(e: MouseEvent) {
  void syncTrafficLights(e.clientY <= 56);
}

onMounted(async () => {
  await invoke("frontend_ready", { version: "0.1.0", tracks: 0 }).catch(() => {});
  // 启动即隐藏，进入窗口后再按位置决定
  await invoke("set_traffic_lights", { visible: false }).catch(() => {});
  window.addEventListener("mousemove", onWindowMouseMove);
  await refresh();
  if (tracks.value.length === 0) {
    await doScan();
  }
});

watch(eqOpen, (v) => {
  if (v) void invoke("set_eq_curve", { req: { gains: gains.value, preamp: 0 } });
});
</script>

<template>
  <div class="app" :style="{ '--tint': tint }">
    <!-- 主区顶部透明拖拽带 -->
    <div class="main-drag" data-tauri-drag-region />
    <!-- 侧栏 -->
    <aside class="sidebar">
      <div class="sidebar-head" data-tauri-drag-region @mouseenter="syncTrafficLights(true)" @mouseleave="syncTrafficLights(false)" />
      <div class="brand">Awake <span>Rust</span></div>

      <div class="nav-section">曲库</div>
      <button
        class="nav-item"
        :class="{ active: view === 'albums' && !openAlbum }"
        @click="(view = 'albums'), (openAlbum = null)"
      >
        <span>◎</span> 专辑
        <span class="count">{{ albums.length }}</span>
      </button>
      <button
        class="nav-item"
        :class="{ active: view === 'songs' && !openAlbum }"
        @click="(view = 'songs'), (openAlbum = null)"
      >
        <span>≡</span> 歌曲
        <span class="count">{{ tracks.length }}</span>
      </button>

      <div class="nav-section">来源</div>
      <button
        v-for="s in sources"
        :key="s.id"
        class="nav-item"
      >
        <span>▸</span> {{ s.name }}
        <span class="count">{{ s.track_count }}</span>
      </button>
      <button class="nav-item" :disabled="scanning" @click="doScan(DEMO_PATH)">
        <span v-if="scanning" class="spin" />
        <span v-else>+</span> 扫描演示曲库
      </button>

      <div class="nav-section">声音</div>
      <button class="nav-item" :class="{ active: eqOpen }" @click="eqOpen = !eqOpen">
        <span>≈</span> 31 段 EQ
      </button>
    </aside>

    <!-- 主区 -->
    <main class="main">
      <template v-if="openAlbum">
        <div class="back-row">
          <div class="big-art">
            <img
              v-if="artUrl(openAlbum.artwork_path)"
              :src="artUrl(openAlbum.artwork_path)!"
              alt=""
            />
            <span v-else>♪</span>
          </div>
          <div>
            <div class="page-title">{{ openAlbum.title }}</div>
            <div class="page-sub">
              {{ openAlbum.artist }}
              <template v-if="openAlbum.year"> · {{ openAlbum.year }}</template>
              · {{ openAlbum.tracks.length }} 首 ·
              {{ Math.round(openAlbum.tracks.reduce((s, t) => s + t.duration, 0) / 60) }} 分钟
            </div>
            <button class="btn primary" @click="play(openAlbum.tracks[0])">播放全部</button>
            <button class="btn" style="margin-left: 8px" @click="openAlbum = null">返回</button>
          </div>
        </div>

        <div
          v-for="(t, i) in openAlbum.tracks"
          :key="t.id"
          class="track-row"
          :class="{ playing: nowPlaying?.id === t.id }"
          @dblclick="play(t)"
        >
          <span class="idx">{{ t.track_number ?? i + 1 }}</span>
          <span class="title">{{ t.title }}</span>
          <span>{{ fmtDuration(t.duration) }}</span>
          <span class="quality">{{ qualityOf(t) }}</span>
        </div>
      </template>

      <template v-else-if="view === 'albums'">
        <div class="page-title">专辑</div>
        <div class="page-sub">
          {{ albums.length }} 张专辑 · {{ tracks.length }} 首曲目
          <template v-if="scanMsg"> · {{ scanMsg }}</template>
        </div>
        <div class="album-grid">
          <div
            v-for="a in albums"
            :key="a.id"
            class="album-card"
            @dblclick="selectAlbum(a)"
            @click="selectAlbum(a)"
          >
            <div class="album-art">
              <img v-if="artUrl(a.artwork_path)" :src="artUrl(a.artwork_path)!" alt="" />
              <span v-else>♪</span>
            </div>
            <div class="album-title">{{ a.title }}</div>
            <div class="album-meta">
              {{ a.artist }}
              <span v-if="a.tracks.some(isHires)" class="badge-hires">HI-RES</span>
            </div>
          </div>
        </div>
        <div v-if="albums.length === 0" class="empty">
          <div class="empty-icon">◎</div>
          <div class="empty-title">曲库还是空的</div>
          <div class="empty-desc">
            点左侧「扫描演示曲库」把 DemoMusic 里的 9 首 24-bit / 96 kHz 样例收进来。
          </div>
        </div>
      </template>

      <template v-else>
        <div class="page-title">歌曲</div>
        <div class="page-sub">
          {{ tracks.length }} 首 · 共 {{ fmtDuration(totalDuration) }}
        </div>
        <div
          v-for="(t, i) in tracks"
          :key="t.id"
          class="track-row"
          :class="{ playing: nowPlaying?.id === t.id }"
          @dblclick="play(t)"
        >
          <span class="idx">{{ i + 1 }}</span>
          <span class="title">{{ t.title }} <small style="opacity:.5">· {{ t.album }}</small></span>
          <span>{{ fmtDuration(t.duration) }}</span>
          <span class="quality">{{ qualityOf(t) }}</span>
        </div>
      </template>
    </main>

    <!-- EQ 面板 -->
    <div class="eq-panel" :class="{ open: eqOpen }">
      <div class="eq-head">
        <div class="eq-title">31 段 EQ</div>
        <button class="btn" @click="eqOpen = false">收起</button>
      </div>
      <div class="eq-sub">ISO 1/3 倍频程 · 每段 Q ≈ 4.32 · 自动余量保护</div>
      <div class="eq-bands">
        <div v-for="(f, i) in BAND_FREQS" :key="i" class="eq-band">
          <span class="val">{{ gains[i] > 0 ? "+" : "" }}{{ gains[i].toFixed(0) }}</span>
          <input
            type="range"
            min="-12"
            max="12"
            step="0.5"
            v-model.number="gains[i]"
            @change="invoke('set_eq_curve', { req: { gains, preamp: 0 } })"
          />
          <span class="freq">{{ f >= 1000 ? f / 1000 + "k" : f }}</span>
        </div>
      </div>
      <div class="eq-actions">
        <button class="btn" @click="applyEqPreset('flat')">平坦</button>
        <button class="btn" @click="applyEqPreset('low')">低频</button>
        <button class="btn" @click="applyEqPreset('vocal')">人声</button>
        <button class="btn" @click="resetEq">重置</button>
      </div>
    </div>

    <!-- 播放条 -->
    <footer class="playbar">
      <div class="now-info">
        <div class="now-art">
          <img
            v-if="nowPlaying && artUrl(nowPlaying.artwork_path)"
            :src="artUrl(nowPlaying.artwork_path!)!"
            alt=""
          />
          <span v-else>♪</span>
        </div>
        <div class="now-text">
          <div class="now-title">{{ nowPlaying?.title ?? "未在播放" }}</div>
          <div class="now-artist">
            {{ nowPlaying ? nowPlaying.artist + " · " + nowPlaying.album : "双击曲目开始播放" }}
          </div>
        </div>
      </div>

      <div class="transport">
        <button class="play-btn" :disabled="!nowPlaying" @click="togglePlay">
          <span v-if="playing">❙❙</span>
          <span v-else>▶</span>
        </button>
      </div>

      <div class="status-line">{{ status }}</div>
    </footer>
  </div>
</template>
