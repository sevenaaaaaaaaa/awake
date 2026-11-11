<script setup lang="ts">
import Icon from "./Icon.vue";
import Artwork from "./Artwork.vue";
import { duration, type Track } from "./types";
import { call } from "./bridge";
function origin(track: Track) {
  if (track.origin_url) void call("open_telegram_link", { url: track.origin_url });
}
defineProps<{
  tracks: Track[];
  currentId?: string;
  favorites: Set<string>;
  reasons?: Record<string, string>;
  empty?: string;
}>();
defineEmits<{ play: [track: Track]; favorite: [track: Track]; edit: [track: Track] }>();
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
      @contextmenu.prevent="$emit('edit', t)"
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
        <Artwork :path="t.artwork_path" :seed="t.album || t.title" :style-name="t.media_info?.cover_style" /><span
          ><strong>{{ t.title }}</strong
          ><small>{{ reasons?.[t.id] || t.artist || "未知艺人" }}</small></span
        >
      </button>
      <span class="album-column muted ellipsis">{{ t.album }}<button v-if="t.origin_url" type="button" class="text-button" :aria-label="`查看 ${t.title} 的原始消息`" @click="origin(t)">原始消息</button></span
      ><span class="mono muted">{{ duration(t.duration) }}</span>
      <div class="track-actions"><button class="icon-btn" :aria-label="`整理 ${t.title} 的封面、歌词与乐评`" @click="$emit('edit',t)"><Icon name="info" /></button><button
        class="icon-btn"
        :class="{ loved: favorites.has(t.id) }"
        :aria-label="`${favorites.has(t.id) ? '取消收藏' : '收藏'} ${t.title}`"
        :aria-pressed="favorites.has(t.id)"
        @click="$emit('favorite', t)"
      >
        <Icon name="heart" />
      </button></div>
    </div>
    <div v-if="!tracks.length" class="list-empty">
      {{ empty || "暂时没有曲目，先添加你的音乐。" }}
    </div>
  </div>
</template>
