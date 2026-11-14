<script setup lang="ts">
import { computed, nextTick, onMounted, ref, watch } from "vue";
import Icon from "./Icon.vue";
import {
  playlistImportFetch,
  playlistImportFile,
  playlistImportGaps,
  playlistImportMatch,
} from "./bridge";
import type { MatchGaps } from "./bridge";
import type {
  ImportMatch,
  ImportedPlaylist,
  Playlist,
  PlaylistEntry,
  Track,
} from "./types";

// 歌单导入：读取来源 → 解析 → 与本地曲库匹配 → 手动修正 → 保存为静态歌单。
// 不扫描曲库、不自动播放；后端命令按契约调用，未就绪时给出可读中文错误。
interface SourceOption {
  id: string;
  label: string;
  hint: string;
  placeholder: string;
  kind: "link" | "text" | "file";
}

const SOURCES: SourceOption[] = [
  {
    id: "netease",
    label: "网易云音乐",
    hint: "公开歌单链接或歌单 ID；需要曲目列表可公开访问。",
    placeholder: "https://music.163.com/playlist?id=… 或歌单 ID",
    kind: "link",
  },
  {
    id: "qq",
    label: "QQ 音乐",
    hint: "公开歌单链接或歌单 ID。",
    placeholder: "https://y.qq.com/n/ryqq/playlist/…",
    kind: "link",
  },
  {
    id: "youtube",
    label: "YouTube",
    hint: "播放列表链接或 list ID。",
    placeholder: "https://www.youtube.com/playlist?list=…",
    kind: "link",
  },
  {
    id: "apple",
    label: "Apple Music",
    hint: "公开播放列表链接。",
    placeholder: "https://music.apple.com/…/playlist/…",
    kind: "link",
  },
  {
    id: "spotify",
    label: "Spotify",
    hint: "公开播放列表链接。",
    placeholder: "https://open.spotify.com/playlist/…",
    kind: "link",
  },
  {
    id: "text",
    label: "粘贴文本",
    hint: "每行一首，格式「艺人 - 歌名」，行号会自动去掉。",
    placeholder: "",
    kind: "text",
  },
  {
    id: "file",
    label: "文件",
    hint: "支持 m3u / m3u8 / pls / csv / json / cue / txt，只在本机解析。",
    placeholder: "",
    kind: "file",
  },
];

const props = defineProps<{
  tracks: Track[];
  savePlaylist: (
    name: string,
    smart: boolean,
    items: Track[],
    entries: PlaylistEntry[],
  ) => Promise<Playlist | undefined>;
  /** 选择并扫描一个本地文件夹；返回是否真的扫到了东西。导入缺口时才用得上。 */
  scanFolder?: () => Promise<boolean>;
}>();

const emit = defineEmits<{
  close: [];
  created: [playlist: Playlist];
}>();

type Busy = "parse" | "match" | "save" | null;

const source = ref("netease");
const input = ref("");
const fileName = ref("");
const fileContent = ref("");
const fileInput = ref<HTMLInputElement | null>(null);
const firstInput = ref<HTMLInputElement | HTMLTextAreaElement | null>(null);
const nameInput = ref<HTMLInputElement | null>(null);
const busy = ref<Busy>(null);
const error = ref("");
const playlist = ref<ImportedPlaylist | null>(null);
const matches = ref<ImportMatch[]>([]);
const selected = ref<boolean[]>([]);
const manualIds = ref<Record<number, string>>({});
const onlyUnmatched = ref(false);
const manualOpen = ref<number | null>(null);
const manualQuery = ref("");
const name = ref("");
const gaps = ref<MatchGaps | null>(null);
const rescanning = ref(false);

const currentSource = computed(
  () => SOURCES.find((option) => option.id === source.value) ?? SOURCES[0],
);
const step = computed(() => (playlist.value ? "review" : "source"));
const totalTracks = computed(() => playlist.value?.tracks.length ?? 0);

const libraryById = computed(
  () => new Map(props.tracks.map((track) => [track.id, track])),
);

function effectiveId(index: number): string | null {
  return manualIds.value[index] ?? matches.value[index]?.song_id ?? null;
}

function effectiveTrack(index: number): Track | undefined {
  const id = effectiveId(index);
  return id ? libraryById.value.get(id) : undefined;
}

const matchedCount = computed(() => {
  const total = playlist.value?.tracks.length ?? 0;
  let count = 0;
  for (let index = 0; index < total; index += 1)
    if (effectiveId(index)) count += 1;
  return count;
});

const chosen = computed(() => {
  const list = playlist.value?.tracks ?? [];
  const picked: Track[] = [];
  list.forEach((_track, index) => {
    if (!selected.value[index]) return;
    const track = effectiveTrack(index);
    if (track) picked.push(track);
  });
  return picked;
});
const chosenEntries = computed<PlaylistEntry[]>(() => {
  const list = playlist.value?.tracks ?? [];
  const picked: PlaylistEntry[] = [];
  list.forEach((track, index) => {
    if (!selected.value[index]) return;
    const local = effectiveTrack(index);
    const title = (local?.title || track.title || "").trim();
    const artist = (local?.artist || track.artist || "").trim();
    if (!title && !artist && !local) return;
    picked.push({
      track_id: effectiveId(index),
      title,
      artist,
      album: (local?.album || track.album || "").trim(),
    });
  });
  return picked;
});
const pendingCount = computed(
  () => chosenEntries.value.filter((entry) => !entry.track_id).length,
);

const rows = computed(() =>
  (playlist.value?.tracks ?? []).map((track, index) => ({
    track,
    index,
    match: matches.value[index] ?? null,
    local: effectiveTrack(index),
    on: selected.value[index] === true,
  })),
);

const visibleRows = computed(() =>
  rows.value.filter((row) => !onlyUnmatched.value || !row.local),
);

const manualResults = computed(() => {
  const query = manualQuery.value.trim().toLowerCase();
  const list = query
    ? props.tracks.filter((track) =>
        `${track.title} ${track.artist} ${track.album}`
          .toLowerCase()
          .includes(query),
      )
    : props.tracks;
  return list.slice(0, 40);
});

const cueNote = computed(() => {
  if (source.value === "file" && /\.cue$/i.test(fileName.value)) return true;
  const current = playlist.value;
  return /cue/i.test(current?.source ?? "") || /cue/i.test(current?.note ?? "");
});

function readable(reason: unknown, action: string): string {
  const raw = String(reason instanceof Error ? reason.message : reason)
    .replace(/^Error:\s*/, "")
    .trim();
  if (!raw) return `${action}失败，请稍后重试。`;
  if (/浏览器预览|需要桌面版/.test(raw)) return raw;
  if (/not found|unknown command|command .* not found/i.test(raw))
    return `桌面版后端还没有提供「${action}」能力，请更新到最新桌面版后再试。`;
  if (/not supported|unsupported|未实现/i.test(raw))
    return `桌面版暂不支持「${action}」，请更新到最新版本后再试。`;
  if (/failed to fetch|network|timed out|timeout|dns|connect|连接/i.test(raw))
    return `${action}失败：无法连接来源，请检查网络或链接后重试。`;
  if (/401|403|unauthorized|forbidden|登录|cookie|token/i.test(raw))
    return `${action}失败：来源需要登录，或链接已失效，请换一个公开链接。`;
  if (/404|not exist|找不到/i.test(raw))
    return `${action}失败：没有找到这个歌单，请确认链接或 ID。`;
  return `${action}失败：${raw}`;
}

function adopted(result: ImportedPlaylist): boolean {
  if (!result || !Array.isArray(result.tracks) || !result.tracks.length) {
    error.value = "没有从这份来源里解析到曲目，请检查链接、ID 或文件内容。";
    return false;
  }
  playlist.value = {
    name: result.name ?? "",
    source: result.source ?? source.value,
    tracks: result.tracks,
    note: result.note ?? null,
  };
  name.value = (result.name || "").trim() || "导入的歌单";
  matches.value = [];
  gaps.value = null;
  selected.value = result.tracks.map(() => false);
  manualIds.value = {};
  manualOpen.value = null;
  onlyUnmatched.value = false;
  error.value = "";
  return true;
}

async function fetchMatches() {
  const current = playlist.value;
  if (!current) return;
  busy.value = "match";
  error.value = "";
  try {
    const result = await playlistImportMatch(current.tracks);
    if (!Array.isArray(result)) throw new Error("匹配结果格式不正确");
    matches.value = result;
    // 默认全部选中：匹配到本地的是可直接播放的曲目，未匹配的保留为待匹配条目。
    selected.value = current.tracks.map(() => true);
    manualIds.value = {};
    manualOpen.value = null;
    gaps.value = await playlistImportGaps(result);
  } catch (reason) {
    error.value = readable(reason, "匹配本地曲库");
  } finally {
    busy.value = null;
  }
}

/** 缺口引导：选一个文件夹扫进曲库，再重新匹配一次。 */
async function rescanAndMatch() {
  if (!props.scanFolder || busy.value) return;
  rescanning.value = true;
  error.value = "";
  try {
    const scanned = await props.scanFolder();
    if (!scanned) {
      error.value = "没有扫到音频文件。换一个包含音乐的文件夹再试。";
      return;
    }
    await fetchMatches();
  } catch (reason) {
    error.value = readable(reason, "扫描文件夹");
  } finally {
    rescanning.value = false;
  }
}

async function parse() {
  if (busy.value) return;
  error.value = "";
  const option = currentSource.value;
  if (option.kind === "file") {
    if (!fileContent.value) {
      error.value = "请先选择一个歌单文件（m3u / pls / csv / json / cue / txt）。";
      return;
    }
    busy.value = "parse";
    try {
      const result = await playlistImportFile(fileName.value, fileContent.value);
      if (adopted(result)) await fetchMatches();
    } catch (reason) {
      error.value = readable(reason, "读取歌单文件");
    } finally {
      busy.value = null;
    }
    return;
  }
  const value = input.value.trim();
  if (!value) {
    error.value =
      option.kind === "text"
        ? "请先粘贴歌单文本，每行一首。"
        : `请填写${option.label}的歌单链接或 ID。`;
    return;
  }
  busy.value = "parse";
  try {
    const result = await playlistImportFetch(source.value, value);
    if (adopted(result)) await fetchMatches();
  } catch (reason) {
    error.value = readable(reason, "抓取歌单");
  } finally {
    busy.value = null;
  }
}

async function readFile(event: Event) {
  const element = event.target as HTMLInputElement;
  const file = element.files?.[0];
  element.value = "";
  if (!file) return;
  error.value = "";
  if (file.size > 2 * 1024 * 1024) {
    fileName.value = "";
    fileContent.value = "";
    error.value = "歌单文件超过 2 MB，请精简后再导入。";
    return;
  }
  try {
    const text = await file.text();
    fileName.value = file.name;
    fileContent.value = text;
    playlist.value = null;
    matches.value = [];
    selected.value = [];
    manualIds.value = {};
  } catch (reason) {
    error.value = readable(reason, "读取文件");
  }
}

function pickSource(id: string) {
  if (source.value === id || busy.value) return;
  source.value = id;
  input.value = "";
  error.value = "";
  void nextTick(() => {
    if (currentSource.value.kind === "file") fileInput.value?.focus();
    else firstInput.value?.focus();
  });
}

function reset() {
  playlist.value = null;
  matches.value = [];
  selected.value = [];
  manualIds.value = {};
  manualOpen.value = null;
  onlyUnmatched.value = false;
  name.value = "";
  error.value = "";
  void nextTick(() => firstInput.value?.focus());
}

function toggle(index: number, checked: boolean) {
  selected.value[index] = checked;
}

function openManual(index: number) {
  manualOpen.value = index;
  manualQuery.value = "";
  void nextTick(() => {
    document.getElementById(`manual-search-${index}`)?.focus();
  });
}

function pickManual(index: number, id: string) {
  manualIds.value = { ...manualIds.value, [index]: id };
  selected.value[index] = true;
  manualOpen.value = null;
  error.value = "";
}

function clearManual(index: number) {
  const next = { ...manualIds.value };
  delete next[index];
  manualIds.value = next;
  selected.value[index] = false;
}

function scorePercent(match: ImportMatch | null): number | null {
  if (!match || match.song_id == null) return null;
  const raw = Number(match.score);
  if (!Number.isFinite(raw)) return null;
  const percent = raw <= 1 ? raw * 100 : raw;
  return Math.round(Math.max(0, Math.min(100, percent)));
}

function scoreLabel(match: ImportMatch | null): string {
  const percent = scorePercent(match);
  return percent === null ? "" : `${percent}%`;
}

function scoreTone(match: ImportMatch | null): string {
  const percent = scorePercent(match);
  if (percent === null) return "low";
  return percent >= 70 ? "high" : percent >= 40 ? "mid" : "low";
}

function trapFocus(event: KeyboardEvent) {
  const nodes = Array.from(
    (event.currentTarget as HTMLElement).querySelectorAll<HTMLElement>(
      "button:not(:disabled),input:not(:disabled),select:not(:disabled),textarea:not(:disabled)",
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

function requestClose() {
  if (busy.value === "save") return;
  emit("close");
}

async function create() {
  if (busy.value) return;
  if (!name.value.trim()) {
    error.value = "请给歌单起一个名字。";
    return;
  }
  if (!chosenEntries.value.length) {
    error.value = "至少勾选一首曲目（未匹配的曲目也可以先保存）。";
    return;
  }
  error.value = "";
  busy.value = "save";
  try {
    const saved = await props.savePlaylist(
      name.value.trim(),
      false,
      chosen.value,
      chosenEntries.value,
    );
    if (saved) emit("created", saved);
    else error.value = "歌单没有保存成功，请稍后重试。";
  } catch (reason) {
    error.value = readable(reason, "保存歌单");
  } finally {
    busy.value = null;
  }
}

watch(step, async (value) => {
  if (value !== "review") return;
  await nextTick();
  nameInput.value?.focus();
});

onMounted(() => {
  void nextTick(() => {
    if (currentSource.value.kind === "file") fileInput.value?.focus();
    else firstInput.value?.focus();
  });
});
</script>

<template>
  <div class="modal-backdrop import-backdrop" @click.self="requestClose">
    <section
      class="modal import-modal"
      role="dialog"
      aria-modal="true"
      aria-label="导入歌单"
      @keydown.tab="trapFocus"
    >
      <div class="modal-heading">
        <div>
          <p class="eyebrow">BRING YOUR MIX HOME</p>
          <h2>把外面的歌单，带回这里。</h2>
        </div>
        <button
          class="icon-btn"
          aria-label="关闭导入歌单"
          :disabled="busy === 'save'"
          @click="requestClose"
        >
          <Icon name="close" />
        </button>
      </div>

      <template v-if="step === 'source'">
        <div class="import-sources" role="tablist" aria-label="歌单来源">
          <button
            v-for="option in SOURCES"
            :key="option.id"
            role="tab"
            :aria-selected="source === option.id"
            :class="{ active: source === option.id }"
            :disabled="busy !== null"
            @click="pickSource(option.id)"
          >
            {{ option.label }}
          </button>
        </div>
        <p class="muted import-hint">{{ currentSource.hint }}</p>

        <div v-if="currentSource.kind === 'link'" class="import-field">
          <label for="import-input">{{ currentSource.label }}链接或 ID</label>
          <input
            id="import-input"
            ref="firstInput"
            v-model="input"
            :placeholder="currentSource.placeholder"
            :disabled="busy !== null"
            @keydown.enter.prevent="parse"
          />
        </div>
        <div v-else-if="currentSource.kind === 'text'" class="import-field">
          <label for="import-input">粘贴歌单文本</label>
          <textarea
            id="import-input"
            ref="firstInput"
            v-model="input"
            rows="7"
            placeholder="逃跑计划 - 夜空中最亮的星&#10;朴树 - 平凡之路"
            :disabled="busy !== null"
          />
          <small class="muted">每行一首，解析后会与本地曲库匹配。</small>
        </div>
        <div v-else class="import-field">
          <label for="import-file">选择歌单文件</label>
          <input
            id="import-file"
            ref="fileInput"
            type="file"
            accept=".m3u,.m3u8,.pls,.csv,.json,.cue,.txt"
            :disabled="busy !== null"
            @change="readFile"
          />
          <small v-if="fileName" class="muted">
            已读取 {{ fileName }} · {{ Math.max(1, Math.round(fileContent.length / 1024)) }} KB
          </small>
          <small v-else class="muted">
            文件只在本机解析，不会上传。CUE 暂不支持分轨播放。
          </small>
        </div>

        <p v-if="error" class="job-error" role="alert">{{ error }}</p>
        <div class="import-footer">
          <span class="muted">只会创建歌单，不会自动扫描曲库，也不会自动播放。</span>
          <button
            class="button primary"
            :disabled="
              busy !== null ||
              (currentSource.kind === 'file' ? !fileContent : !input.trim())
            "
            @click="parse"
          >
            <span
              v-if="busy === 'parse' || busy === 'match'"
              class="spinner"
            />
            {{
              busy === 'parse'
                ? '正在解析…'
                : busy === 'match'
                  ? '正在匹配…'
                  : '解析并匹配'
            }}
          </button>
        </div>
      </template>

      <template v-else>
        <div class="import-summary">
          <div>
            <strong>{{ playlist?.name || '未命名歌单' }}</strong>
            <small class="muted">
              共 {{ totalTracks }} 首 · 已匹配 {{ matchedCount }} 首 · 已选
              {{ chosenEntries.length }} 首（{{ pendingCount }} 首待匹配）
            </small>
          </div>
          <button class="text-button" :disabled="busy !== null" @click="reset">
            <Icon name="back" />换一个来源
          </button>
        </div>

        <div
          v-if="gaps && gaps.missing > 0"
          class="info-panel import-gaps"
        >
          <Icon name="info" :size="18" />
          <div>
            <p>
              <strong>"{{ playlist?.name || '这份歌单' }}" 里缺
              {{ gaps.missing }} 首（{{ gaps.artists.length }} 位艺人）。</strong>
              扫一个本地文件夹，扫完我自动重新匹配一次。
            </p>
            <ul v-if="gaps.artists.length" class="gap-artists">
              <li v-for="gap in gaps.artists.slice(0, 5)" :key="gap.artist">
                {{ gap.artist }} · 缺 {{ gap.missing }} 首
                <small v-if="gap.titles.length" class="muted"
                  >（{{ gap.titles.join("、") }}）</small
                >
              </li>
            </ul>
            <p v-if="gaps.artists.length > 5" class="muted">
              还有 {{ gaps.artists.length - 5 }} 位艺人没列出来
            </p>
            <button
              v-if="scanFolder"
              class="button"
              type="button"
              :disabled="rescanning || busy !== null"
              @click="rescanAndMatch"
            >
              <Icon name="folder" />{{
                rescanning ? "正在扫描…" : "选一个文件夹，扫完再匹配"
              }}
            </button>
            <p v-else class="muted">文件夹扫描需要在桌面版使用。</p>
          </div>
        </div>

        <div v-if="playlist?.note" class="info-panel import-note">
          <Icon name="info" :size="18" /><p>{{ playlist.note }}</p>
        </div>
        <div v-if="cueNote" class="info-panel import-note">
          <Icon name="info" :size="18" />
          <p>桌面版暂不支持分轨播放，将以整轨 / 提示方式处理。</p>
        </div>

        <p v-if="busy === 'match'" class="muted import-hint" role="status">
          正在匹配本地曲库…
        </p>
        <div class="import-tools">
          <label class="checkbox-label import-filter">
            <input v-model="onlyUnmatched" type="checkbox" />只看未匹配
          </label>
          <button
            class="text-button"
            :disabled="busy !== null"
            @click="fetchMatches"
          >
            <Icon name="refresh" :size="14" />
            {{ busy === 'match' ? '正在匹配…' : '重新匹配' }}
          </button>
        </div>

        <div class="match-list">
          <div
            v-for="row in visibleRows"
            :key="row.index"
            class="match-row"
            :class="{ unmatched: !row.local }"
          >
            <input
              type="checkbox"
              :checked="row.on"
              :disabled="busy === 'save'"
              :aria-label="`选择 ${row.track.title || '未命名曲目'}`"
              @change="
                toggle(
                  row.index,
                  ($event.target as HTMLInputElement).checked,
                )
              "
            />
            <div class="match-copy">
              <div class="match-origin">
                <strong>{{ row.track.title || '未命名曲目' }}</strong>
                <small>
                  {{ row.track.artist || '未知艺人' }}<template
                    v-if="row.track.album"
                  >
                    · {{ row.track.album }}</template
                  >
                </small>
              </div>
              <div class="match-local">
                <template v-if="row.local">
                  <span class="match-arrow">→</span>
                  <span class="match-picked">
                    {{ row.local.title }}
                    <small>
                      {{ row.local.artist }}<template v-if="row.local.album">
                        · {{ row.local.album }}</template
                      >
                    </small>
                  </span>
                  <span class="match-score" :class="scoreTone(row.match)">
                    {{ scoreLabel(row.match) }}
                  </span>
                </template>
                <template v-else>
                  <span class="match-missing">
                    本地曲库没有找到，可手动指定或稍后在 iOS 端调整。
                  </span>
                  <button
                    class="text-button"
                    :disabled="busy === 'save'"
                    @click="openManual(row.index)"
                  >
                    手动指定
                  </button>
                </template>
              </div>
              <p v-if="row.match?.reason" class="muted match-reason">
                {{ row.match.reason }}
              </p>

              <div v-if="manualOpen === row.index" class="manual-picker">
                <label :for="`manual-search-${row.index}`">在曲库中搜索</label>
                <input
                  :id="`manual-search-${row.index}`"
                  v-model="manualQuery"
                  placeholder="歌名、艺人或专辑"
                  :disabled="busy === 'save'"
                />
                <div class="manual-results">
                  <button
                    v-for="track in manualResults"
                    :key="track.id"
                    @click="pickManual(row.index, track.id)"
                  >
                    <span>{{ track.title }}<small>{{ track.artist }}</small></span>
                    <Icon name="plus" :size="14" />
                  </button>
                  <p v-if="!manualResults.length" class="muted">
                    曲库里没有匹配的歌曲。
                  </p>
                </div>
              </div>
              <button
                v-if="manualIds[row.index]"
                class="text-button danger manual-clear"
                @click="clearManual(row.index)"
              >
                取消手动指定
              </button>
            </div>
          </div>
          <p v-if="!visibleRows.length" class="list-empty">
            {{
              onlyUnmatched
                ? '全部曲目都已匹配到本地曲库。'
                : '没有解析到可展示的曲目。'
            }}
          </p>
        </div>

        <p v-if="error" class="job-error" role="alert">{{ error }}</p>

        <div class="import-create">
          <label for="import-name">歌单名字</label>
          <input
            id="import-name"
            ref="nameInput"
            v-model="name"
            :disabled="busy !== null"
            @keydown.enter.prevent="create"
          />
          <div class="import-footer">
            <span class="muted">
              未匹配的曲目会保存为待匹配条目，可在歌单页查看；曲库更新后自动匹配。
            </span>
            <div class="button-row">
              <button
                class="button"
                :disabled="busy === 'save'"
                @click="requestClose"
              >
                关闭
              </button>
              <button
                class="button primary"
                :disabled="busy !== null || !chosenEntries.length"
                @click="create"
              >
                <span v-if="busy === 'save'" class="spinner" />
                {{
                  busy === 'save'
                    ? '正在保存…'
                    : pendingCount
                      ? '创建歌单（含 ' + pendingCount + ' 首待匹配）'
                      : '创建歌单'
                }}
              </button>
            </div>
          </div>
        </div>
      </template>
    </section>
  </div>
</template>
