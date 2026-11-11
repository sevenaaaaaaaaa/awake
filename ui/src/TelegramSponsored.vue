<script setup lang="ts">
import { nextTick, onUnmounted, ref, watch } from "vue";
import { call, desktop } from "./bridge";
const props = defineProps<{ sourceId: string }>();
interface Ad { id: string; title: string; text: string; url: string; button: string; sponsor_info: string; additional_info: string }
const ads = ref<Ad[]>([]), error = ref("");
let observer: IntersectionObserver | undefined, timer: ReturnType<typeof setInterval> | undefined;
const nodes = new Map<string, HTMLElement>();
const seen = new Set<string>();
function observe(id: string, node: unknown) {
  if (node instanceof HTMLElement) { nodes.set(id, node); observer?.observe(node); }
}
async function load() {
  if (!desktop || !props.sourceId) return;
  try {
    const result = await call<{ messages: Ad[] }>("telegram_sponsored", { id: props.sourceId });
    ads.value = result.messages; error.value = "";
    await nextTick();
  } catch (e) { ads.value = []; error.value = String(e); }
}
watch(() => props.sourceId, async () => {
  observer?.disconnect(); nodes.clear(); seen.clear();
  if (timer) clearInterval(timer);
  observer = new IntersectionObserver(entries => {
    for (const entry of entries) {
      const id = (entry.target as HTMLElement).dataset.adId;
      if (entry.isIntersecting && entry.intersectionRatio >= 0.99 && id && !seen.has(id)) {
        seen.add(id);
        void call("telegram_ad_viewed", { id: props.sourceId, ad: id }).catch(() => seen.delete(id));
      }
    }
  }, { threshold: 1 });
  await load(); timer = setInterval(load, 300000);
}, { immediate: true });
onUnmounted(() => { observer?.disconnect(); if (timer) clearInterval(timer); });
function confirmLink(event: MouseEvent, url: string) {
  event.preventDefault();
  if (window.confirm("打开此赞助消息链接？")) void call("open_telegram_link", { url }).catch(e => error.value = String(e));
}
function safeURL(value: string): string | undefined {
  try { const u = new URL(value); if (["https:", "http:", "tg:"].includes(u.protocol)) return u.href; } catch { /* Invalid sponsored URL. */ }
}
</script>
<template>
  <div v-if="ads.length || error" class="telegram-sponsored" aria-label="Telegram 频道赞助消息">
    <p v-if="error" role="status" class="muted">Telegram 频道信息暂不可用：{{ error }}</p>
    <article v-for="ad in ads" :key="ad.id" :ref="node => observe(ad.id, node)" :data-ad-id="ad.id">
      <small>Telegram 赞助消息</small><strong>{{ ad.title }}</strong><p>{{ ad.text }}</p>
      <p v-if="ad.sponsor_info">{{ ad.sponsor_info }}</p><p v-if="ad.additional_info">{{ ad.additional_info }}</p>
      <a v-if="safeURL(ad.url)" :href="safeURL(ad.url)" target="_blank" rel="noopener noreferrer" @click="event => confirmLink(event, ad.url)">{{ ad.button || '查看' }}</a>
    </article>
  </div>
</template>
<style scoped>
.telegram-sponsored { display: grid; gap: 10px; font-size: 13px; }
article { display: grid; gap: 7px; padding: 14px; border: 1px solid var(--border); border-radius: 12px; }
small { color: var(--text-muted); } p { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; } a { color: var(--accent); }
</style>
