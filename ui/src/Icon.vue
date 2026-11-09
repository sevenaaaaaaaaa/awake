<script setup lang="ts">
// 一套线性图标，一个尺寸，一个描边。
// 24×24 视框、stroke 1.5、颜色取当前文字角色 —— 全站不出现第二个图标集。
withDefaults(defineProps<{ name: string; size?: number; stroke?: number }>(), {
  size: 16,
  stroke: 1.5,
});

const PATHS: Record<string, string> = {
  disc: '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="2.5"/>',
  list: '<path d="M21 15V6"/><path d="M18.5 18.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5Z"/><path d="M21 6l-9 2"/><path d="M8.5 18.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5Z"/><path d="M12 18V8"/>',
  database:
    '<ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v14c0 1.7 3.6 3 8 3s8-1.3 8-3V5"/><path d="M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/>',
  sliders:
    '<path d="M4 21v-7"/><path d="M4 10V3"/><path d="M12 21v-9"/><path d="M12 8V3"/><path d="M20 21v-5"/><path d="M20 12V3"/><path d="M1 14h6"/><path d="M9 8h6"/><path d="M17 16h6"/>',
  plus: '<path d="M12 5v14"/><path d="M5 12h14"/>',
  play: '<path d="M8 5.2v13.6L19 12 8 5.2Z" fill="currentColor" stroke="none"/>',
  pause:
    '<path d="M9 5v14" stroke-width="2.5"/><path d="M15 5v14" stroke-width="2.5"/>',
  prev: '<path d="M18 5.5v13L8.5 12 18 5.5Z" fill="currentColor" stroke="none"/><path d="M6 5v14"/>',
  next: '<path d="M6 5.5v13L15.5 12 6 5.5Z" fill="currentColor" stroke="none"/><path d="M18 5v14"/>',
  heart:
    '<path d="M12 20.3C12 20.3 3.5 15.4 3.5 9.8A4.3 4.3 0 0 1 12 7.6a4.3 4.3 0 0 1 8.5 2.2c0 5.6-8.5 10.5-8.5 10.5Z"/>',
  volume:
    '<path d="M11 5 6 9H2v6h4l5 4V5Z"/><path d="M15.5 8.5a5 5 0 0 1 0 7"/><path d="M18.5 5.5a9 9 0 0 1 0 13"/>',
  back: '<path d="M15 6l-6 6 6 6"/>',
  music:
    '<path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/>',
  wave: '<path d="M2 12h2l2-6 3 12 3-9 2 5h4"/>',
};
</script>

<template>
  <svg
    class="icon"
    :width="size"
    :height="size"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    :stroke-width="stroke"
    stroke-linecap="round"
    stroke-linejoin="round"
    aria-hidden="true"
    v-html="PATHS[name] ?? ''"
  />
</template>
