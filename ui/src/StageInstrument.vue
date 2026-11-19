<script setup lang="ts">
import { computed } from "vue";
import type { Track } from "./types";
import {
  DEFAULT_GEOMETRY,
  EQ_FREQS,
  EQ_TICKS,
  curvePath,
  dbLabel,
  fillPath,
  freqLabel,
  isFlatCurve,
  normaliseGains,
  peakBand,
  xForFrequency,
  yForGain,
} from "./stageCurve";

const props = defineProps<{
  track: Track | null;
  gains: number[];
  sourceName: string;
}>();

const geometry = DEFAULT_GEOMETRY;
const W = geometry.width;
const H = geometry.height;
const INSET = geometry.inset;
const TICKS = EQ_TICKS;

const values = computed(() => normaliseGains(props.gains));
const peak = computed(() => peakBand(values.value));
const flat = computed(() => isFlatCurve(values.value));
const path = computed(() => curvePath(values.value, geometry));
const fill = computed(() => fillPath(values.value, geometry));
const x = (frequency: number) => xForFrequency(frequency, geometry);
const y = (gain: number) => yForGain(gain, geometry);

const codec = computed(() => {
  const t = props.track;
  if (!t) return "—";
  const parts = [t.codec || "音频"];
  if (t.bit_depth > 0) parts.push(`${t.bit_depth} bit`);
  if (t.sample_rate > 0) {
    const k = t.sample_rate / 1000;
    parts.push(`${Number.isInteger(k) ? k.toFixed(0) : k.toFixed(1)} kHz`);
  }
  if (t.channels > 0) parts.push(t.channels === 1 ? "单声道" : `${t.channels} 声道`);
  return parts.join(" / ");
});

const steps = computed(() => [
  { label: "音源", value: codec.value },
  { label: "EQ", value: flat.value ? "平直" : "31 段" },
  { label: "输出", value: "本机输出" },
]);

const peakLabel = computed(() =>
  flat.value ? "平直" : `${freqLabel(EQ_FREQS[peak.value.index])} ${dbLabel(peak.value.value)}`,
);
</script>

<template>
  <section class="stage-instrument">
    <div class="chain">
      <template v-for="(step, i) in steps" :key="step.label">
        <div class="chain-step">
          <span>{{ step.label }}</span>
          <strong>{{ step.value }}</strong>
        </div>
        <i v-if="i < steps.length - 1" class="chain-link" aria-hidden="true" />
      </template>
    </div>

    <div class="curve-head">
      <span>31 段曲线</span>
      <strong :class="{ flat }">{{ peakLabel }}</strong>
    </div>

    <svg class="curve" :viewBox="`0 0 ${W} ${H}`" role="img" aria-label="31 段均衡曲线">
      <line
        v-for="tick in TICKS"
        :key="`g${tick}`"
        :x1="x(tick)"
        :x2="x(tick)"
        :y1="INSET"
        :y2="H - 18"
        class="grid"
      />
      <line
        v-for="step in [-6, 0, 6]"
        :key="`h${step}`"
        :x1="INSET"
        :x2="W - INSET"
        :y1="y(step)"
        :y2="y(step)"
        :class="step === 0 ? 'zero' : 'grid dashed'"
      />
      <path :d="fill" class="fill" />
      <path :d="path" class="line" />
      <circle
        v-if="!flat"
        :cx="x(EQ_FREQS[peak.index])"
        :cy="y(peak.value)"
        r="2.6"
        class="marker"
      />
      <text
        v-for="tick in TICKS"
        :key="`t${tick}`"
        :x="x(tick)"
        :y="H - 4"
        class="axis"
        text-anchor="middle"
      >
        {{ freqLabel(tick) }}
      </text>
    </svg>

    <p class="curve-status">
      <span v-if="flat">当前输出按平直曲线播放 · 在「声音」里选择耳机与链路后这里会画出实际曲线</span>
      <span v-else>曲线为当前链路实际生效的 31 段增益</span>
      <span v-if="sourceName" class="curve-source">{{ sourceName }}</span>
    </p>
  </section>
</template>

<style scoped>
.stage-instrument {
  display: grid;
  gap: 12px;
}
.chain {
  display: flex;
  align-items: flex-start;
  gap: 10px;
  padding: 12px 0;
  border-bottom: 1px solid var(--line);
}
.chain-step {
  display: grid;
  gap: 4px;
  min-width: 0;
}
.chain-step span {
  font-size: 10px;
  color: var(--muted);
}
.chain-step strong {
  font-family: var(--mono, ui-monospace, SFMono-Regular, monospace);
  font-size: 12px;
  font-weight: 500;
  color: var(--text);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.chain-link {
  display: block;
  width: 10px;
  height: 1px;
  margin-top: 19px;
  background: var(--line);
  flex: 0 0 auto;
}
.curve-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  font-size: 12px;
}
.curve-head span {
  color: var(--muted);
}
.curve-head strong {
  font-family: var(--mono, ui-monospace, SFMono-Regular, monospace);
  font-weight: 500;
  color: var(--accent);
}
.curve-head strong.flat {
  color: var(--dim);
}
.curve {
  width: 100%;
  height: 152px;
  border: 1px solid var(--line);
  border-radius: 4px;
  background: color-mix(in srgb, var(--bg) 60%, transparent);
}
.grid {
  stroke: var(--line);
  stroke-width: 0.6;
}
.grid.dashed {
  stroke-dasharray: 2 3;
  opacity: 0.6;
}
.zero {
  stroke: var(--line);
  stroke-width: 0.8;
}
.fill {
  fill: color-mix(in srgb, var(--accent) 12%, transparent);
}
.line {
  fill: none;
  stroke: var(--accent);
  stroke-width: 1.5;
  stroke-linejoin: round;
}
.marker {
  fill: var(--accent);
}
.axis {
  fill: var(--dim);
  font-family: var(--mono, ui-monospace, SFMono-Regular, monospace);
  font-size: 8px;
}
.curve-status {
  display: flex;
  justify-content: space-between;
  gap: 16px;
  font-size: 11px;
  color: var(--dim);
  margin: 0;
}
.curve-source {
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
</style>
