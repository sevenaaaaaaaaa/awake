<script setup lang="ts">
/**
 * S1-c：这首歌的依据。
 *
 * 只做三件事：
 * 1. 把「耳机 / 曲目 / 先验」三段照实写出来，缺哪段写「未记录」；
 * 2. 依据失效时说清是哪副耳机记的、现在用的是哪副；
 * 3. 把导入时没对上的曲线摆出来，让用户点一首接上——同名与「找不到」分开写。
 *
 * 这里不解释「这条曲线好不好」，只解释「它凭什么成立」。
 */
import { computed } from "vue";
import type { Track } from "./types";
import type { CurveResolution, PendingCurve } from "./curve";

const props = defineProps<{
  curve: CurveResolution | null;
  pending: PendingCurve[];
  desktop: boolean;
  playing: Track | null;
}>();
const emit = defineEmits<{
  remember: [];
  forget: [];
  assign: [iosId: string, trackId: string];
  drop: [iosId: string];
}>();

const basisRows = computed(() => {
  const basis = props.curve?.basis;
  if (!basis) return [];
  return [
    { key: "耳机", value: basis.headphone || "未记录" },
    { key: "曲目", value: basis.track || "未记录" },
    { key: "先验", value: basis.prior || "未记录" },
  ];
});
const hasMemory = computed(() => props.curve?.source === "song");
const label = (item: { title: string; artist: string }) =>
  item.artist ? item.title + " · " + item.artist : item.title;
</script>

<template>
  <section v-if="desktop" class="basis-card">
    <div class="section-heading">
      <div>
        <h2>这首歌的依据</h2>
        <p class="muted">
          依据记的是「按下记住那一刻」的前提，不是实时状态。换耳机、换前端之后要重记一次。
        </p>
      </div>
    </div>

    <p v-if="!playing" class="muted">先播放一首歌，这里会写清它凭什么被这样调。</p>

    <template v-else>
      <div class="basis-state">
        <span class="tag" :class="{ plain: !hasMemory }">
          {{ hasMemory ? "按歌记忆" : "链路曲线" }}
        </span>
        <span class="muted">{{ playing.title }}</span>
      </div>

      <dl v-if="basisRows.length" class="basis-grid">
        <template v-for="row in basisRows" :key="row.key">
          <dt>{{ row.key }}</dt>
          <dd>{{ row.value }}</dd>
        </template>
      </dl>
      <p v-else class="muted">
        这条曲线没有记下依据（早期版本记的），只有曲线本身。
      </p>

      <p v-if="curve?.basis_stale" class="basis-warn">
        {{ curve.stale_hint || "依据里记的耳机和现在这副对不上" }}。
        这条依据已经不成立：声音会偏，建议按现在这副重调一次再记住。
      </p>

      <p v-if="curve?.prior_applied" class="muted">
        已叠加 {{ curve.prior_display }}：基础曲线 + 先验，逐段限幅 ±12 dB。
      </p>

      <div class="basis-actions">
        <button class="button primary" @click="emit('remember')">
          {{ hasMemory ? "用当前曲线更新记忆" : "记住这首歌" }}
        </button>
        <button v-if="hasMemory" class="button" @click="emit('forget')">
          忘掉这首歌
        </button>
      </div>
    </template>

    <div v-if="pending.length" class="pending-block">
      <h3>还有 {{ pending.length }} 首要指定</h3>
      <p class="muted">
        档案里有这些曲线，但曲库里对不上。点一首把它接上；接上之后再放这首歌，记忆就在了。
      </p>
      <div v-for="item in pending" :key="item.ios_id" class="pending-item">
        <div class="pending-head">
          <strong>{{ item.title || "（档案里没有曲名）" }}</strong>
          <span class="pending-reason">{{ item.reason }}</span>
        </div>
        <div v-if="item.candidates.length" class="pending-candidates">
          <button
            v-for="candidate in item.candidates"
            :key="candidate.id"
            class="text-button"
            @click="emit('assign', item.ios_id, candidate.id)"
          >
            {{ label(candidate) }}
          </button>
        </div>
        <p v-else class="muted">
          曲库里没有相近的曲目：先在桌面导入这首歌，再回到这里指定。
        </p>
        <button class="text-button drop" @click="emit('drop', item.ios_id)">
          这首不要了
        </button>
      </div>
    </div>
  </section>
</template>

<style scoped>
.basis-card {
  border: 1px solid var(--line);
  border-radius: 14px;
  background: var(--surface);
  padding: 4px 18px 18px;
  margin-top: 18px;
}
.basis-state {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-bottom: 12px;
}
.tag {
  font-size: 10px;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--on-accent);
  background: var(--accent);
  border-radius: 999px;
  padding: 3px 9px;
}
.tag.plain {
  color: var(--muted);
  background: transparent;
  border: 1px solid var(--line);
}
.basis-grid {
  display: grid;
  grid-template-columns: 56px 1fr;
  gap: 8px 14px;
  margin: 0 0 14px;
  font-size: 12px;
}
.basis-grid dt {
  color: var(--dim);
}
.basis-grid dd {
  margin: 0;
  color: var(--text);
  line-height: 1.5;
  overflow-wrap: anywhere;
}
.basis-warn {
  font-size: 12px;
  line-height: 1.6;
  color: var(--text);
  border-left: 2px solid var(--dim);
  padding-left: 10px;
  margin: 0 0 12px;
}
.basis-actions {
  display: flex;
  gap: 10px;
  flex-wrap: wrap;
}
.pending-block {
  border-top: 1px solid var(--line);
  margin-top: 18px;
  padding-top: 16px;
}
.pending-block h3 {
  font-size: 13px;
  margin: 0 0 6px;
}
.pending-item {
  border: 1px solid var(--line);
  border-radius: 12px;
  padding: 12px;
  margin-top: 10px;
}
.pending-head {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 10px;
  margin-bottom: 8px;
}
.pending-reason {
  font-size: 11px;
  color: var(--dim);
}
.pending-candidates {
  display: flex;
  flex-wrap: wrap;
  gap: 6px 14px;
  margin-bottom: 6px;
}
.pending-candidates .text-button {
  border: 1px solid var(--line);
  border-radius: 999px;
  padding: 4px 10px;
}
.drop {
  color: var(--dim);
  font-size: 11px;
}
</style>
