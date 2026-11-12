<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from "vue";
import Artwork from "./Artwork.vue";
import Icon from "./Icon.vue";
import { duration, format, type Track } from "./types";

// 全窗口刷音乐：上下模式用滚轮 / 上下键 / 上下拖动，卡片模式叠放卡片，
// 右滑喜欢、左滑跳过、上下换歌。只负责手势与展示，播放状态仍归 useAwake。
const props = defineProps<{
  track: Track;
  nextTrack: Track | null;
  previousTrack: Track | null;
  position: number;
  total: number;
  playing: boolean;
  loading: boolean;
  favorite: boolean;
  index: number;
  totalTracks: number;
}>();

const emit = defineEmits<{
  close: [];
  next: [];
  previous: [];
  toggle: [];
  seek: [seconds: number];
  like: [track: Track];
  "toggle-favorite": [];
}>();

type Mode = "vertical" | "cards";
const MODE_KEY = "awake-swipe-mode";
const mode = ref<Mode>("vertical");
const reduced = ref(false);
const dragging = ref(false);
const busy = ref(false);
const flying = ref<"left" | "right" | "up" | "down" | null>(null);
const dx = ref(0);
const dy = ref(0);
const overlay = ref<HTMLElement | null>(null);
let startX = 0;
let startY = 0;
let pointerId = -1;
let wheelAt = 0;
let flyTimer: number | undefined;
let safetyTimer: number | undefined;
let media: MediaQueryList | undefined;

const horizontal = computed(() => Math.abs(dx.value) > Math.abs(dy.value));
const likeOn = computed(
  () =>
    flying.value === "right" ||
    (dragging.value && horizontal.value && dx.value > 30),
);
const skipOn = computed(
  () =>
    flying.value === "left" ||
    (dragging.value && horizontal.value && dx.value < -30),
);
const upOn = computed(
  () =>
    flying.value === "up" ||
    (dragging.value && !horizontal.value && dy.value < -24),
);
const downOn = computed(
  () =>
    flying.value === "down" ||
    (dragging.value && !horizontal.value && dy.value > 24),
);

const cardStyle = computed<Record<string, string>>(() => {
  if (flying.value === "left")
    return { transform: "translate3d(-70vw, 9vh, 0) rotate(-14deg)", opacity: "0" };
  if (flying.value === "right")
    return { transform: "translate3d(70vw, 9vh, 0) rotate(14deg)", opacity: "0" };
  if (flying.value === "up")
    return { transform: "translate3d(0, -60vh, 0) scale(.94)", opacity: "0" };
  if (flying.value === "down")
    return { transform: "translate3d(0, 60vh, 0) scale(.94)", opacity: "0" };
  const base: Record<string, string> = {};
  if (!dragging.value) return base;
  const rotate = Math.max(-14, Math.min(14, dx.value * 0.05));
  return {
    transform: `translate3d(${dx.value}px, ${dy.value}px, 0) rotate(${rotate}deg)`,
  };
});

function release() {
  busy.value = false;
  clearTimeout(safetyTimer);
}

function fire(modeName: "next" | "previous" | "like" | "skip") {
  if (busy.value) return;
  busy.value = true;
  clearTimeout(safetyTimer);
  safetyTimer = window.setTimeout(release, 900);
  if (mode.value === "cards") {
    flying.value =
      modeName === "like"
        ? "right"
        : modeName === "skip"
          ? "left"
          : modeName === "next"
            ? "up"
            : "down";
    clearTimeout(flyTimer);
    flyTimer = window.setTimeout(
      () => {
        const direction = flying.value;
        flying.value = null;
        if (direction === "right") emit("like", props.track);
        else if (direction === "left") emit("next");
        else if (direction === "up") emit("next");
        else emit("previous");
      },
      reduced.value ? 0 : 190,
    );
    return;
  }
  if (modeName === "next" || modeName === "like") emit("next");
  else emit("previous");
}

function onPointerDown(event: PointerEvent) {
  if (busy.value || event.button !== 0) return;
  const stage = event.currentTarget as HTMLElement;
  startX = event.clientX;
  startY = event.clientY;
  dx.value = 0;
  dy.value = 0;
  pointerId = event.pointerId;
  dragging.value = true;
  try {
    stage.setPointerCapture(event.pointerId);
  } catch {
    /* 某些触控设备不支持指针捕获，退化为普通拖动 */
  }
}

function onPointerMove(event: PointerEvent) {
  if (!dragging.value || event.pointerId !== pointerId) return;
  dx.value = event.clientX - startX;
  dy.value = event.clientY - startY;
}

function onPointerEnd(event: PointerEvent) {
  if (!dragging.value || event.pointerId !== pointerId) return;
  const stage = event.currentTarget as HTMLElement;
  try {
    stage.releasePointerCapture(event.pointerId);
  } catch {
    /* 已经释放的指针无需处理 */
  }
  dragging.value = false;
  const x = dx.value;
  const y = dy.value;
  const sideways = Math.abs(x) > Math.abs(y);
  dx.value = 0;
  dy.value = 0;
  if (mode.value === "cards" && sideways && Math.abs(x) > 92) {
    fire(x > 0 ? "like" : "skip");
    return;
  }
  if (!sideways && Math.abs(y) > 80) fire(y < 0 ? "next" : "previous");
}

function onWheel(event: WheelEvent) {
  if (busy.value || Math.abs(event.deltaY) < 6) return;
  if (Math.abs(event.deltaY) < Math.abs(event.deltaX)) return;
  const now = performance.now();
  if (now - wheelAt < 480) return;
  wheelAt = now;
  event.preventDefault();
  fire(event.deltaY > 0 ? "next" : "previous");
}

function onKeydown(event: KeyboardEvent) {
  const target = event.target as HTMLElement | null;
  if (
    target &&
    ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName)
  )
    return;
  if (event.key === "Escape") {
    event.preventDefault();
    emit("close");
    return;
  }
  if (event.key === "ArrowUp") {
    event.preventDefault();
    fire("previous");
    return;
  }
  if (event.key === "ArrowDown") {
    event.preventDefault();
    fire("next");
    return;
  }
  if (mode.value === "cards" && event.key === "ArrowRight") {
    event.preventDefault();
    fire("like");
    return;
  }
  if (mode.value === "cards" && event.key === "ArrowLeft") {
    event.preventDefault();
    fire("skip");
    return;
  }
  if (event.code === "Space" && target?.tagName !== "BUTTON") {
    event.preventDefault();
    emit("toggle");
  }
}

function setMode(next: Mode) {
  if (mode.value === next) return;
  mode.value = next;
  dragging.value = false;
  flying.value = null;
  dx.value = 0;
  dy.value = 0;
  try {
    localStorage.setItem(MODE_KEY, next);
  } catch {
    /* 隐私模式下无法写入，忽略即可 */
  }
}

function trapFocus(event: KeyboardEvent) {
  const nodes = Array.from(
    (event.currentTarget as HTMLElement).querySelectorAll<HTMLElement>(
      "button:not(:disabled),input:not(:disabled)",
    ),
  );
  const first = nodes[0];
  const last = nodes[nodes.length - 1];
  if (event.shiftKey && document.activeElement === first) {
    event.preventDefault();
    last?.focus();
  } else if (!event.shiftKey && document.activeElement === last) {
    event.preventDefault();
    first?.focus();
  }
}

function seekTo(event: Event) {
  const seconds = Number((event.target as HTMLInputElement).value);
  if (Number.isFinite(seconds)) emit("seek", seconds);
}

function onReducedChange(event: MediaQueryListEvent) {
  reduced.value = event.matches;
}

watch(
  () => props.track.id,
  () => {
    dx.value = 0;
    dy.value = 0;
    flying.value = null;
    clearTimeout(flyTimer);
    clearTimeout(safetyTimer);
    busy.value = false;
  },
);

onMounted(() => {
  try {
    mode.value = localStorage.getItem(MODE_KEY) === "cards" ? "cards" : "vertical";
  } catch {
    mode.value = "vertical";
  }
  if (typeof window.matchMedia === "function") {
    media = window.matchMedia("(prefers-reduced-motion: reduce)");
    reduced.value = media.matches;
    media.addEventListener("change", onReducedChange);
  }
  window.addEventListener("keydown", onKeydown);
  overlay.value?.focus();
});

onUnmounted(() => {
  window.removeEventListener("keydown", onKeydown);
  media?.removeEventListener("change", onReducedChange);
  clearTimeout(flyTimer);
  clearTimeout(safetyTimer);
});
</script>

<template>
  <div
    ref="overlay"
    class="swipe-overlay"
    :class="[`mode-${mode}`, { 'is-dragging': dragging, 'is-reduced': reduced }]"
    role="dialog"
    aria-modal="true"
    aria-label="刷音乐"
    tabindex="-1"
    @keydown.tab="trapFocus"
  >
    <header class="swipe-head">
      <div class="swipe-heading">
        <p class="eyebrow">SWIPE THROUGH YOUR SOUND</p>
        <h1>刷音乐<span class="serif">，让耳朵先决定。</span></h1>
      </div>
      <div class="swipe-head-actions">
        <div class="swipe-modes" role="group" aria-label="刷音乐模式">
          <button
            :class="{ active: mode === 'vertical' }"
            :aria-pressed="mode === 'vertical'"
            @click="setMode('vertical')"
          >
            上下模式
          </button>
          <button
            :class="{ active: mode === 'cards' }"
            :aria-pressed="mode === 'cards'"
            @click="setMode('cards')"
          >
            卡片模式
          </button>
        </div>
        <button
          class="icon-btn swipe-close"
          aria-label="退出刷音乐（Esc）"
          @click="emit('close')"
        >
          <Icon name="close" :size="20" />
        </button>
      </div>
    </header>

    <div class="swipe-body" @wheel="onWheel">
      <div
        class="swipe-stage"
        @pointerdown="onPointerDown"
        @pointermove="onPointerMove"
        @pointerup="onPointerEnd"
        @pointercancel="onPointerEnd"
        @dragstart.prevent
      >
        <div v-if="mode === 'cards'" class="swipe-ghost" aria-hidden="true">
          <Artwork
            v-if="nextTrack"
            :path="nextTrack.artwork_path"
            :seed="nextTrack.album || nextTrack.title"
            :style-name="nextTrack.media_info?.cover_style"
          />
          <div v-else class="swipe-ghost-empty">
            <Icon name="wave" :size="30" />
          </div>
          <span>{{ nextTrack?.title || "队列到这里了" }}</span>
        </div>

        <div
          class="swipe-card"
          :class="{ dragging: dragging, flying: !!flying }"
          :style="cardStyle"
        >
          <span class="swipe-marker like" :class="{ on: likeOn }">喜欢</span>
          <span class="swipe-marker skip" :class="{ on: skipOn }">跳过</span>
          <span class="swipe-marker up" :class="{ on: upOn }">下一首</span>
          <span class="swipe-marker down" :class="{ on: downOn }">上一首</span>

          <div :key="track.id" class="swipe-art">
            <Artwork
              :path="track.artwork_path"
              :seed="track.album || track.title"
              :style-name="track.media_info?.cover_style"
              large
            />
          </div>
          <div :key="track.id" class="swipe-meta">
            <p class="eyebrow">
              NOW SWIPING · {{ index + 1 }} / {{ totalTracks }}
            </p>
            <h2>{{ track.title }}</h2>
            <p>
              {{ track.artist || "未知艺人" }}<template v-if="track.album">
                · {{ track.album }}</template
              >
            </p>
            <small class="mono">{{ format(track) }}</small>
          </div>
        </div>
      </div>

      <div class="swipe-controls">
        <div class="timeline swipe-timeline">
          <span>{{ duration(position) }}</span>
          <input
            type="range"
            min="0"
            :max="total || track.duration || 0"
            :value="position"
            step="0.1"
            :disabled="loading || !total"
            aria-label="刷音乐里的播放进度"
            @change="seekTo"
          />
          <span>{{ duration(total || track.duration || 0) }}</span>
        </div>
        <div class="swipe-buttons">
          <button
            class="icon-btn"
            :disabled="!previousTrack"
            aria-label="上一首"
            @click="fire('previous')"
          >
            <Icon name="prev" :size="18" />
          </button>
          <button
            class="play-button"
            :disabled="loading"
            :aria-label="playing ? '暂停' : '播放'"
            @click="emit('toggle')"
          >
            <span v-if="loading" class="spinner" />
            <Icon v-else :name="playing ? 'pause' : 'play'" :size="20" />
          </button>
          <button
            class="icon-btn"
            :disabled="!nextTrack"
            aria-label="下一首"
            @click="fire('next')"
          >
            <Icon name="next" :size="18" />
          </button>
          <button
            class="icon-btn swipe-favorite"
            :class="{ loved: favorite }"
            :aria-label="favorite ? '取消收藏当前歌曲' : '收藏当前歌曲'"
            @click="emit('toggle-favorite')"
          >
            <Icon name="heart" :size="19" />
          </button>
        </div>
        <p class="swipe-hint">
          <template v-if="mode === 'vertical'">
            滚轮 / ↑↓ / 上下拖动切换歌曲 · Esc 退出
          </template>
          <template v-else>
            向右拖动喜欢 · 向左跳过 · 上下换歌 · Esc 退出
          </template>
        </p>
        <p class="sr-only" aria-live="polite">
          正在刷 {{ track.title }}，{{ track.artist }}
        </p>
      </div>
    </div>
  </div>
</template>
