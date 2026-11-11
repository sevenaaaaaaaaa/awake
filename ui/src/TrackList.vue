<script setup lang="ts">
import Icon from "./Icon.vue";
import Artwork from "./Artwork.vue";
import { duration, type Track } from "./types";
defineProps<{
  tracks: Track[];
  currentId?: string;
  favorites: Set<string>;
  reasons?: Record<string, string>;
  empty?: string;
}>();
defineEmits<{ play: [track: Track]; favorite: [track: Track] }>();
</script>
<template>
  <div class="track-table">
    <div class="table-head">
      <span>#</span><span>曲目</span><span class="album-column">专辑</span
      ><span>时长</span><span />
    </div>
    <div
      v-for="(t, i) in tracks"
      :key="t.id"
      class="track-row"
      :class="{ current: currentId === t.id }"
    >
      <button
        class="row-play"
        :aria-label="`播放 ${t.title}`"
        @click="$emit('play', t)"
      >
        <Icon v-if="currentId === t.id" name="wave" /><span
          v-else
          class="row-number"
          >{{ String(i + 1).padStart(2, "0") }}</span
        ><Icon class="row-play-icon" name="play" />
      </button>
      <button class="track-name" @click="$emit('play', t)">
        <Artwork :path="t.artwork_path" :seed="t.album" /><span
          ><strong>{{ t.title }}</strong
          ><small>{{ reasons?.[t.id] || t.artist || "未知艺人" }}</small></span
        >
      </button>
      <span class="album-column muted ellipsis">{{ t.album }}</span
      ><span class="mono muted">{{ duration(t.duration) }}</span>
      <button
        class="icon-btn"
        :class="{ loved: favorites.has(t.id) }"
        :aria-label="`${favorites.has(t.id) ? '取消收藏' : '收藏'} ${t.title}`"
        :aria-pressed="favorites.has(t.id)"
        @click="$emit('favorite', t)"
      >
        <Icon name="heart" />
      </button>
    </div>
    <div v-if="!tracks.length" class="list-empty">
      {{ empty || "暂时没有曲目，先添加你的音乐。" }}
    </div>
  </div>
</template>
