<script setup lang="ts">
import { call, desktop } from "./bridge";
import type { Services } from "./types";
import { reactive, ref, onUnmounted } from "vue";
import {
  builtins,
  customSkins,
  selectedSkin,
  activeSkin,
  chooseSkin,
  applySkin,
  saveSkin,
  removeSkin,
  parseDesign,
  designMarkdown,
  type Skin,
} from "./themes";
defineProps<{ services: Services }>();
const aiBusy = ref(false);
const draft = reactive<Skin>(
  structuredClone({
    ...activeSkin.value,
    colors: { ...activeSkin.value.colors },
  }),
);
const design = ref(""),
  error = ref(""),
  message = ref(""),
  preview = ref(false);
onUnmounted(() => {
  if (preview.value) chooseSkin(selectedSkin.value);
});
const labels: Record<string, string> = {
  bg: "页面背景",
  surface: "卡片表面",
  raised: "悬浮层",
  text: "主要文字",
  muted: "次要文字",
  accent: "强调色",
  onAccent: "按钮文字",
  border: "分隔线",
};
function select(id: string) {
  try {
    chooseSkin(id);
    Object.assign(
      draft,
      structuredClone({
        ...activeSkin.value,
        colors: { ...activeSkin.value.colors },
      }),
    );
    preview.value = false;
    error.value = "";
  } catch (e) {
    error.value = String(e);
  }
}
function act(f: () => void) {
  try {
    f();
    error.value = "";
  } catch (e) {
    error.value = String(e);
  }
}
async function generateAI() {
  aiBusy.value = true;
  error.value = "";
  try {
    const result = await call("generate_skin", { markdown: design.value });
    const skin = parseDesign(JSON.stringify(result));
    Object.assign(draft, skin);
    applySkin(skin);
    preview.value = true;
    message.value = "AI 设计已生成预览，通过对比度校验后才会应用；请确认后保存";
  } catch (e) {
    error.value = String(e);
  } finally {
    aiBusy.value = false;
  }
}
function download() {
  const url = URL.createObjectURL(
    new Blob([designMarkdown(activeSkin.value)], { type: "text/markdown" }),
  );
  const a = document.createElement("a");
  a.href = url;
  a.download = "design.md";
  a.click();
  URL.revokeObjectURL(url);
}
async function importFile(event: Event) {
  const input = event.target as HTMLInputElement;
  const file = input.files?.[0];
  if (!file) return;
  try {
    if (file.size > 65536) throw Error("文件不能超过 64 KB");
    design.value = await file.text();
    const skin = parseDesign(design.value);
    Object.assign(draft, skin);
    message.value = "已读取设计，可预览后保存";
    error.value = "";
  } catch (e) {
    error.value = String(e);
  }
  input.value = "";
}
function previewDraft() {
  const skin = parseDesign(JSON.stringify(draft));
  applySkin(skin);
  preview.value = true;
}
function commit() {
  saveSkin({
    ...draft,
    id: draft.id.startsWith("custom-") ? draft.id : "custom",
  });
  Object.assign(draft, activeSkin.value);
  preview.value = false;
  message.value = "皮肤已保存并应用";
}
</script>
<template>
  <div class="page-intro">
    <div>
      <p class="eyebrow">MAKE IT YOURS</p>
      <h1>外观，由你定义。</h1>
      <p>纯粹的黑与白，通透的玻璃，或一份属于你的设计。</p>
    </div>
    <button
      class="button"
      @click="select('system')"
      :aria-pressed="selectedSkin === 'system'"
    >
      跟随系统
    </button>
  </div>
  <div class="skin-grid">
    <button
      v-for="skin in [...builtins, ...customSkins]"
      :key="skin.id"
      class="skin-tile"
      :class="{ chosen: selectedSkin === skin.id }"
      :aria-pressed="selectedSkin === skin.id"
      @click="select(skin.id)"
    >
      <span
        class="skin-mini"
        :style="{
          '--mini-bg': skin.colors.bg,
          '--mini-surface': skin.colors.surface,
          '--mini-accent': skin.colors.accent,
          '--mini-text': skin.colors.text,
        }"
        ><i /><span><b /><b /><em /><b /></span></span
      ><strong>{{ skin.name }}</strong
      ><small>{{
        skin.mode === "glass"
          ? "通透层次与柔和光晕"
          : skin.mode === "light"
            ? "明亮、清晰、轻盈"
            : "中性黑阶与专辑色彩"
      }}</small>
    </button>
  </div>
  <section class="eq-card appearance-editor">
    <div class="section-heading">
      <div>
        <h2>制作你的皮肤</h2>
        <p>颜色、密度、字体和材质，保存后随时切换；导出后也可以分享给社区。</p>
      </div>
      <button class="text-button" @click="download">导出 design.md</button>
    </div>
    <label class="field-label"
      >皮肤名称<input v-model="draft.name" maxlength="60"
    /></label>
    <div class="skin-colors">
      <label v-for="(color, key) in draft.colors" :key="key"
        ><input
          type="color"
          v-model="draft.colors[key]"
          :aria-label="labels[key]"
        /><span>{{ labels[key] }}</span
        ><small>{{ color }}</small></label
      >
    </div>
    <div class="skin-controls">
      <label
        >模式<select v-model="draft.mode">
          <option value="dark">黑色</option>
          <option value="light">白色</option>
          <option value="glass">玻璃</option>
        </select></label
      ><label
        >密度<select v-model="draft.density">
          <option value="comfortable">舒展</option>
          <option value="compact">紧凑</option>
        </select></label
      ><label
        >标题字体<select v-model="draft.font">
          <option value="system">现代无衬线</option>
          <option value="serif">衬线</option>
        </select></label
      ><label
        >圆角 {{ draft.radius
        }}<input
          v-model.number="draft.radius"
          type="range"
          min="0"
          max="28" /></label
      ><label
        >模糊 {{ draft.blur
        }}<input v-model.number="draft.blur" type="range" min="0" max="40"
      /></label>
    </div>
    <div class="theme-actions">
      <button class="button" @click="act(previewDraft)">预览皮肤</button
      ><button class="button primary" @click="act(commit)">保存并应用</button
      ><button v-if="preview" class="text-button" @click="select(selectedSkin)">
        取消预览</button
      ><button
        v-if="selectedSkin.startsWith('custom-')"
        class="text-button"
        @click="
          act(() => {
            removeSkin(selectedSkin);
            select('dark');
          })
        "
      >
        移除此皮肤
      </button>
    </div>
  </section>
  <section class="eq-card">
    <div class="section-heading">
      <div>
        <h2>从 design.md 或社区皮肤生成</h2>
        <p>
          导入设计师、AI 或社区提供的 design.md。文字说明配合 JSON
          设计区块，应用会检查格式与文字对比度。
        </p>
      </div>
      <label class="button"
        >导入文件<input
          type="file"
          accept=".md,.json,.txt"
          class="sr-only"
          @change="importFile"
      /></label>
    </div>
    <textarea
      v-model="design"
      rows="8"
      aria-label="design.md 皮肤内容"
      placeholder="粘贴 design.md 或皮肤 JSON"
      class="skin-source"
    />
    <div class="theme-actions">
      <button class="button" @click="design = designMarkdown()">
        填入当前设计模板</button
      ><button
        class="button primary"
        @click="
          act(() => {
            Object.assign(draft, parseDesign(design));
            previewDraft();
            message = '设计已生成预览，请保存并应用';
          })
        "
      >
        生成预览
      </button>
    </div>
    <div class="theme-actions">
      <button
        class="button"
        :disabled="!desktop || !services.curator || !design.trim() || aiBusy"
        @click="generateAI"
      >
        {{ aiBusy ? "正在解读设计…" : "AI 解读设计文档" }}</button
      ><small class="muted"
        >自由文字设计稿可交给已配置的 AI
        转换。只在点击时发送本页设计文档，生成后先预览。</small
      >
    </div>
    <p class="muted">
      皮肤只改变外观；不会执行代码或加载外部资源。最多保存 30 份自定义皮肤。
    </p>
  </section>
  <p v-if="error" role="alert" class="job-error">{{ error }}</p>
  <p v-if="message" role="status">{{ message }}</p>
</template>
