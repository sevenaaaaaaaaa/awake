<script setup lang="ts">
import { computed } from "vue";
import Icon from "./Icon.vue";
import type { WeeklySummary } from "./types";

const props = defineProps<{ summary: WeeklySummary | null; loading: boolean }>();
const emit = defineEmits<{ play: [string]; refresh: [] }>();

const labels = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"];
const maxSeconds = computed(() =>
  // 至少按 10 分钟定标，避免只听了 1 秒就把柱子顶满。
  Math.max(600, ...(props.summary?.days.map((day) => day.seconds) ?? [0])),
);
const minutes = computed(() =>
  props.summary ? Math.round(props.summary.seconds / 60) : 0,
);
const hours = computed(() => {
  const value = minutes.value;
  return value >= 60 ? Math.floor(value / 60) + " 小时 " + (value % 60) + " 分" : value + " 分钟";
});
const dayHeight = (seconds: number) =>
  seconds <= 0 ? 0 : Math.max(1, Math.round((seconds / maxSeconds.value) * 100));
const dayLabel = (seconds: number) =>
  seconds < 60 ? (seconds > 0 ? Math.round(seconds) + "″" : "—") : Math.round(seconds / 60) + "′";
</script>

<template>
  <div v-if="loading" class="empty-state">
    <span class="spinner" /><p>正在整理这周的聆听…</p>
  </div>
  <template v-else-if="summary">
    <div class="week-stats">
      <article class="week-stat">
        <span class="eyebrow">LISTENING TIME</span>
        <strong>{{ hours }}</strong>
        <small>比任何数字都更接近这一周的心情</small>
      </article>
      <article class="week-stat">
        <span class="eyebrow">FULL PLAYS</span>
        <strong>{{ summary.plays }}</strong>
        <small>完整听完的曲目</small>
      </article>
      <article class="week-stat">
        <span class="eyebrow">ARTISTS</span>
        <strong>{{ summary.artist_count }}</strong>
        <small>不同的声音陪你走过</small>
      </article>
      <article class="week-stat">
        <span class="eyebrow">NEW IN LIBRARY</span>
        <strong>{{ summary.new_tracks }}</strong>
        <small>本周新加入的曲目</small>
      </article>
    </div>

    <section class="eq-card week-chart">
      <div class="section-heading">
        <div>
          <h2>这一周的声场</h2>
          <p>按天统计实际播放时长；跳过与未播放不计入。</p>
        </div>
        <button class="text-button" @click="emit('refresh')">
          刷新 <Icon name="refresh" />
        </button>
      </div>
      <div class="week-bars" aria-hidden="true">
        <div v-for="(day, index) in summary.days" :key="index" class="week-bar">
          <span class="week-bar-value">{{ dayLabel(day.seconds) }}</span>
          <div class="week-bar-track">
            <span :style="{ height: dayHeight(day.seconds) + '%' }" />
          </div>
          <small>{{ labels[index] }}</small>
        </div>
      </div>
    </section>

    <div class="week-columns">
      <section class="eq-card">
        <div class="section-heading">
          <div><h2>反复心动</h2><p>播放次数最多的五首。</p></div>
        </div>
        <button
          v-for="(track, index) in summary.top_tracks"
          :key="track.id"
          class="week-track"
          @click="emit('play', track.id)"
        >
          <span class="week-rank">{{ String(index + 1).padStart(2, "0") }}</span>
          <span class="week-track-copy">
            <strong>{{ track.title }}</strong>
            <small>{{ track.artist || "未知艺人" }}</small>
          </span>
          <span class="muted">{{ track.plays }} 次</span>
          <Icon name="play" :size="14" />
        </button>
        <p v-if="!summary.top_tracks.length" class="list-empty">
          这周还没有完整的播放记录。
        </p>
      </section>
      <section class="eq-card">
        <div class="section-heading">
          <div><h2>声音的主人</h2><p>按聆听时长排序。</p></div>
        </div>
        <div v-for="artist in summary.top_artists" :key="artist.artist" class="week-artist">
          <span>{{ artist.artist }}</span>
          <div class="progress-track" aria-hidden="true">
            <span
              :style="{
                width:
                  Math.max(
                    4,
                    Math.round(
                      (artist.seconds /
                        Math.max(1, summary.top_artists[0]?.seconds || 1)) *
                        100,
                    ),
                  ) + '%',
              }"
            />
          </div>
          <small class="muted">{{ Math.round(artist.seconds / 60) }} 分钟</small>
        </div>
        <p v-if="!summary.top_artists.length" class="list-empty">
          多听几首，这里会出现你偏爱的声音。
        </p>
      </section>
    </div>

    <section class="info-panel week-notes">
      <Icon name="spark" :size="24" />
      <div>
        <h3>这一周，我听见的你</h3>
        <p v-for="(line, index) in summary.lines" :key="index">{{ line }}</p>
        <p class="muted">
          统计来自本机收听记录（{{ new Date(summary.since).toLocaleDateString("zh-CN") }} –
          {{ new Date(summary.until - 1).toLocaleDateString("zh-CN") }}），不会上传。
        </p>
      </div>
    </section>
  </template>
  <div v-else class="empty-state">
    <Icon name="chart" :size="40" />
    <h2>统计需要桌面版。</h2>
    <p>在 Awake 桌面应用里，本周的每一次聆听都会汇总在这里。</p>
  </div>
</template>
