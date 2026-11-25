<script setup lang="ts">
/**
 * 电台台站列表。
 *
 * 判定与缓存都在 Rust（`awake_core::radio` + `radio_stations` 命令），这里只做三件事：
 * 拉一次、显示每台"能不能放"、给一个按钮真探一次。
 *
 * 刻意不做的事：这里**不自己判编码**。界面若也判一遍，两处结论早晚不一致，
 * 而用户看到的是界面那份——那才是错的。
 */
import { onMounted, ref } from "vue";
import Icon from "./Icon.vue";
import { call, desktop } from "./bridge";

interface StationView {
  uuid: string;
  name: string;
  url: string;
  homepage: string;
  favicon: string;
  tags: string[];
  country: string;
  codec: string;
  bitrate: number;
  votes: number;
  clicks: number;
  support: "yes" | "unverified" | "no";
  verdict: string;
  can_play: boolean;
  needs_ffmpeg: boolean;
  probed_at_ms: number;
}

interface StationList {
  server: string;
  fetched: number;
  shown: number;
  hidden: number;
  stations: StationView[];
  note: string;
}

const query = ref("");
const list = ref<StationList | null>(null);
const busy = ref(false);
const error = ref("");
const probing = ref("");
const copied = ref("");

async function load() {
  if (busy.value) return;
  busy.value = true;
  error.value = "";
  copied.value = "";
  try {
    list.value = await call<StationList>("list_radio_stations", {
      query: query.value.trim() || null,
      limit: 120,
    });
  } catch (issue) {
    list.value = null;
    error.value = String(issue);
  } finally {
    busy.value = false;
  }
}

async function probe(station: StationView) {
  if (!desktop || probing.value) return;
  probing.value = station.uuid;
  error.value = "";
  try {
    await call("probe_radio_station", { uuid: station.uuid, url: station.url });
    // 结论已经写进缓存，重拉一次让判定在 Rust 里重算——界面不自己改结论。
    await load();
  } catch (issue) {
    error.value = String(issue);
  } finally {
    probing.value = "";
  }
}

async function copyUrl(station: StationView) {
  try {
    await navigator.clipboard.writeText(station.url);
    copied.value = station.uuid;
    window.setTimeout(() => {
      if (copied.value === station.uuid) copied.value = "";
    }, 1600);
  } catch (issue) {
    error.value = `复制失败：${issue}`;
  }
}

function badgeText(station: StationView): string {
  if (station.probed_at_ms) return "已探测";
  if (station.support === "yes") return "解码器支持";
  if (station.support === "unverified") return "编码未验证";
  return "不支持";
}

onMounted(() => {
  void load();
});
</script>

<template>
  <article class="source-card stations">
    <span class="source-icon"><Icon name="cast" :size="26" /></span>
    <div class="body">
      <span class="subtle-badge">公开电台目录</span>
      <h2>台站</h2>
      <p class="lead">
        从 radio-browser 拉一份公开台站列表。每台的"能不能放"由这里的解码器判断，
        不看台站自己的声明；拿不准的先标未验证。
      </p>

      <p v-if="!desktop" class="hint">
        浏览器预览里只有示例台站；真实目录、探测与判定都在桌面版。
      </p>

      <form class="search" @submit.prevent="load">
        <label class="field">
          <span class="visually-hidden">按名字搜索台站</span>
          <input
            v-model="query"
            type="search"
            placeholder="按名字搜，例如 jazz、BBC、古典"
            spellcheck="false"
          />
        </label>
        <button class="button primary" type="submit" :disabled="!desktop || busy">
          <Icon name="search" :size="15" />{{ busy ? "拉取中…" : "获取台站" }}
        </button>
        <button
          class="button ghost"
          type="button"
          :disabled="!desktop || busy || !list"
          @click="load"
        >
          <Icon name="refresh" :size="15" />刷新
        </button>
      </form>

      <p v-if="error" class="job-error">
        {{ error }}
        <br />
        <small>检查网络后点「刷新」；一直失败就是目录服务连不上，不是你的设置问题。</small>
      </p>

      <p v-if="list" class="meta">
        {{ list.note }} · 拉到 {{ list.fetched }} 条 · 列出 {{ list.shown }} 条<template
          v-if="list.hidden"
        >（{{ list.hidden }} 条编码解不了，已挡掉）</template>
      </p>

      <p v-if="busy && !list" class="hint">正在连目录…</p>

      <ul v-if="list && list.stations.length" class="grid">
        <li
          v-for="station in list.stations"
          :key="station.uuid || station.url"
          class="station"
          :class="{ muted: !station.can_play }"
        >
          <div class="head">
            <strong :title="station.name">{{ station.name || "未命名台站" }}</strong>
            <span class="badge" :class="station.support">{{ badgeText(station) }}</span>
          </div>
          <p class="line">
            {{ station.country || "地区未知" }}
            <template v-if="station.codec"> · {{ station.codec }}</template>
            <template v-if="station.bitrate"> · {{ station.bitrate }}k</template>
            <template v-if="station.votes"> · {{ station.votes }} 票</template>
          </p>
          <p class="verdict">{{ station.verdict }}</p>
          <div class="actions">
            <button
              class="button tiny"
              type="button"
              :disabled="!desktop || Boolean(probing)"
              @click="probe(station)"
            >
              <Icon name="play" :size="13" />{{ probing === station.uuid ? "探测中…" : "探测" }}
            </button>
            <button class="button tiny ghost" type="button" @click="copyUrl(station)">
              <Icon name="copy" :size="13" />{{ copied === station.uuid ? "已复制" : "复制地址" }}
            </button>
          </div>
        </li>
      </ul>

      <p v-else-if="list" class="hint empty">
        没拉到台站。换一个搜索词（英文关键词命中更多），或者点「刷新」再试一次。
      </p>

      <p class="hint">
        探测会真的连上去解 4 秒，结论存 7 天。内置播放还没接——现在先探测、复制地址。
      </p>
    </div>
  </article>
</template>

<style scoped>
.stations .body {
  display: grid;
  gap: 10px;
}
.stations h2 {
  margin: 0;
  font-size: 17px;
}
.lead,
.hint,
.meta {
  margin: 0;
  color: var(--text-dim);
  font-size: 13px;
  line-height: 1.6;
}
.meta {
  color: var(--text-muted);
  font-size: 12px;
}
.search {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
  align-items: end;
}
.field {
  flex: 1 1 220px;
  display: grid;
  gap: 4px;
}
.field input {
  width: 100%;
  min-height: 40px;
  padding: 8px 10px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--surface);
  color: var(--text);
  font-size: 13px;
}
.field input:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 1px;
}
.visually-hidden {
  position: absolute;
  width: 1px;
  height: 1px;
  overflow: hidden;
  clip: rect(0 0 0 0);
  white-space: nowrap;
}
.grid {
  list-style: none;
  margin: 0;
  padding: 0;
  display: grid;
  /* 容器比 240 还窄时按 100% 走一列：minmax 的固定下限会撑破卡片。 */
  grid-template-columns: repeat(auto-fill, minmax(min(240px, 100%), 1fr));
  gap: 8px;
  max-height: 460px;
  overflow: auto;
}
.station {
  display: grid;
  gap: 6px;
  /* grid item 默认 min-width:auto：badge 的 nowrap 会把卡片按内容撑宽，超出容器。 */
  min-width: 0;
  padding: 10px 12px;
  border: 1px solid var(--line);
  border-radius: 10px;
  background: var(--raised);
  transition: border-color 180ms ease;
}
.station:hover {
  border-color: var(--accent);
}
.station.muted {
  opacity: 0.72;
}
.head {
  display: flex;
  gap: 8px;
  align-items: baseline;
  justify-content: space-between;
  min-width: 0;
}
.head strong {
  /* flex 子项默认 min-width:auto 不会收缩，省略号就永远不出现，徽标会被挤成一条线。 */
  flex: 1 1 auto;
  min-width: 0;
  font-size: 13px;
  line-height: 1.4;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.badge {
  flex: none;
  white-space: nowrap;
  padding: 2px 6px;
  border-radius: 999px;
  font-size: 11px;
  background: var(--surface);
  color: var(--text-muted);
}
.badge.yes {
  color: var(--accent);
}
.badge.unverified {
  color: var(--text-dim);
  border: 1px dashed var(--line);
}
.badge.no {
  color: var(--danger, #d4675f);
}
.line,
.verdict {
  margin: 0;
  font-size: 12px;
  line-height: 1.5;
  color: var(--text-muted);
}
.verdict {
  color: var(--text-dim);
}
.actions {
  display: flex;
  gap: 6px;
  flex-wrap: wrap;
}
.button.tiny {
  padding: 4px 8px;
  font-size: 12px;
}
.button.ghost {
  background: transparent;
}
.empty {
  padding: 12px;
  border: 1px dashed var(--line);
  border-radius: 10px;
}
@media (max-width: 480px) {
  .grid {
    grid-template-columns: 1fr;
    max-height: none;
  }
  .search {
    flex-direction: column;
    align-items: stretch;
  }
  /* 竖排时 flex-basis 会变成高度：不重置的话搜索框会被撑成 220px 的方块。 */
  .field {
    flex: none;
  }
  /* 手机上没有横向空间给装饰图标，宽度留给列表本身。 */
  .stations > .source-icon {
    display: none;
  }
}
</style>
