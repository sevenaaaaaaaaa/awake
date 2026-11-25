<script setup lang="ts">
/**
 * 电台解码设置：只有一个开关——"用 ffmpeg 兜底"。
 *
 * 默认关：兜底会引入外部二进制与首播延迟，只在用户明确需要时付这个代价。
 * 判定逻辑在 Rust（awake_core::radio::plan），这里只显示与写入开关。
 */
import { onMounted, ref } from "vue";
import { call, desktop } from "./bridge";

interface RadioSettingsView {
  ffmpeg_fallback: boolean;
  ffmpeg_path: string;
  needs_ffmpeg_for: string[];
}

const view = ref<RadioSettingsView | null>(null);
const busy = ref(false);
const error = ref("");

async function load() {
  if (!desktop) return;
  try {
    view.value = await call<RadioSettingsView>("get_radio_settings");
  } catch (issue) {
    error.value = String(issue);
  }
}

async function toggle() {
  if (!view.value || busy.value) return;
  busy.value = true;
  error.value = "";
  const next = !view.value.ffmpeg_fallback;
  try {
    view.value = await call<RadioSettingsView>("set_ffmpeg_fallback", { enabled: next });
  } catch (issue) {
    error.value = String(issue);
  } finally {
    busy.value = false;
  }
}

onMounted(load);
</script>

<template>
  <article class="source-card radio-settings">
    <span class="source-icon"><Icon name="sliders" :size="26" /></span>
    <div class="body">
      <span class="subtle-badge">电台解码</span>
      <h2>用 ffmpeg 兜底</h2>
      <p class="lead">
        有些台用的是解码器覆盖不到的编码（今天只有 Opus）。打开这个开关后，这类台会改由 ffmpeg 解码，
        代价是首播会多等一会儿，而且本机必须装了 ffmpeg。
      </p>

      <p v-if="!desktop" class="hint">这条只在桌面版可用。</p>
      <p v-if="error" class="job-error">{{ error }}</p>

      <button
        v-if="desktop && view"
        type="button"
        class="switch"
        :class="{ on: view.ffmpeg_fallback }"
        :aria-pressed="view.ffmpeg_fallback"
        :disabled="busy"
        @click="toggle"
      >
        <span class="knob" />
        <span class="label">{{ view.ffmpeg_fallback ? "已打开" : "已关闭" }}</span>
      </button>

      <p v-if="view" class="hint">
        <template v-if="view.ffmpeg_path">
          ffmpeg：<code>{{ view.ffmpeg_path }}</code>
        </template>
        <template v-else>
          没找到 ffmpeg——打开开关也放不了，先 <code>brew install ffmpeg</code>。
        </template>
      </p>
      <p v-if="view && view.needs_ffmpeg_for.length" class="hint">
        需要它的编码：<code>{{ view.needs_ffmpeg_for.join(" / ") }}</code>
      </p>
    </div>
  </article>
</template>

<style scoped>
.radio-settings .body {
  display: grid;
  gap: 10px;
}
.radio-settings h2 {
  margin: 0;
  font-size: 17px;
}
.lead,
.hint {
  margin: 0;
  color: var(--text-dim);
  font-size: 13px;
  line-height: 1.6;
}
.switch {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  justify-self: start;
  padding: 6px 12px 6px 6px;
  border: 1px solid var(--line);
  border-radius: 999px;
  background: var(--surface);
  color: var(--text);
  cursor: pointer;
}
.switch:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
}
.switch:disabled {
  opacity: 0.6;
  cursor: wait;
}
.knob {
  width: 34px;
  height: 18px;
  border-radius: 999px;
  background: var(--line);
  position: relative;
  transition: background 180ms ease;
}
.knob::after {
  content: "";
  position: absolute;
  top: 2px;
  left: 2px;
  width: 14px;
  height: 14px;
  border-radius: 50%;
  background: var(--surface);
  transition: transform 180ms ease;
}
.switch.on .knob {
  background: var(--accent);
}
.switch.on .knob::after {
  transform: translateX(16px);
}
.label {
  font-size: 13px;
}
code {
  font-family: var(--mono);
  font-size: 12px;
}
</style>
