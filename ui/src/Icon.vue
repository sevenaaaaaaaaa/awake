<script setup lang="ts">
// 一套线性图标，一个尺寸，一个描边。
// 24×24 视框、stroke 1.5、颜色取当前文字角色 —— 全站不出现第二个图标集。
withDefaults(defineProps<{ name: string; size?: number; stroke?: number }>(), {
  size: 16,
  stroke: 1.5,
});

const PATHS: Record<string, string> = {
  home: '<path d="m3 10 9-7 9 7v10H3Z"/><path d="M9 20v-7h6v7"/>',
  search: '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',
  spark:
    '<path d="m12 2 2.5 7.5L22 12l-7.5 2.5L12 22l-2.5-7.5L2 12l7.5-2.5Z"/>',
  orbit:
    '<circle cx="12" cy="12" r="3"/><ellipse cx="12" cy="12" rx="11" ry="4.5" transform="rotate(-40 12 12)"/><ellipse cx="12" cy="12" rx="11" ry="4.5" transform="rotate(40 12 12)"/>',
  headphones:
    '<path d="M4 14v-3a8 8 0 0 1 16 0v3"/><rect x="3" y="12" width="4" height="8" rx="2"/><rect x="17" y="12" width="4" height="8" rx="2"/>',
  chevron: '<path d="m9 6 6 6-6 6"/>',
  arrow: '<path d="M4 12h16m-6-6 6 6-6 6"/>',
  folder: '<path d="M3 6h7l2 2h9v12H3Z"/><path d="M3 8V4h7l2 2"/>',
  refresh:
    '<path d="M20 7v5h-5M4 17v-5h5"/><path d="M6.3 6.3a8 8 0 0 1 13 3M4.7 14.7a8 8 0 0 0 13 3"/>',
  shield:
    '<path d="m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6Z"/><path d="m8 12 3 3 5-6"/>',
  close: '<path d="m6 6 12 12M6 18 18 6"/>',
  check: '<path d="m5 12 5 5L20 7"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7h.01"/>',

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
  lyrics:
    '<path d="M4 7h9"/><path d="M4 12h6"/><path d="M4 17h11"/><path d="M17 4v11"/><circle cx="17" cy="17" r="2.5"/><path d="M19.5 17V8"/>',
  download: '<path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M4 21h16"/>',
  copy: '<rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v1"/>',
  cast: '<path d="M21 8V6a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v2"/><path d="M21 16v2a2 2 0 0 1-2 2h-7"/><path d="M3 12a9 9 0 0 1 9 9"/><path d="M3 16a5 5 0 0 1 5 5"/><path d="M4 20h.01"/>',
  book: '<path d="M4 4.5h5.5A3.5 3.5 0 0 1 13 8v12a3 3 0 0 0-3-3H4Z"/><path d="M20 4.5h-5.5A3.5 3.5 0 0 0 11 8v12a3 3 0 0 1 3-3h6Z"/>',
  chart: '<path d="M3 21h18"/><path d="M6 21V11"/><path d="M11 21V4"/><path d="M16 21v-7"/>',
  mic: '<rect x="9" y="2" width="6" height="12" rx="3"/><path d="M5 11a7 7 0 0 0 14 0"/><path d="M12 18v3"/><path d="M8 21h8"/>',
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
