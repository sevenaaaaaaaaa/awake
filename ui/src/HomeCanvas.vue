<script setup lang="ts">
/**
 * 画布式首页：版面由 composeHome() 按库状态算，不是编辑写死的。
 * 这里只负责画和转发点击，取舍规则全在 homeLayout.ts（有单测）。
 */
import { computed } from "vue";
import { composeHome, type TileKind } from "./homeLayout";

const props = defineProps<{
  trackCount: number;
  continueAt: { title: string; remainingSec: number } | null;
  pendingAdapt: number;
  today: string | null;
  shelves: { classical: number; light: number; live: number };
  stationCount: number;
  hasCalibration: boolean;
}>();

const emit = defineEmits<{ go: [kind: TileKind] }>();

const tiles = computed(() =>
  composeHome({
    trackCount: props.trackCount,
    continueAt: props.continueAt,
    pendingAdapt: props.pendingAdapt,
    today: props.today,
    shelves: props.shelves,
    stationCount: props.stationCount,
    hasCalibration: props.hasCalibration,
  }),
);
</script>

<template>
  <section class="canvas" aria-label="今日版面">
    <div class="canvas-head">
      <h2>今天，<span class="serif">从哪儿开始。</span></h2>
      <small>版面按你的库算出来，不是手动摆的</small>
    </div>
    <div class="canvas-grid">
      <button
        v-for="tile in tiles"
        :key="tile.kind + tile.title"
        type="button"
        class="tile"
        @click="emit('go', tile.kind)"
      >
        <span class="tile-title">{{ tile.title }}</span>
        <span class="tile-sub">{{ tile.subtitle }}</span>
        <span class="tile-why">{{ tile.reason }}</span>
      </button>
    </div>
  </section>
</template>

<style scoped>
.canvas {
  display: grid;
  gap: 12px;
  margin-bottom: 28px;
}
.canvas-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 12px;
}
.canvas-head h2 {
  margin: 0;
  font-size: 20px;
  font-weight: 600;
}
.canvas-head small {
  color: var(--text-muted);
}
.canvas-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 12px;
}
@media (max-width: 767px) {
  .canvas-grid {
    grid-template-columns: 1fr;
  }
}
.tile {
  display: grid;
  gap: 6px;
  padding: 16px;
  text-align: left;
  border: 1px solid var(--line);
  border-radius: 12px;
  background: var(--surface);
  color: var(--text);
  cursor: pointer;
  transition:
    border-color 180ms ease,
    transform 180ms ease;
}
.tile:hover {
  border-color: var(--accent);
}
.tile:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
}
.tile:active {
  transform: translateY(1px);
}
.tile-title {
  font-size: 15px;
  font-weight: 600;
}
.tile-sub {
  font-size: 13px;
  color: var(--text-dim);
}
.tile-why {
  font-size: 12px;
  color: var(--text-muted);
}
</style>
