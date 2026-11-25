<script setup lang="ts">
/**
 * 艺人页：只讲"你和他之间发生了什么"。
 * 数字全部来自本地播放事件（`ListenEvent`）+ 曲库标签，不联网、不查百科。
 */
import { computed } from "vue";
import type { ArtistProfile } from "./insight";

const props = defineProps<{ profiles: ArtistProfile[] }>();
const emit = defineEmits<{ play: [artist: string] }>();

const sorted = computed(() =>
  [...props.profiles].sort((a, b) => b.plays - a.plays || a.artist.localeCompare(b.artist)),
);

function percent(value: number): string {
  return `${Math.round(value * 100)}%`;
}
</script>

<template>
  <div class="page-intro">
    <div>
      <p class="eyebrow">YOUR ARTISTS</p>
      <h1>你听过的，<span class="serif">才在这里。</span></h1>
      <p>只统计库里有的艺人；没听过的不会有条目——所以这里没有"百科"，只有你的事。</p>
    </div>
  </div>

  <div v-if="!sorted.length" class="artist-empty">
    <strong>还没有艺人画像</strong>
    <p>先播几首、让记录跑起来；达到合格播放阈值后才会进这里。</p>
  </div>

  <ul v-else class="artist-list">
    <li v-for="item in sorted" :key="item.artist">
      <button type="button" class="artist-row" @click="emit('play', item.artist)">
        <span class="who">
          <strong>{{ item.artist }}</strong>
          <small v-if="item.top_genres.length">{{ item.top_genres.join(" · ") }}</small>
        </span>
        <span class="line">{{ item.line }}</span>
        <span class="bar" :title="`完成率 ${percent(item.completion_rate)}`">
          <i :style="{ width: percent(item.completion_rate) }" />
        </span>
        <span class="stats">
          播 {{ item.plays }} · 跳过 {{ item.skips }} · 完成率 {{ percent(item.completion_rate) }}
        </span>
      </button>
    </li>
  </ul>
</template>

<style scoped>
.artist-list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: grid;
  gap: 8px;
}
.artist-row {
  display: grid;
  grid-template-columns: minmax(120px, 1fr) minmax(0, 2fr) 96px;
  gap: 12px;
  align-items: center;
  width: 100%;
  padding: 12px 14px;
  border: 1px solid var(--line);
  border-radius: 12px;
  background: var(--surface);
  color: var(--text);
  text-align: left;
  cursor: pointer;
}
.artist-row:hover {
  border-color: var(--accent);
}
.artist-row:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
}
.who {
  display: grid;
  gap: 2px;
}
.who small {
  color: var(--text-muted);
}
.line,
.stats {
  color: var(--text-dim);
  font-size: 12px;
}
.stats {
  grid-column: 1 / -1;
}
.bar {
  display: block;
  height: 4px;
  border-radius: 999px;
  background: var(--line);
  overflow: hidden;
}
.bar i {
  display: block;
  height: 100%;
  background: var(--accent);
}
.artist-empty {
  border: 1px dashed var(--line);
  border-radius: 12px;
  padding: 20px;
  color: var(--text-dim);
}
.artist-empty strong {
  color: var(--text);
}
@media (max-width: 767px) {
  .artist-row {
    grid-template-columns: 1fr;
  }
}
</style>
