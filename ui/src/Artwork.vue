<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { artUrl } from "./bridge";
const props = defineProps<{
  path?: string | null;
  seed?: string;
  large?: boolean;
  styleName?: string;
}>();
const failed = ref(false);
watch(() => props.path, () => failed.value = false);
const palette = computed(() => {
  const n =
    [...(props.seed || "Awake")].reduce((a, c) => ((a * 31) ^ c.charCodeAt(0)) >>> 0, 2166136261) % 4;
  const selected = ({nocturne:"blue",forest:"forest",amber:"ochre",rose:"clay"} as Record<string,string>)[props.styleName || ""];
  if (selected) return selected;
  return ["ochre", "forest", "clay", "blue"][n];
});
</script>
<template>
  <div class="artwork" :class="[palette, { large }]">
    <img v-if="path && !failed" :src="artUrl(path)" alt="音频封面" loading="lazy" @error="failed = true" />
    <template v-else
      ><div class="art-orbit" />
      <div class="art-orbit second" />
      <div class="art-horizon" />
      <div class="art-sun" />
      <span class="art-word"
        >{{ large ? (seed || 'awake').slice(0, 24) : 'awake' }}<span>PERSONAL SOUND ARCHIVE</span></span
      ></template
    >
  </div>
</template>
<style scoped>
.art-sun{position:absolute;width:31%;height:31%;border-radius:50%;left:53%;top:19%;background:radial-gradient(circle at 35% 30%,#fff1cd,#ffd9ad66 60%,transparent 72%);filter:blur(.4px);mix-blend-mode:screen}.artwork{background-image:radial-gradient(ellipse at 25% 15%,#ffedd544,transparent 55%);}.artwork.large .art-word{font-size:clamp(18px,3vw,32px);letter-spacing:-.04em;max-width:80%;line-height:1.2;overflow-wrap:anywhere}.artwork.large .art-word span{font-size:8px;letter-spacing:.16em;margin-top:12px}
</style>
