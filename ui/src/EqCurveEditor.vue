<script setup lang="ts">
import { computed, onBeforeUnmount, ref } from "vue";
import { bandFromRatio, gainFromRatio, paintIndices, withGains } from "./eqInteraction";

/**
 * 31 段均衡曲线编辑器。
 *
 * 桌面端原来的做法是 31 根细滑块 + 一张只读折线：想改哪一段得先找到那根条，
 * 曲线也不会跟着手指走。这里改成直接拖曲线：
 *
 * - 按住拖动：改离指针最近的那一段
 * - 按住 Shift 拖动：把经过的频段一起改（涂改整条曲线）
 * - 双击：该段复位到 0 dB
 * - 滚轮：在选中的频段上微调（0.1 dB）
 * - 键盘：← → 选频段，↑ ↓ 步进 0.5 dB，Delete 复位
 *
 * 拖动过程中按节流调用 apply()，让声音跟着手走，而不是松手才生效。
 */
const props = defineProps<{
  gains: number[];
  frequencies: readonly number[];
  disabled?: boolean;
}>();

const emit = defineEmits<{
  (e: "update:gains", value: number[]): void;
  (e: "apply"): void;
}>();

const VIEW_W = 600;
const VIEW_H = 160;
const MID = VIEW_H / 2;
const PX_PER_DB = 4; // 1 dB = 4 px，与旧图一致
const RANGE = 12;

const svg = ref<SVGSVGElement | null>(null);
const selected = ref<number | null>(null);
const dragging = ref<null | "single" | "paint">(null);
const hovered = ref<number | null>(null);

let lastApply = 0;
let applyTimer: number | undefined;

const values = computed<number[]>(() =>
  Array.from({ length: props.frequencies.length }, (_, i) => {
    const v = Number(props.gains?.[i]);
    return Number.isFinite(v) ? Math.max(-RANGE, Math.min(RANGE, v)) : 0;
  }),
);

const points = computed(() =>
  values.value
    .map((v, i) => {
      const x = (i / (props.frequencies.length - 1)) * VIEW_W;
      return `${x.toFixed(1)},${(MID - v * PX_PER_DB).toFixed(1)}`;
    })
    .join(" "),
);

const fillPoints = computed(
  () => `0,${MID} ${points.value} ${VIEW_W},${MID}`,
);

function x(index: number) {
  return (index / (props.frequencies.length - 1)) * VIEW_W;
}

function freqLabel(f: number) {
  return f >= 1000 ? `${f / 1000}k` : String(f);
}

const active = computed(() => hovered.value ?? selected.value);

const readout = computed(() => {
  const index = active.value;
  if (index === null) return "";
  const v = values.value[index];
  return `${freqLabel(props.frequencies[index])} Hz · ${v >= 0 ? "+" : ""}${v.toFixed(1)} dB`;
});

// —— 指针 ——

function locate(event: PointerEvent) {
  const element = svg.value;
  if (!element) return { index: 0, gain: 0 };
  const rect = element.getBoundingClientRect();
  const ratioX = (event.clientX - rect.left) / Math.max(1, rect.width);
  const ratioY = (event.clientY - rect.top) / Math.max(1, rect.height);
  return {
    index: bandFromRatio(ratioX, props.frequencies.length),
    gain: gainFromRatio(ratioY),
  };
}

function commit(next: number[]) {
  emit("update:gains", next);
  const now = performance.now();
  // 拖动中每 80 ms 生效一次，松手立即生效：既跟手又不会把后端打满。
  if (now - lastApply > 80) {
    lastApply = now;
    emit("apply");
  } else {
    window.clearTimeout(applyTimer);
    applyTimer = window.setTimeout(() => emit("apply"), 90);
  }
}

function onPointerDown(event: PointerEvent) {
  if (props.disabled) return;
  event.preventDefault();
  const { index, gain } = locate(event);
  selected.value = index;
  dragging.value = event.shiftKey ? "paint" : "single";
  (event.target as Element).setPointerCapture?.(event.pointerId);
  const next = values.value.slice();
  next[index] = event.shiftKey ? gain : next[index];
  commit(next);
}

function onPointerMove(event: PointerEvent) {
  if (props.disabled) return;
  const { index, gain } = locate(event);
  hovered.value = index;
  if (!dragging.value) return;
  const base = values.value.slice();
  const next =
    dragging.value === "single"
      ? withGains(base, [index], gain)
      : withGains(base, paintIndices(selected.value ?? index, index), gain);
  selected.value = index;
  commit(next);
}

function endDrag() {
  if (!dragging.value) return;
  dragging.value = null;
  emit("apply");
}

function onDoubleClick(event: MouseEvent | PointerEvent) {
  if (props.disabled) return;
  const element = svg.value;
  if (!element) return;
  const rect = element.getBoundingClientRect();
  const ratioX = (event.clientX - rect.left) / Math.max(1, rect.width);
  const index = bandFromRatio(ratioX, props.frequencies.length);
  const next = values.value.slice();
  next[index] = 0;
  selected.value = index;
  commit(next);
  emit("apply");
}

function onWheel(event: WheelEvent) {
  if (props.disabled) return;
  const index = selected.value ?? props.frequencies.length >> 1;
  event.preventDefault();
  const next = values.value.slice();
  const delta = event.deltaY > 0 ? -0.1 : 0.1;
  next[index] = Math.max(-RANGE, Math.min(RANGE, Math.round((next[index] + delta) * 10) / 10));
  selected.value = index;
  commit(next);
}

function onKeydown(event: KeyboardEvent) {
  if (props.disabled) return;
  const count = props.frequencies.length;
  const current = selected.value ?? Math.floor(count / 2);
  const next = values.value.slice();
  let changed = false;
  if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
    const step = event.key === "ArrowLeft" ? -1 : 1;
    selected.value = Math.max(0, Math.min(count - 1, current + step));
    event.preventDefault();
    return;
  }
  if (event.key === "ArrowUp" || event.key === "ArrowDown") {
    const step = (event.key === "ArrowUp" ? 1 : -1) * (event.shiftKey ? 0.1 : 0.5);
    next[current] = Math.max(-RANGE, Math.min(RANGE, Math.round((next[current] + step) * 10) / 10));
    selected.value = current;
    changed = true;
  }
  if (event.key === "Delete" || event.key === "Backspace") {
    next[current] = 0;
    selected.value = current;
    changed = true;
  }
  if (changed) {
    event.preventDefault();
    commit(next);
    emit("apply");
  }
}

onBeforeUnmount(() => window.clearTimeout(applyTimer));
</script>

<template>
  <div class="eq-editor" :class="{ disabled }">
    <div class="eq-editor-head">
      <span class="eq-editor-hint">
        拖动改这一段 · Shift 拖动涂改 · 双击复位 · 滚轮微调
      </span>
      <span class="eq-editor-readout">{{ readout || "选中一段开始调整" }}</span>
    </div>
    <svg
      ref="svg"
      class="eq-editor-canvas"
      :viewBox="`0 0 ${VIEW_W} ${VIEW_H}`"
      preserveAspectRatio="none"
      tabindex="0"
      role="application"
      :aria-label="`31 段均衡曲线，当前 ${readout || '未选中'}`"
      @pointerdown="onPointerDown"
      @pointermove="onPointerMove"
      @pointerup="endDrag"
      @pointercancel="endDrag"
      @pointerleave="endDrag"
      @dblclick="onDoubleClick"
      @wheel.prevent="onWheel"
      @keydown="onKeydown"
      @blur="selected = null"
    >
      <line v-for="step in [0, 40, 120]" :key="step" :x1="0" :x2="VIEW_W" :y1="step" :y2="step" class="grid" />
      <line :x1="0" :x2="VIEW_W" :y1="MID" :y2="MID" class="zero" />
      <polygon :points="fillPoints" class="fill" />
      <polyline :points="points" class="line" vector-effect="non-scaling-stroke" />
      <line
        v-if="active !== null"
        :x1="x(active)"
        :x2="x(active)"
        :y1="0"
        :y2="VIEW_H"
        class="cursor"
        vector-effect="non-scaling-stroke"
      />
    </svg>
    <div class="eq-editor-axis">
      <span v-for="f in frequencies" :key="f">{{ freqLabel(f) }}</span>
    </div>
  </div>
</template>

<style scoped>
.eq-editor {
  display: grid;
  gap: 8px;
}
.eq-editor.disabled {
  opacity: 0.5;
  pointer-events: none;
}
.eq-editor-head {
  display: flex;
  justify-content: space-between;
  gap: 16px;
  font-size: 11px;
  color: var(--dim);
}
.eq-editor-readout {
  font-family: var(--mono);
  color: var(--accent);
  white-space: nowrap;
}
.eq-editor-canvas {
  width: 100%;
  height: 180px;
  display: block;
  border: 1px solid var(--line);
  border-radius: 6px;
  background: color-mix(in srgb, var(--bg) 55%, transparent);
  cursor: crosshair;
  touch-action: none;
  outline: none;
}
.eq-editor-canvas:focus-visible {
  border-color: color-mix(in srgb, var(--accent) 60%, transparent);
}
.grid {
  stroke: var(--line);
  stroke-width: 1;
}
.zero {
  stroke: var(--line);
  stroke-width: 1.4;
}
.fill {
  fill: color-mix(in srgb, var(--accent) 10%, transparent);
}
.line {
  fill: none;
  stroke: var(--accent);
  stroke-width: 1.8;
  stroke-linejoin: round;
}
.cursor {
  stroke: color-mix(in srgb, var(--accent) 45%, transparent);
  stroke-width: 1;
  stroke-dasharray: 3 4;
}
.eq-editor-axis {
  display: flex;
  justify-content: space-between;
  font-family: var(--mono);
  font-size: 9px;
  color: var(--dim);
}
.eq-editor-axis span {
  writing-mode: horizontal-tb;
}
</style>
