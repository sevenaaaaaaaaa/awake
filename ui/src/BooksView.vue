<script setup lang="ts">
import { computed, onMounted, ref, watch } from "vue";
import Icon from "./Icon.vue";
import Artwork from "./Artwork.vue";
import { call, desktop } from "./bridge";
import {
  duration,
  type Book,
  type NewsItem,
  type Services,
  type SpeechJob,
  type SpeechPlan,
  type Track,
  type Voice,
} from "./types";

const props = defineProps<{
  books: Book[];
  tracks: Track[];
  jobs: SpeechJob[];
  services: Services;
  now: Track | null;
}>();
const emit = defineEmits<{
  play: [Track, Track[]];
  resume: [Book];
  toast: [string];
  refresh: [];
  openPlaylist: [string];
  importFiles: [];
}>();

type Tab = "shelf" | "studio" | "news";
const tab = ref<Tab>("shelf");
const shelf = ref<Book[]>([]);
const includeAll = ref(false);
const sort = ref("recent");
const selected = ref<string | null>(null);
const voices = ref<Voice[]>([]);
const voice = ref("");
const testVoice = ref("");
const error = ref("");
const busy = ref(false);

async function loadShelf() {
  if (!desktop) {
    shelf.value = props.books;
    return;
  }
  try {
    shelf.value = await call<Book[]>("audiobook_shelf", {
      includeAll: includeAll.value,
    });
  } catch (reason) {
    error.value = String(reason);
  }
}
watch(
  () => props.books,
  () => {
    if (!includeAll.value) shelf.value = props.books;
  },
);
watch(includeAll, () => void loadShelf());

const sorted = computed(() => {
  const list = [...shelf.value];
  if (sort.value === "title")
    list.sort((a, b) => a.title.localeCompare(b.title, "zh-CN"));
  else if (sort.value === "author")
    list.sort((a, b) =>
      (a.author || "未知").localeCompare(b.author || "未知", "zh-CN"),
    );
  else if (sort.value === "unfinished")
    list.sort((a, b) => {
      const pa = a.total_seconds ? a.listened_seconds / a.total_seconds : 0;
      const pb = b.total_seconds ? b.listened_seconds / b.total_seconds : 0;
      return Number(pa >= 0.999) - Number(pb >= 0.999) || pa - pb;
    });
  return list;
});

const current = computed(
  () => sorted.value.find((book) => book.id === selected.value) ?? null,
);
const booksInProgress = computed(
  () => shelf.value.filter((book) => book.listened_seconds > 0 && !book.finished),
);

function percent(book: Book): number {
  if (!book.total_seconds) return 0;
  return Math.max(0, Math.min(100, Math.round((book.listened_seconds / book.total_seconds) * 100)));
}
function quality(track: Track): string {
  return (track.codec || "音频").toUpperCase() + " · " + duration(track.duration);
}
function hours(seconds: number): string {
  if (!seconds) return "0 分钟";
  const h = Math.floor(seconds / 3600);
  const m = Math.round((seconds % 3600) / 60);
  return h > 0 ? h + " 小时 " + m + " 分钟" : m + " 分钟";
}
function openBook(book: Book) {
  selected.value = book.id;
}
function resume(book: Book) {
  emit("resume", book);
}
function playChapter(book: Book, track: Track) {
  emit("play", track, book.chapters);
}
async function finish(book: Book) {
  const track = book.chapters[book.chapters.length - 1];
  if (!track) return;
  try {
    await call("audiobook_progress", {
      bookId: book.id,
      trackId: track.id,
      position: 0,
      finished: true,
    });
    emit("toast", "已标记听完《" + book.title + "》");
    emit("refresh");
    await loadShelf();
  } catch (reason) {
    error.value = String(reason);
  }
}

async function loadVoices() {
  if (!desktop) return;
  try {
    voices.value = await call<Voice[]>("speech_voices");
    const preferred =
      voices.value.find((v) => v.name.includes("Tingting")) ||
      voices.value.find((v) => v.language === "zh_CN") ||
      voices.value[0];
    if (preferred) {
      if (!voice.value) voice.value = preferred.name;
      if (!testVoice.value) testVoice.value = preferred.name;
    }
  } catch (reason) {
    error.value = String(reason);
  }
}
onMounted(async () => {
  shelf.value = props.books;
  await Promise.all([loadShelf(), loadVoices()]);
});

/* ---------------- AI 拆书 / 拆剧 ---------------- */
const mode = ref<"book" | "drama">("book");
const title = ref("");
const author = ref("");
const text = ref("");
const useCloud = ref(false);
const planning = ref(false);
const plan = ref<SpeechPlan | null>(null);
const rendering = ref(false);
const planChars = computed(() =>
  plan.value
    ? plan.value.chapters.reduce(
        (sum, chapter) =>
          sum +
          chapter.segments.reduce(
            (value, segment) => value + segment.text.length,
            0,
          ),
        0,
      )
    : 0,
);
const speakers = computed(() => {
  const set = new Set<string>();
  plan.value?.chapters.forEach((chapter) =>
    chapter.segments.forEach((segment) => {
      if (segment.speaker) set.add(segment.speaker);
    }),
  );
  return [...set];
});

async function readText(event: Event) {
  const input = event.target as HTMLInputElement;
  const file = input.files?.[0];
  input.value = "";
  if (!file) return;
  if (file.size > 2 * 1024 * 1024) {
    error.value = "文本文件超过 2 MB，请精简后再试。";
    return;
  }
  text.value = await file.text();
  if (!title.value) title.value = file.name.replace(/\.[^.]+$/, "");
}

async function makePlan() {
  if (!text.value.trim()) {
    error.value = "请先粘贴正文或选择一个文本文件。";
    return;
  }
  error.value = "";
  planning.value = true;
  try {
    plan.value = await call<SpeechPlan>("speech_plan", {
      req: {
        title: title.value,
        author: author.value,
        mode: mode.value,
        text: text.value,
        voice: voice.value,
        use_cloud: useCloud.value && !!props.services.curator,
      },
    });
    emit("toast", "已拆成 " + plan.value.chapters.length + " 章，可先预览再合成");
  } catch (reason) {
    error.value = String(reason).replace(/^Error: /, "");
  } finally {
    planning.value = false;
  }
}

async function render() {
  if (!plan.value) return;
  error.value = "";
  rendering.value = true;
  try {
    await call("speech_render", {
      planId: plan.value.id,
      voice: voice.value,
    });
    emit("toast", "已开始后台合成，完成后会出现在书架和歌单里");
    emit("refresh");
  } catch (reason) {
    error.value = String(reason).replace(/^Error: /, "");
  } finally {
    rendering.value = false;
  }
}

/* ---------------- 新闻播报 ---------------- */
const news = ref<NewsItem[]>([]);
const picked = ref<string[]>([]);
const newsKind = ref<"url" | "text" | "eml">("url");
const newsUrl = ref("");
const newsTitle = ref("");
const newsText = ref("");
const newsBusy = ref(false);
const briefing = ref("");

async function loadNews() {
  if (!desktop) return;
  try {
    news.value = await call<NewsItem[]>("news_list");
  } catch (reason) {
    error.value = String(reason);
  }
}

async function addNews() {
  error.value = "";
  newsBusy.value = true;
  try {
    let payload: Record<string, unknown> = { kind: newsKind.value };
    if (newsKind.value === "url") {
      if (!newsUrl.value.trim()) throw new Error("请填写新闻链接");
      payload = { ...payload, url: newsUrl.value.trim() };
    } else if (newsKind.value === "text") {
      if (!newsText.value.trim()) throw new Error("请粘贴新闻或邮件正文");
      payload = {
        ...payload,
        title: newsTitle.value,
        content: newsText.value,
      };
    } else {
      if (!newsText.value.trim()) throw new Error("请选择 .eml 邮件文件");
      payload = {
        ...payload,
        title: newsTitle.value,
        content: newsText.value,
      };
    }
    const item = await call<NewsItem>("news_add", { req: payload });
    news.value = [item, ...news.value];
    if (!picked.value.includes(item.id)) picked.value.push(item.id);
    newsUrl.value = "";
    newsTitle.value = "";
    newsText.value = "";
    emit("toast", "已加入新闻列表：" + item.title);
  } catch (reason) {
    error.value = String(reason).replace(/^Error: /, "");
  } finally {
    newsBusy.value = false;
  }
}

async function readEml(event: Event) {
  const input = event.target as HTMLInputElement;
  const file = input.files?.[0];
  input.value = "";
  if (!file) return;
  if (file.size > 2 * 1024 * 1024) {
    error.value = "邮件文件超过 2 MB";
    return;
  }
  newsKind.value = "eml";
  newsText.value = await file.text();
  if (!newsTitle.value) newsTitle.value = file.name.replace(/\.[^.]+$/, "");
}

function togglePick(id: string) {
  picked.value = picked.value.includes(id)
    ? picked.value.filter((item) => item !== id)
    : [...picked.value, id];
}
async function removeNews(id: string) {
  try {
    await call("news_delete", { id });
    news.value = news.value.filter((item) => item.id !== id);
    picked.value = picked.value.filter((item) => item !== id);
  } catch (reason) {
    error.value = String(reason);
  }
}

async function buildBriefing() {
  if (!news.value.length) {
    error.value = "请先加入至少一条新闻或邮件";
    return;
  }
  error.value = "";
  newsBusy.value = true;
  try {
    const plan = await call<SpeechPlan>("news_plan", {
      req: {
        title: briefing.value,
        ids: picked.value,
        voice: voice.value,
        use_cloud: useCloud.value && !!props.services.curator,
      },
    });
    await call("speech_render", { planId: plan.id, voice: voice.value });
    emit("toast", "AI 新闻播报已开始合成，完成后自动加入歌单");
    emit("refresh");
  } catch (reason) {
    error.value = String(reason).replace(/^Error: /, "");
  } finally {
    newsBusy.value = false;
  }
}

const activeJobs = computed(() =>
  props.jobs.filter((job) => job.state === "running").slice(0, 3),
);
</script>

<template>
  <div class="page-intro">
    <div>
      <p class="eyebrow">LISTEN LONGER, REMEMBER MORE</p>
      <h1>把长内容，<span class="serif">听成自己的时间。</span></h1>
      <p>有声书、AI 拆书、新闻与邮件播报，都在同一个书架里继续。</p>
    </div>
    <span class="subtle-badge"
      ><span class="status-dot" />{{ booksInProgress.length }} 本在听</span
    >
  </div>

  <div class="segmented book-tabs" role="tablist" aria-label="听书功能">
    <button :class="{ active: tab === 'shelf' }" @click="tab = 'shelf'">书架</button>
    <button :class="{ active: tab === 'studio' }" @click="tab = 'studio'">
      AI 拆书 / 拆剧
    </button>
    <button :class="{ active: tab === 'news' }" @click="tab = 'news'">
      新闻播报
    </button>
  </div>

  <p v-if="error" class="job-error" role="alert">{{ error }}</p>

  <div v-if="activeJobs.length" class="speech-jobs">
    <article v-for="job in activeJobs" :key="job.id" class="speech-job">
      <div>
        <strong>{{ job.title }}</strong>
        <small>{{ job.message }}</small>
      </div>
      <div class="progress-track" aria-hidden="true">
        <span :style="{ width: (job.total ? (job.done / job.total) * 100 : 0) + '%' }" />
      </div>
      <small>{{ job.done }} / {{ job.total }} 章</small>
    </article>
  </div>

  <template v-if="tab === 'shelf'">
    <div class="library-toolbar">
      <div class="segmented">
        <button :class="{ active: !includeAll }" @click="includeAll = false">
          有声书
        </button>
        <button :class="{ active: includeAll }" @click="includeAll = true">
          全部长音频
        </button>
      </div>
      <label class="inline-search"
        ><span class="muted">排序</span
        ><select v-model="sort" aria-label="书架排序">
          <option value="recent">最近在听</option>
          <option value="title">书名</option>
          <option value="author">作者</option>
          <option value="unfinished">未听完优先</option>
        </select></label
      >
    </div>

    <div v-if="!sorted.length" class="empty-state">
      <Icon name="book" :size="40" />
      <h2>书架还空着。</h2>
      <p>
        在「音乐来源」里添加有声书文件夹（m4b / mp3 / m4a 都行），或到
        AI 拆书把一段文字变成有声书。
      </p>
      <button class="button primary" @click="tab = 'studio'">
        去做第一本有声书
      </button>
    </div>

    <div v-else class="book-grid">
      <button
        v-for="book in sorted"
        :key="book.id"
        class="book-card"
        :class="{ active: selected === book.id }"
        @click="openBook(book)"
      >
        <Artwork :path="book.artwork_path" :seed="book.title" />
        <div class="book-copy">
          <strong>{{ book.title }}</strong>
          <small>{{ book.author || '未知作者' }} · {{ book.chapters.length }} 章 ·
            {{ hours(book.total_seconds) }}</small>
          <div class="progress-track" aria-hidden="true">
            <span :style="{ width: percent(book) + '%' }" />
          </div>
          <small class="muted">
            {{ percent(book) }}%{{ book.finished ? ' · 已听完' : '' }}
          </small>
        </div>
      </button>
    </div>

    <section v-if="current" class="book-detail eq-card">
      <div class="book-detail-head">
        <Artwork :path="current.artwork_path" :seed="current.title" />
        <div>
          <p class="eyebrow">AUDIOBOOK</p>
          <h2>{{ current.title }}</h2>
          <p>
            {{ current.author || '未知作者' }} ·
            {{ current.chapters.length }} 章 · {{ hours(current.total_seconds) }}
          </p>
          <div class="button-row">
            <button class="button primary" @click="resume(current)">
              <Icon name="play" />{{ current.listened_seconds > 0 ? '继续听' : '开始听' }}
            </button>
            <button class="button" @click="playChapter(current, current.chapters[0])">
              从头播放
            </button>
            <button
              v-if="!current.finished"
              class="text-button"
              @click="finish(current)"
            >
              标记听完
            </button>
          </div>
        </div>
      </div>
      <div class="chapter-list">
        <button
          v-for="(chapter, index) in current.chapters"
          :key="chapter.id"
          class="chapter-row"
          :class="{ playing: now?.id === chapter.id }"
          @click="playChapter(current, chapter)"
        >
          <span class="chapter-index">{{ index + 1 }}</span>
          <span class="chapter-copy"
            ><strong>{{ chapter.title }}</strong
            ><small>{{ quality(chapter) }}</small></span
          >
          <span class="muted">{{ duration(chapter.duration) }}</span>
          <Icon :name="now?.id === chapter.id ? 'wave' : 'play'" />
        </button>
      </div>
    </section>
  </template>

  <template v-else-if="tab === 'studio'">
    <section class="studio-panel speech-studio">
      <div class="studio-orbit"><Icon name="book" :size="64" /></div>
      <form @submit.prevent="makePlan">
        <label class="field-label">把它做成</label>
        <div class="segmented">
          <button
            type="button"
            :class="{ active: mode === 'book' }"
            @click="mode = 'book'"
          >
            有声书（拆书）
          </button>
          <button
            type="button"
            :class="{ active: mode === 'drama' }"
            @click="mode = 'drama'"
          >
            广播剧（拆剧）
          </button>
        </div>
        <div class="speech-meta">
          <label>书名 / 剧名<input v-model="title" placeholder="可以留空，自动从正文识别" /></label>
          <label>作者<input v-model="author" placeholder="可选" /></label>
          <label>旁白语音<select v-model="voice" aria-label="旁白语音">
            <option v-for="item in voices" :key="item.name" :value="item.name">
              {{ item.name }} · {{ item.language }}
            </option>
          </select></label>
        </div>
        <label class="field-label">正文</label>
        <textarea
          v-model="text"
          rows="8"
          placeholder="粘贴小说、文章或剧本全文。拆剧模式建议每行写成「角色：台词」。"
        />
        <div class="speech-actions">
          <label class="text-button file-label">
            <Icon name="folder" />导入 .txt / .md
            <input type="file" accept=".txt,.md,.markdown" @change="readText" />
          </label>
          <label v-if="services.curator" class="checkbox-label">
            <input v-model="useCloud" type="checkbox" />用云端 AI
            智能分章（会发送本次文本）
          </label>
          <button class="button primary" :disabled="planning || !desktop">
            <span v-if="planning" class="spinner" />
            {{ planning ? '正在拆分…' : '预览分章' }}
          </button>
        </div>
      </form>
    </section>

    <section v-if="plan" class="eq-card">
      <div class="section-heading">
        <div>
          <h2>{{ plan.title }}</h2>
          <p>
            {{ plan.chapters.length }} 章 · {{ planChars }} 字 · 约
            {{ hours(planChars / 4.2) }}
            <template v-if="speakers.length"> · {{ speakers.length }} 个角色</template>
          </p>
        </div>
        <button
          class="button primary"
          :disabled="rendering"
          @click="render"
        >
          <Icon name="wave" />{{ rendering ? '正在提交…' : '合成有声书' }}
        </button>
      </div>
      <p v-if="plan.note" class="muted">{{ plan.note }}</p>
      <div class="chapter-list compact">
        <div v-for="(chapter, index) in plan.chapters" :key="index" class="chapter-row">
          <span class="chapter-index">{{ index + 1 }}</span>
          <span class="chapter-copy"
            ><strong>{{ chapter.title }}</strong
            ><small>{{ chapter.segments.length }} 段 ·
              {{ chapter.segments.reduce((sum, s) => sum + s.text.length, 0) }} 字</small></span
          >
        </div>
      </div>
    </section>

    <div v-if="jobs.length" class="section-heading">
      <div><h2>合成记录</h2><p>完成后的作品会出现在书架和歌单里。</p></div>
    </div>
    <article v-for="job in jobs.slice(0, 6)" :key="job.id" class="brief-card">
      <Icon :name="job.state === 'failed' ? 'info' : 'wave'" />
      <div>
        <strong>{{ job.title }}</strong>
        <small>{{ job.message }}</small>
        <p v-if="job.error" class="job-error">{{ job.error }}</p>
      </div>
      <button
        v-if="job.state === 'done' && job.playlist_id"
        class="button"
        @click="emit('openPlaylist', job.playlist_id)"
      >
        打开歌单
      </button>
    </article>
  </template>

  <template v-else>
    <section class="eq-card news-panel">
      <div class="section-heading">
        <div>
          <h2>把新闻和邮件，变成一段播报。</h2>
          <p>只读取你给的公开链接或本地文件；不会登录邮箱，也不会上传未勾选的内容。</p>
        </div>
      </div>
      <div class="segmented">
        <button :class="{ active: newsKind === 'url' }" @click="newsKind = 'url'">链接</button>
        <button :class="{ active: newsKind === 'text' }" @click="newsKind = 'text'">粘贴文本</button>
        <button :class="{ active: newsKind === 'eml' }" @click="newsKind = 'eml'">邮件 .eml</button>
      </div>
      <div v-if="newsKind === 'url'" class="import-field">
        <label for="news-url">新闻 / 文章链接</label>
        <input id="news-url" v-model="newsUrl" placeholder="https://example.com/story" />
      </div>
      <div v-else class="import-field">
        <label>标题<input v-model="newsTitle" placeholder="可选" /></label>
        <textarea
          v-model="newsText"
          rows="6"
          :placeholder="newsKind === 'eml' ? '选择 .eml 文件，或粘贴邮件原文' : '粘贴新闻正文'"
        />
        <label class="text-button file-label">
          <Icon name="folder" />选择 .eml 文件
          <input type="file" accept=".eml,message/rfc822" @change="readEml" />
        </label>
      </div>
      <div class="button-row">
        <button class="button" :disabled="newsBusy || !desktop" @click="addNews">
          <Icon name="plus" />{{ newsBusy ? '正在读取…' : '加入播报列表' }}
        </button>
        <button class="text-button" type="button" @click="emit('importFiles')">
          <Icon name="wave" />导入播客音频
        </button>
      </div>

      <div v-if="news.length" class="news-list">
        <label v-for="item in news" :key="item.id" class="news-row">
          <input
            type="checkbox"
            :checked="picked.includes(item.id)"
            @change="togglePick(item.id)"
          />
          <span>
            <strong>{{ item.title }}</strong>
            <small>{{ item.source }} ·
              {{ new Date(item.created_at).toLocaleString("zh-CN") }}</small>
            <p class="muted">{{ item.text.slice(0, 120) }}…</p>
          </span>
          <button class="icon-btn" aria-label="删除" @click.prevent="removeNews(item.id)">
            <Icon name="close" :size="14" />
          </button>
        </label>
      </div>
      <p v-else class="list-empty">还没有导入内容。加一条链接，或选择一封邮件。</p>

      <div v-if="jobs.some((job) => job.state === 'done')" class="speech-jobs">
        <article
          v-for="job in jobs.filter((item) => item.state === 'done').slice(0, 3)"
          :key="job.id"
          class="speech-job"
        >
          <div>
            <strong>{{ job.title }}</strong>
            <small>{{ job.message }}</small>
          </div>
          <span />
          <button
            v-if="job.playlist_id"
            class="button"
            @click="emit('openPlaylist', job.playlist_id)"
          >
            播放
          </button>
        </article>
      </div>
      <div class="speech-actions">
        <label>播报标题<input v-model="briefing" placeholder="可选，例如「早间十分钟」" /></label>
        <label class="checkbox-label" v-if="services.curator">
          <input v-model="useCloud" type="checkbox" />用云端 AI 摘要
        </label>
        <button
          class="button primary"
          :disabled="newsBusy || !news.length || !desktop"
          @click="buildBriefing"
        >
          <Icon name="wave" />生成 AI 新闻播报
        </button>
      </div>
    </section>
  </template>
</template>
