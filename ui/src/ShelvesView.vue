<script setup lang="ts">
/**
 * 专架页：古典 / 轻音乐 / 现场。
 * 每一条都带"凭什么进来的"——分类错了要能一眼看出来是哪个信号错了。
 */
import { computed } from "vue";
import { shelfLine, type ShelfGroup } from "./insight";
import type { Track } from "./types";

const props = defineProps<{ groups: ShelfGroup[]; tracks: Track[] }>();
const emit = defineEmits<{ play: [id: string] }>();

const byId = computed(() => {
  const map = new Map<string, Track>();
  for (const track of props.tracks) map.set(track.id, track);
  return map;
});

function preview(group: ShelfGroup): Track[] {
  return group.track_ids
    .slice(0, 6)
    .map((id) => byId.value.get(id))
    .filter((track): track is Track => Boolean(track));
}
</script>

<template>
  <div class="page-intro">
    <div>
      <p class="eyebrow">SHELVES</p>
      <h1>不一样的音乐，<span class="serif">放不一样的架子。</span></h1>
      <p>古典按作品与乐章排，轻音乐按场景排，现场单列——三种默认 EQ 也不同。</p>
    </div>
  </div>

  <div v-if="!groups.length" class="shelf-empty">
    <strong>还没有够数的专架</strong>
    <p>
      一个专架至少要 8 首才成立。古典需要「流派标签」与「作品号 Op./BWV/K.」两个信号同时成立，
      所以有些古典曲目暂时不会出现在这里——宁可少分，也不错分。
    </p>
  </div>

  <section v-for="group in groups" :key="group.key" class="shelf-card">
    <header>
      <h2>{{ group.label }}</h2>
      <small>{{ shelfLine(group) }}</small>
    </header>
    <div v-if="group.works?.length" class="works">
      <span class="works-head">按作品浏览（作曲家来自标签，不进曲库 schema）</span>
      <ul>
        <li v-for="work in group.works" :key="work.composer + work.work + work.catalogue">
          <button
            type="button"
            class="work-row"
            :disabled="!work.track_ids.length"
            @click="work.track_ids[0] && emit('play', work.track_ids[0])"
          >
            <span class="work-name">{{ work.composer }} · {{ work.work }}</span>
            <span class="work-meta">
              {{ work.catalogue || "无作品号" }} · {{ work.movement_count }} 段
            </span>
          </button>
        </li>
      </ul>
    </div>
    <ul>
      <li v-for="track in preview(group)" :key="track.id">
        <button type="button" class="shelf-track" @click="emit('play', track.id)">
          <span class="name">{{ track.title }}</span>
          <span class="meta">{{ track.artist }} · {{ track.album }}</span>
        </button>
      </li>
    </ul>
    <small v-if="group.count > preview(group).length" class="more"
      >还有 {{ group.count - preview(group).length }} 首</small
    >
  </section>
</template>

<style scoped>
.shelf-card {
  border: 1px solid var(--line);
  border-radius: 12px;
  background: var(--surface);
  padding: 16px;
  margin-bottom: 12px;
}
.shelf-card header {
  display: grid;
  gap: 4px;
  margin-bottom: 10px;
}
.shelf-card h2 {
  margin: 0;
  font-size: 17px;
}
.shelf-card small {
  color: var(--text-muted);
}
.shelf-card ul {
  list-style: none;
  margin: 0;
  padding: 0;
  display: grid;
  gap: 2px;
}
.shelf-track {
  display: flex;
  justify-content: space-between;
  gap: 12px;
  width: 100%;
  padding: 8px 10px;
  border: 0;
  border-radius: 8px;
  background: transparent;
  color: var(--text);
  text-align: left;
  cursor: pointer;
}
.shelf-track:hover {
  background: var(--raised);
}
.shelf-track:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 1px;
}
.shelf-track .meta {
  color: var(--text-muted);
  font-size: 12px;
}
.shelf-empty {
  border: 1px dashed var(--line);
  border-radius: 12px;
  padding: 20px;
  color: var(--text-dim);
}
.shelf-empty strong {
  color: var(--text);
}
.works {
  display: grid;
  gap: 6px;
  margin-bottom: 12px;
  padding-bottom: 10px;
  border-bottom: 1px solid var(--line);
}
.works-head {
  color: var(--text-muted);
  font-size: 12px;
}
.works ul {
  list-style: none;
  margin: 0;
  padding: 0;
  display: grid;
  gap: 2px;
}
.work-row {
  display: flex;
  justify-content: space-between;
  gap: 12px;
  width: 100%;
  padding: 8px 10px;
  border: 0;
  border-radius: 8px;
  background: var(--raised);
  color: var(--text);
  text-align: left;
  cursor: pointer;
}
.work-row:hover:not(:disabled) {
  outline: 1px solid var(--accent);
}
.work-row:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 1px;
}
.work-row:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}
.work-meta {
  color: var(--text-muted);
  font-size: 12px;
}
.more {
  display: block;
  margin-top: 8px;
}
</style>
