<script setup lang="ts">
import { computed } from "vue";
import { artUrl } from "./bridge";
const props = defineProps<{
  path?: string | null;
  seed?: string;
  large?: boolean;
}>();
const palette = computed(() => {
  const n =
    [...(props.seed || "Awake")].reduce((a, c) => a + c.charCodeAt(0), 0) % 4;
  return ["ochre", "forest", "clay", "blue"][n];
});
</script>
<template>
  <div class="artwork" :class="[palette, { large }]">
    <img v-if="path" :src="artUrl(path)" alt="专辑封面" loading="lazy" />
    <template v-else
      ><div class="art-orbit" />
      <div class="art-orbit second" />
      <div class="art-horizon" />
      <span class="art-word"
        >awake<span>PERSONAL SOUND ARCHIVE</span></span
      ></template
    >
  </div>
</template>
