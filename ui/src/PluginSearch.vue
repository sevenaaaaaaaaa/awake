<script setup lang="ts">
import { nextTick, onMounted, ref } from "vue";
import Icon from "./Icon.vue";
import { call } from "./bridge";
import type { Source } from "./types";
import {
  searchPlugin,
  toPayload,
  type PluginItem,
} from "./plugins";

/**
 * 插件来源的搜索面板：枪弹分离里的「弹」只管定义搜索与解析，
 * 这里负责把搜索结果挑进曲库（locator 保存原始 musicItem，播放时再解析直连地址）。
 */
const props = defineProps<{ source: Source }>();
const emit = defineEmits<{
  close: [];
  toast: [message: string];
  imported: [count: number];
}>();

const query = ref("");
const page = ref(1);
const searching = ref(false);
const importing = ref(false);
const error = ref("");
const items = ref<PluginItem[]>([]);
const isEnd = ref(true);
const searched = ref(false);
const searchInput = ref<HTMLInputElement | null>(null);

function duration(seconds: number): string {
  if (!seconds) return "—";
  const total = Math.round(seconds);
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`;
}

async function search(reset = true) {
  if (searching.value) return;
  if (reset) page.value = 1;
  error.value = "";
  searching.value = true;
  try {
    const result = await searchPlugin(props.source.id, query.value.trim(), page.value);
    items.value = result.items;
    isEnd.value = result.isEnd;
    searched.value = true;
    if (!items.value.length) error.value = "这个来源没有搜到结果，换个关键词试试。";
  } catch (reason) {
    error.value = String(reason).replace(/^Error: /, "");
    items.value = [];
  }
  searching.value = false;
}

async function nextPage() {
  if (isEnd.value || searching.value) return;
  page.value += 1;
  await search(false);
}

async function previousPage() {
  if (page.value <= 1 || searching.value) return;
  page.value -= 1;
  await search(false);
}

async function importItems(list: PluginItem[]) {
  if (!list.length || importing.value) return;
  importing.value = true;
  error.value = "";
  try {
    const added = await call<number>("save_plugin_tracks", {
      sourceId: props.source.id,
      items: list.map(toPayload),
    });
    emit("toast", `已入库 ${added} 首到「${props.source.name}」`);
    emit("imported", added);
  } catch (reason) {
    error.value = String(reason).replace(/^Error: /, "");
  }
  importing.value = false;
}

onMounted(() => {
  void nextTick(() => searchInput.value?.focus());
});
</script>

<template>
  <div class="modal-backdrop plugin-backdrop" @click.self="emit('close')">
    <section
      class="modal plugin-modal"
      role="dialog"
      aria-modal="true"
      aria-label="插件来源搜索"
    >
      <div class="modal-heading">
        <div>
          <p class="eyebrow">PLUGIN SOURCE · 枪弹分离</p>
          <h2>{{ source.name }}：搜索并入库。</h2>
        </div>
        <button class="icon-btn" aria-label="关闭插件搜索" @click="emit('close')">
          <Icon name="close" />
        </button>
      </div>
      <p class="muted plugin-note">
        插件由你导入，搜索与解析都在本机运行；网络请求经本机代发。
        入库只保存曲目信息，播放时再向插件解析直连地址。
      </p>
      <form class="plugin-search-row" @submit.prevent="search(true)">
        <input
          ref="searchInput"
          v-model="query"
          placeholder="歌名 / 艺人 / 专辑"
          aria-label="插件来源搜索关键词"
          :disabled="searching || importing"
        />
        <button class="button primary" type="submit" :disabled="searching || importing">
          <Icon name="search" />{{ searching ? "搜索中…" : "搜索" }}
        </button>
      </form>
      <p v-if="error" class="job-error" role="alert">{{ error }}</p>
      <ul v-if="items.length" class="plugin-results">
        <li v-for="(item, index) in items" :key="`${item.id ?? 'i'}-${index}`">
          <span class="plugin-index">{{ (page - 1) * 20 + index + 1 }}</span>
          <div class="plugin-copy">
            <strong>{{ item.title }}</strong>
            <small>
              {{ item.artist || "未知艺人" }}
              <template v-if="item.album">· {{ item.album }}</template>
              · {{ duration(item.duration) }}
            </small>
          </div>
          <button
            class="button"
            type="button"
            :disabled="importing"
            @click="importItems([item])"
          >
            入库
          </button>
        </li>
      </ul>
      <p v-else-if="searched && !error" class="list-empty">这一页没有结果。</p>
      <div v-if="searched" class="plugin-footer">
        <div class="plugin-pager">
          <button class="text-button" type="button" :disabled="page <= 1 || searching" @click="previousPage">
            上一页
          </button>
          <span class="muted">第 {{ page }} 页</span>
          <button class="text-button" type="button" :disabled="isEnd || searching" @click="nextPage">
            下一页
          </button>
        </div>
        <button
          class="button primary"
          type="button"
          :disabled="!items.length || importing"
          @click="importItems(items)"
        >
          <Icon name="plus" />{{ importing ? "正在入库…" : `导入本页 ${items.length} 首` }}
        </button>
      </div>
    </section>
  </div>
</template>

<style scoped>
.plugin-modal {
  width: min(640px, 92vw);
  max-height: 78vh;
  display: flex;
  flex-direction: column;
}
.plugin-note {
  margin: 4px 0 12px;
  font-size: 12px;
  line-height: 1.6;
}
.plugin-search-row {
  display: flex;
  gap: 8px;
  margin-bottom: 12px;
}
.plugin-search-row input {
  flex: 1;
}
.plugin-results {
  list-style: none;
  margin: 0;
  padding: 0;
  overflow-y: auto;
  flex: 1;
  min-height: 80px;
}
.plugin-results li {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 8px 4px;
  border-bottom: 1px solid color-mix(in srgb, currentColor 8%, transparent);
}
.plugin-index {
  width: 28px;
  text-align: right;
  font-variant-numeric: tabular-nums;
  opacity: 0.5;
  font-size: 12px;
}
.plugin-copy {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 2px;
}
.plugin-copy strong {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.plugin-copy small {
  opacity: 0.65;
}
.plugin-footer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  margin-top: 12px;
}
.plugin-pager {
  display: flex;
  align-items: center;
  gap: 10px;
}
</style>
