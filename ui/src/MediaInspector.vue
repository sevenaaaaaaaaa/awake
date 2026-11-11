<script setup lang="ts">
import { nextTick, onMounted, onUnmounted, reactive, ref } from "vue";
import { call, desktop } from "./bridge";
import Artwork from "./Artwork.vue";
import Icon from "./Icon.vue";
import type { Track, MediaInfo, MediaReview } from "./types";
const props = defineProps<{ track: Track }>();
const emit = defineEmits<{ close: []; saved: [] }>();
interface Candidate { id: string; title: string; artist: string; album: string; duration: number; score: number; release_id: string; group_id: string }
const draft = reactive({ title: props.track.title, artist: props.track.artist, album: props.track.album, comment: props.track.comment || "", lyrics: props.track.lyrics || "", artwork_path: props.track.artwork_path });
const info = reactive<MediaInfo>(props.track.media_info ? JSON.parse(JSON.stringify(props.track.media_info)) : {
  original_title: props.track.title, original_artist: props.track.artist, original_album: props.track.album,
  original_artwork: props.track.artwork_path, original_comment: draft.comment, original_lyrics: draft.lyrics,
  source_note: "", suggested_filename: "", cover_style: "auto", credits: [], reviews: [],
});
const busy = ref(false), error = ref(""), notice = ref(""), source = ref(""), tab = ref("info");
const candidates = ref<Candidate[]>([]);
const panel = ref<HTMLElement>();
const previousFocus = document.activeElement as HTMLElement | null;
onUnmounted(() => { if (previousFocus?.isConnected) previousFocus.focus(); });
function keyboard(event: KeyboardEvent) {
  if (event.key === "Escape" && !busy.value) emit("close");
  if (event.key !== "Tab" || !panel.value) return;
  const nodes = [...panel.value.querySelectorAll<HTMLElement>('button:not(:disabled), input:not(:disabled), textarea:not(:disabled), select:not(:disabled), summary')].filter(node => node.offsetParent !== null);
  const first = nodes[0], last = nodes.at(-1);
  if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
  else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
}
const suggestion = ref<{ title: string; artist: string; filename: string }>();
onMounted(async () => {
  await nextTick(); panel.value?.querySelector<HTMLInputElement>("input")?.focus();
  if (!desktop) return;
  try {
    const result = await call<{ track: Track; source_name: string; source_kind: string; suggestion: typeof suggestion.value }>("inspect_media", { id: props.track.id });
    source.value = `${result.source_name} · ${result.source_kind}`; suggestion.value = result.suggestion;
    if (!draft.lyrics) draft.lyrics = result.track.lyrics || "";
  } catch (e) { error.value = String(e); }
});
async function run(action: () => Promise<void>) {
  busy.value = true; error.value = ""; notice.value = "";
  try { await action(); } catch(e) { error.value = String(e); } finally { busy.value = false; }
}
function tidy() {
  if (suggestion.value) { draft.title = suggestion.value.title; draft.artist = suggestion.value.artist; info.suggested_filename = suggestion.value.filename; notice.value = "已生成显示名称与文件名建议，原文件路径保持保留。"; }
}
async function search() { await run(async () => { candidates.value = await call("search_media_info", { title: draft.title, artist: draft.artist === "未知艺人" ? "" : draft.artist }); if (!candidates.value.length) notice.value = "没有找到可靠候选。可手动编辑并选择设计封面。"; }); }
async function choose(candidate: Candidate) {
  await run(async () => {
    const result = await call<{ artwork_path: string | null; lyrics: string; reviews: MediaReview[]; credits: string[]; warnings: string[] }>("fetch_media_resources", { candidate });
    draft.title = candidate.title; draft.artist = candidate.artist; draft.album = candidate.album;
    if (result.artwork_path) { draft.artwork_path = result.artwork_path; info.cover_style = "original"; }
    if (result.lyrics) draft.lyrics = result.lyrics;
    if (!candidate.id.startsWith("lrclib:")) info.reviews = result.reviews; info.credits = [...new Set([...info.credits, ...result.credits])];
    const mismatch = candidate.duration > 0 && props.track.duration > 0 && Math.abs(candidate.duration - props.track.duration) > 5 ? "候选时长不同，可能是现场版、节选或不同版本，请核对。" : "";
    notice.value = `候选资料已放入预览，点击保存后生效。${mismatch}${result.warnings.join("；")}`;
  });
}
async function attachment(kind: string) {
  await run(async () => {
    const result = await call<{ artwork_path: string | null; text: string } | null>("import_media_attachment", { kind });
    if (!result) return;
    if (kind === "cover") { draft.artwork_path = result.artwork_path; info.cover_style = "original"; }
    else if (kind === "lyrics") draft.lyrics = result.text;
    else {
      const rows = JSON.parse(result.text);
      if (!Array.isArray(rows) || rows.length > 50 || rows.some(r => !r.author || !r.source || !r.text || !r.url || !r.license)) throw new Error("评论 JSON 需要为最多 50 条记录，并包含作者、来源、正文、链接和许可");
      info.reviews = rows.map(r => ({ author: r.author, text: r.text, source: r.source, url: r.url, scope: r.scope || "imported", license: r.license, license_url: r.license_url || "" }));
    }
    notice.value = "本地资料已读取，保存后生效。";
  });
}
async function save() { await run(async () => { await call("save_media_info", { req: { id: props.track.id, ...draft, info: { ...info, credits: [...info.credits], reviews: info.reviews.map(r=>({...r})) } } }); emit("saved"); emit("close"); }); }
async function reset() { await run(async () => { await call("reset_media_info", { id: props.track.id }); emit("saved"); emit("close"); }); }
function open(url: string) { if (/^https?:\/\//.test(url)) void call("open_telegram_link", { url }).catch(e => error.value = String(e)); }
</script>
<template>
  <div class="media-scrim" @click.self="!busy && emit('close')" @keydown.stop="keyboard">
    <section ref="panel" class="media-inspector" role="dialog" aria-modal="true" aria-labelledby="media-title" :aria-busy="busy">
      <header><div><small>YOUR PERSONAL MUSIC ARCHIVE</small><h2 id="media-title">整理这份声音</h2></div><button class="icon-btn" aria-label="关闭资料编辑" :disabled="busy" @click="emit('close')"><Icon name="close" /></button></header>
      <div class="media-body">
        <aside>
          <Artwork :path="['auto','original'].includes(info.cover_style) ? draft.artwork_path : null" :seed="draft.title" :style-name="info.cover_style" large />
          <label>封面样式<select v-model="info.cover_style" :disabled="busy"><option value="original">使用图片封面</option><option value="auto">自动设计配图</option><option value="nocturne">夜色 · Nocturne</option><option value="forest">山林 · Forest</option><option value="amber">琥珀 · Amber</option><option value="rose">暮色 · Rose</option></select></label>
          <button class="button" :disabled="busy || !desktop" @click="attachment('cover')">导入封面图片</button>
          <p class="muted">缺少封面时按标题生成设计配图。设计配图不代表原始专辑封面。</p>
          <p class="muted source-original">真实来源：{{ source || track.source_id }}<br />原始位置：{{ track.locator }}</p>
        </aside>
        <div class="media-fields">
          <nav aria-label="曲目资料分类"><button v-for="item in [['info','资料'],['lyrics','歌词'],['reviews','听众乐评']]" :key="item[0]" :aria-pressed="tab===item[0]" @click="tab=item[0]">{{ item[1] }}</button></nav>
          <div v-if="tab==='info'" class="media-form">
            <label>显示名称<input v-model="draft.title" maxlength="250" :disabled="busy" /></label>
            <div class="media-pair"><label>艺人<input v-model="draft.artist" :disabled="busy" /></label><label>专辑<input v-model="draft.album" :disabled="busy" /></label></div>
            <button class="text-button" :disabled="busy || !suggestion" @click="tidy">整理文件名与显示信息</button>
            <label>文件名建议<input v-model="info.suggested_filename" placeholder="用于整理或导出；当前不重命名原文件" /></label>
            <label>来源说明<input v-model="info.source_note" placeholder="例如：个人录音、现场采集、自己的音乐收藏" /></label>
            <label>文件注释 / 个人备注<textarea v-model="draft.comment" rows="3" /></label>
            <button class="button" :disabled="busy || !desktop || !draft.title.trim()" @click="search">{{ busy ? '正在读取资料…' : '查找封面、歌词与乐评' }}</button>
            <p class="muted">主动查询会发送表单中的曲名和艺人；加载候选还会发送专辑与时长。不上传音频、录音内容、路径或来源凭据。</p>
            <article v-for="candidate in candidates" :key="candidate.id" class="media-candidate"><div><strong>{{ candidate.title }}</strong><p>{{ candidate.artist }} · {{ candidate.album || '专辑未确认' }}</p><small>{{ candidate.id.startsWith('lrclib:') ? '歌词库候选' : `匹配分 ${candidate.score}` }} · {{ Math.round(candidate.duration) }} 秒 · 当前 {{ Math.round(track.duration) }} 秒</small></div><button class="button" :disabled="busy" @click="choose(candidate)">预览资料</button></article>
          </div>
          <div v-else-if="tab==='lyrics'" class="media-form"><button class="button" :disabled="busy || !desktop" @click="attachment('lyrics')">导入 LRC / TXT 歌词</button><label>歌词内容<textarea v-model="draft.lyrics" rows="15" placeholder="支持同步 LRC 或纯文本；录音可以留空" /></label></div>
          <div v-else class="media-form"><button class="button" :disabled="busy || !desktop" @click="attachment('reviews')">导入带署名与来源的评论 JSON</button><p v-if="!info.reviews.length" class="muted">还没有匹配到听众乐评。评论为空时不会生成或虚构内容。</p><article v-for="(review, i) in info.reviews" :key="i" class="media-review"><small>{{ review.scope==='release_group' ? '专辑乐评' : review.scope==='recording' ? '单曲乐评' : '导入评论' }} · {{ review.source }}</small><strong>{{ review.author }}</strong><p>{{ review.text }}</p><small>{{ review.license }}</small><button class="text-button" @click="open(review.url)">查看原文</button><button v-if="review.license_url" class="text-button" @click="open(review.license_url)">许可说明</button><button class="text-button" @click="info.reviews.splice(i,1)">移除此条</button></article></div>
          <details v-if="info.credits.length"><summary>资料出处</summary><p v-for="credit in info.credits" :key="credit" class="muted source-original">{{ credit }}</p></details>
        </div>
      </div>
      <footer><p v-if="error" role="alert" class="job-error">{{ error }}</p><p v-if="notice" role="status" class="muted">{{ notice }}</p><div><button class="text-button" :disabled="busy || !track.media_info" @click="reset">恢复原始信息</button><button class="button primary" :disabled="busy || !desktop || !draft.title.trim()" @click="save">保存到曲库</button></div></footer>
    </section>
  </div>
</template>
<style scoped>
.media-scrim{position:fixed;inset:0;z-index:120;background:#000a;backdrop-filter:blur(12px);display:grid;place-items:center;padding:24px}.media-inspector{background:var(--surface,#15161a);color:var(--text,#f3f3f3);border:1px solid var(--line,#333);border-radius:20px;width:min(940px,100%);max-height:90dvh;display:flex;flex-direction:column;box-shadow:0 30px 120px #0008}header,footer{padding:22px 26px}header{display:flex;justify-content:space-between;align-items:center;border-bottom:1px solid var(--line,#333)}header small{color:var(--accent);font-size:10px;letter-spacing:.18em}h2{margin:6px 0 0}.media-body{display:grid;grid-template-columns:240px 1fr;gap:28px;padding:26px;overflow:auto}aside{display:grid;align-content:start;gap:14px}.media-fields,.media-form{display:grid;align-content:start;gap:14px}label{display:grid;gap:7px;font-size:13px}input,textarea,select{width:100%;padding:10px 12px;background:var(--bg,#101114);color:inherit;border:1px solid var(--line,#333);border-radius:8px;font:inherit}textarea{resize:vertical;line-height:1.7}.media-pair{display:grid;grid-template-columns:1fr 1fr;gap:12px}nav{display:flex;gap:8px;border-bottom:1px solid var(--line,#333);padding-bottom:12px}nav button{padding:9px 16px;border-radius:8px}nav button[aria-pressed=true]{background:var(--accent);color:var(--on-accent,#101218)}.media-candidate{border:1px solid var(--line,#333);border-radius:12px;padding:14px;display:flex;justify-content:space-between;align-items:center;gap:12px}.media-candidate p{font-size:12px;margin:5px 0}.media-review{display:grid;gap:9px;border:1px solid var(--line,#333);border-radius:12px;padding:16px}.media-review p{white-space:pre-wrap;line-height:1.75}.source-original{overflow-wrap:anywhere;font-size:11px;line-height:1.6}footer{border-top:1px solid var(--line,#333)}footer>div{display:flex;align-items:center;justify-content:space-between;gap:12px}.muted{font-size:12px;line-height:1.65}button:focus-visible{outline:2px solid var(--accent);outline-offset:3px}@media(max-width:680px){.media-scrim{padding:8px}.media-body{grid-template-columns:1fr;padding:18px}aside .artwork{max-width:220px;justify-self:center}.media-pair{grid-template-columns:1fr}header,footer{padding:16px}}
</style>
