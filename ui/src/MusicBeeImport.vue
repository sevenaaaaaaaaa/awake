<script setup lang="ts">
/**
 * MusicBee 导入面板（macOS 桌面）。
 *
 * 与 `awake-cli mbl apply` 同一套核心，界面上只多两件事：
 * 选文件、把数字摆出来让人自己决定要不要写。
 * 面板**不写回 .mbl**；重复点"应用"是安全的（播放次数只增不减）。
 */
import { computed, ref } from "vue";
import { call, desktop } from "./bridge";

interface LocalSourceView {
  id: string;
  name: string;
  root: string;
}

interface MblPreview {
  path: string;
  bytes: number;
  version: number;
  declared: number;
  parsed: number;
  first_path: string;
  suggested_win_root: string;
  sources: LocalSourceView[];
  library_total: number;
  matched: number;
  changed: number;
  case_insensitive: number;
  unmatched: string[];
  unmatched_total: number;
}

interface MblApplied {
  updated: number;
  play_count_raised: number;
  last_played_moved: number;
  added_at_filled: number;
  backup: string | null;
}

const emit = defineEmits<{ imported: [] }>();

const path = ref("");
const winRoot = ref("");
const preview = ref<MblPreview | null>(null);
const applied = ref<MblApplied | null>(null);
const busy = ref(false);
const confirming = ref(false);
const error = ref("");

const canApply = computed(
  () => Boolean(preview.value && preview.value.changed > 0 && !busy.value),
);

function describeBytes(value: number): string {
  if (value > 1024 * 1024) return `${(value / 1024 / 1024).toFixed(1)} MB`;
  return `${Math.round(value / 1024)} KB`;
}

async function pickFile() {
  error.value = "";
  applied.value = null;
  try {
    const chosen = await call<string>("pick_musicbee_library");
    if (!chosen) return;
    path.value = chosen;
    await runPreview();
  } catch (issue) {
    error.value = String(issue);
  }
}

async function runPreview() {
  if (!path.value) return;
  busy.value = true;
  error.value = "";
  confirming.value = false;
  try {
    const data = await call<MblPreview>("musicbee_preview", {
      path: path.value,
      winRoot: winRoot.value,
    });
    preview.value = data;
    if (!winRoot.value) winRoot.value = data.suggested_win_root;
  } catch (issue) {
    preview.value = null;
    error.value = String(issue);
  } finally {
    busy.value = false;
  }
}

async function runApply() {
  if (!preview.value) return;
  if (!confirming.value) {
    confirming.value = true;
    return;
  }
  busy.value = true;
  error.value = "";
  try {
    const result = await call<MblApplied>("musicbee_apply", {
      path: path.value,
      winRoot: winRoot.value,
    });
    applied.value = result;
    confirming.value = false;
    await runPreview();
    // 曲库已经变了：叫外面重新读一次，否则专架/适配报告还是旧数据。
    if (result.updated > 0) emit("imported");
  } catch (issue) {
    error.value = String(issue);
  } finally {
    busy.value = false;
  }
}
</script>

<template>
  <article class="source-card musicbee">
    <span class="source-icon"><Icon name="database" :size="26" /></span>
    <div class="body">
      <span class="subtle-badge">从别的播放器搬过来</span>
      <h2>MusicBee 曲库</h2>
      <p class="lead">
        选 <code>MusicBeeLibrary.mbl</code>，把它记下的播放次数、上次播放与入库时间导入这里。
        只读那个文件，不写回；导入前会先备份曲库。
      </p>

      <p v-if="!desktop" class="hint">这条只有 macOS 桌面版能做，手机端读不到那个文件。</p>

      <div class="row">
        <button class="button primary" :disabled="!desktop || busy" @click="pickFile">
          <Icon name="folder" :size="15" />{{ path ? "换一个 .mbl" : "选择 .mbl 文件" }}
        </button>
        <button class="button" :disabled="!desktop || !path || busy" @click="runPreview">
          重新预览
        </button>
      </div>

      <p v-if="path" class="file">
        {{ path }}<template v-if="preview"> · {{ describeBytes(preview.bytes) }}</template>
      </p>

      <p v-if="busy" class="hint">读取中…</p>
      <p v-if="error" class="job-error">{{ error }}</p>

      <template v-if="preview">
        <dl class="numbers">
          <div><dt>解析</dt><dd>{{ preview.parsed }} 条（声明 {{ preview.declared }}）</dd></div>
          <div><dt>曲库</dt><dd>{{ preview.library_total }} 首</dd></div>
          <div><dt>对得上</dt><dd>{{ preview.matched }} 首</dd></div>
          <div><dt>会改变</dt><dd>{{ preview.changed }} 首</dd></div>
          <div v-if="preview.case_insensitive">
            <dt>忽略大小写</dt><dd>{{ preview.case_insensitive }} 条</dd>
          </div>
          <div v-if="preview.unmatched_total">
            <dt>对不上</dt><dd>{{ preview.unmatched_total }} 条</dd>
          </div>
        </dl>

        <p v-if="preview.first_path" class="hint">
          首条路径：<code>{{ preview.first_path }}</code>
        </p>

        <label class="field">
          <span>Windows 根</span>
          <input v-model="winRoot" type="text" spellcheck="false" @change="runPreview" />
        </label>

        <p v-if="!preview.sources.length" class="hint">
          曲库里还没有本地来源。先把音乐文件夹加成本地来源，导入才有地方落。
        </p>
        <p v-else class="hint">
          落到：<template v-for="(item, index) in preview.sources" :key="item.id">
            <code>{{ item.root }}</code><template v-if="index + 1 < preview.sources.length">、</template>
          </template>
        </p>

        <ul v-if="preview.unmatched.length" class="unmatched">
          <li v-for="item in preview.unmatched.slice(0, 5)" :key="item">{{ item }}</li>
          <li v-if="preview.unmatched_total > 5">还有 {{ preview.unmatched_total - 5 }} 条…</li>
        </ul>

        <p v-if="!preview.changed" class="hint">没有需要改的曲目——这份 .mbl 与曲库已经一致。</p>

        <button
          v-else
          class="button"
          :class="{ primary: confirming }"
          :disabled="!canApply"
          @click="runApply"
        >
          {{ confirming ? "再点一次确认写入" : `写入这 ${preview.changed} 首` }}
        </button>
      </template>

      <p v-if="applied" class="applied">
        已写入 {{ applied.updated }} 首 · 播放次数 {{ applied.play_count_raised }} ·
        上次播放 {{ applied.last_played_moved }} · 入库时间 {{ applied.added_at_filled }}
        <br v-if="applied.backup" />
        <small v-if="applied.backup">写入前备份：{{ applied.backup }}</small>
        <small v-else>没有需要写入的曲目</small>
      </p>
    </div>
  </article>
</template>

<style scoped>
.musicbee .body {
  display: grid;
  gap: 10px;
}
.musicbee h2 {
  margin: 0;
  font-size: 17px;
}
.lead,
.hint,
.file {
  margin: 0;
  color: var(--text-dim);
  font-size: 13px;
  line-height: 1.6;
}
.file {
  color: var(--text-muted);
  word-break: break-all;
}
.row {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
}
.numbers {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
  gap: 8px;
  margin: 4px 0;
  padding: 12px;
  border: 1px solid var(--line);
  border-radius: 10px;
  background: var(--raised);
}
.numbers dt {
  color: var(--text-muted);
  font-size: 12px;
}
.numbers dd {
  margin: 2px 0 0;
  font-size: 15px;
  font-weight: 600;
}
.field {
  display: grid;
  gap: 4px;
  font-size: 12px;
  color: var(--text-muted);
}
.field input {
  padding: 8px 10px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--surface);
  color: var(--text);
  font-family: var(--mono);
  font-size: 13px;
}
.field input:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 1px;
}
.unmatched {
  margin: 0;
  padding-left: 18px;
  color: var(--text-muted);
  font-size: 12px;
}
.applied {
  margin: 0;
  padding: 10px 12px;
  border-radius: 10px;
  background: var(--raised);
  color: var(--text);
  font-size: 13px;
}
code {
  font-family: var(--mono);
  font-size: 12px;
}
</style>
