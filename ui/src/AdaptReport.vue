<script setup lang="ts">
/**
 * 报告卡：入库之后"还剩什么没做"。
 *
 * 这里一个"已自动适配 380 首"都不会出现——除非真的跑过分析。
 * 只报三件能核对的事：多少首没有曲线、分成几批、被什么卡住。
 */
import { computed } from "vue";
import { insightSummary, type AdaptQueue } from "./insight";

const props = defineProps<{ queue: AdaptQueue | null }>();
const emit = defineEmits<{ play: [id: string]; calibrate: [] }>();

const summary = computed(() => insightSummary(props.queue));
const batches = computed(() => props.queue?.batches ?? []);
</script>

<template>
  <div class="page-intro">
    <div>
      <p class="eyebrow">ADAPTATION</p>
      <h1>入库之后，<span class="serif">谁还没定曲线。</span></h1>
      <p>{{ summary }}</p>
    </div>
    <button
      v-if="props.queue?.blocked_by_reference && props.queue.queued > 0"
      class="button"
      @click="emit('calibrate')"
    >
      先做 3 分钟校准
    </button>
  </div>

  <div v-if="!batches.length" class="adapt-empty">
    <strong>没有待适配的曲目</strong>
    <p>新入库的曲子会在这里按「专架 + 风格」分组，一批只问你一次，不逐首弹。</p>
  </div>

  <ul v-else class="adapt-list">
    <li v-for="batch in batches" :key="batch.key">
      <div class="row">
        <span class="label">{{ batch.label }}</span>
        <span class="count">{{ batch.count }} 首</span>
      </div>
      <p class="reason">{{ batch.reason }}</p>
      <button
        type="button"
        class="preview"
        :disabled="!batch.track_ids.length"
        @click="batch.track_ids[0] && emit('play', batch.track_ids[0])"
      >
        先听一首
      </button>
    </li>
  </ul>

  <p class="foot">
    报告卡不写"已适配多少"——那是跑完分析才有的数字。没跑过就只报欠账。
  </p>
</template>

<style scoped>
.adapt-list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: grid;
  gap: 10px;
}
.adapt-list li {
  border: 1px solid var(--line);
  border-radius: 12px;
  background: var(--surface);
  padding: 14px 16px;
}
.row {
  display: flex;
  justify-content: space-between;
  gap: 12px;
}
.label {
  font-weight: 600;
}
.count {
  color: var(--text-muted);
}
.reason {
  margin: 6px 0 10px;
  color: var(--text-dim);
  font-size: 13px;
}
.preview {
  padding: 6px 12px;
  border: 1px solid var(--line);
  border-radius: 999px;
  background: transparent;
  color: var(--text);
  cursor: pointer;
}
.preview:hover:not(:disabled) {
  border-color: var(--accent);
}
.preview:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
}
.preview:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}
.adapt-empty {
  border: 1px dashed var(--line);
  border-radius: 12px;
  padding: 20px;
  color: var(--text-dim);
}
.adapt-empty strong {
  color: var(--text);
}
.foot {
  margin-top: 16px;
  color: var(--text-muted);
  font-size: 12px;
}
</style>
