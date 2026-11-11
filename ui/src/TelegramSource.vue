<script setup lang="ts">
import { ref, watch } from "vue";
import { call, desktop } from "./bridge";
const props = defineProps<{ url: string; secret: string; disabled: boolean }>();
const emit = defineEmits<{ selected: [url: string] }>();
interface Catalog {
  chats: { id: string; title: string; kind: string }[];
  folders: { id: string; title: string; chat_ids: string[] }[];
}
const catalog = ref<Catalog | null>(null), selected = ref<string[]>([]);
const busy = ref(false), error = ref(""), limit = ref(1000);
watch(() => [props.url, props.secret], () => { catalog.value = null; selected.value = []; error.value = ""; });
async function browse() {
  busy.value = true; error.value = "";
  const url = props.url, secret = props.secret;
  try {
    const result = await call<Catalog>("telegram_catalog", { req: { url, secret } });
    if (url === props.url && secret === props.secret) catalog.value = result;
  } catch (e) { error.value = String(e); }
  finally { busy.value = false; }
}
async function create() {
  busy.value = true; error.value = "";
  const base = props.url, secret = props.secret;
  try {
    const url = await call<string>("telegram_collection", { req: { url: base, secret, chat_ids: selected.value, message_limit: limit.value } });
    if (base === props.url && secret === props.secret) emit("selected", url);
  } catch (e) { error.value = String(e); }
  finally { busy.value = false; }
}
</script>

<template>
  <section class="telegram-picker" aria-label="选择 Telegram 音频来源" :aria-busy="busy">
    <p class="muted">连接你自己运行的 Telegram 连接器。在连接器设备完成账号登录后，在这里选择频道或收藏夹。</p>
    <button type="button" class="button" :disabled="busy || disabled || !desktop || !url || !secret" @click="browse">{{ busy ? '正在读取…' : '读取频道与聊天文件夹' }}</button>
    <template v-if="catalog">
      <label v-if="catalog.folders.length">从聊天文件夹选择
        <select @change="selected = [...(catalog?.folders.find(f => f.id === ($event.target as HTMLSelectElement).value)?.chat_ids ?? [])]">
          <option value="">手动选择</option>
          <option v-for="folder in catalog.folders" :key="folder.id" :value="folder.id">{{ folder.title }} · {{ folder.chat_ids.length }} 个来源</option>
        </select>
      </label>
      <fieldset class="telegram-chats" :disabled="busy">
        <legend>确认要读取的频道与收藏夹</legend>
        <label v-for="chat in catalog.chats" :key="chat.id" class="checkbox-label"><input v-model="selected" type="checkbox" :value="chat.id" />{{ chat.title }}</label>
      </fieldset>
      <label>每个来源的最近消息范围
        <select v-model.number="limit"><option :value="100">最近 100 条</option><option :value="500">最近 500 条</option><option :value="1000">最近 1000 条</option><option :value="2000">最近 2000 条</option></select>
      </label>
      <p class="muted">已选 {{ selected.length }} 个，最多 20 个。只读取范围内的音频；聊天文件夹之后新增的频道需要再次选择。</p>
      <button class="button" type="button" :disabled="busy || !selected.length || selected.length > 20" @click="create">使用所选来源</button>
    </template>
    <p v-if="error" role="alert" class="job-error">{{ error }}</p>
  </section>
</template>

<style scoped>
.telegram-picker { display: grid; gap: 12px; }
.telegram-chats { display: grid; gap: 12px; max-height: 240px; overflow: auto; padding: 14px; border: 1px solid var(--border); border-radius: 12px; }
.telegram-chats legend { padding: 0 6px; }
</style>
