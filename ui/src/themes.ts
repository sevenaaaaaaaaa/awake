import { ref } from "vue";
export interface Skin {
  version: 1;
  id: string;
  name: string;
  mode: "dark" | "light" | "glass";
  colors: {
    bg: string;
    surface: string;
    raised: string;
    text: string;
    muted: string;
    accent: string;
    onAccent: string;
    border: string;
  };
  radius: number;
  density: "comfortable" | "compact";
  font: "system" | "serif";
  blur: number;
}
export const builtins: Skin[] = [
  {
    version: 1,
    id: "dark",
    name: "黑色 · Obsidian",
    mode: "dark",
    colors: {
      bg: "#0c0d10",
      surface: "#14161b",
      raised: "#20232b",
      text: "#f5f6fa",
      muted: "#a5adbe",
      accent: "#a9bcff",
      onAccent: "#11182f",
      border: "#303540",
    },
    radius: 16,
    density: "comfortable",
    font: "system",
    blur: 0,
  },
  {
    version: 1,
    id: "light",
    name: "白色 · Paper",
    mode: "light",
    colors: {
      bg: "#f6f7fb",
      surface: "#ffffff",
      raised: "#ebedf4",
      text: "#171a24",
      muted: "#596177",
      accent: "#3455d9",
      onAccent: "#ffffff",
      border: "#d7dce8",
    },
    radius: 16,
    density: "comfortable",
    font: "system",
    blur: 0,
  },
  {
    version: 1,
    id: "glass",
    name: "玻璃 · Aurora",
    mode: "glass",
    colors: {
      bg: "#0b1125",
      surface: "#18213b",
      raised: "#27324e",
      text: "#f6f8ff",
      muted: "#b6c2dd",
      accent: "#a7e8df",
      onAccent: "#0b2827",
      border: "#435575",
    },
    radius: 20,
    density: "comfortable",
    font: "system",
    blur: 24,
  },
];
const storage = "awake-appearance-v1";
export const selectedSkin = ref("dark");
export const customSkins = ref<Skin[]>([]);
export const activeSkin = ref<Skin>(builtins[0]);
function luminance(hex: string) {
  const c = [1, 3, 5]
    .map((i) => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map((v) => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));
  return c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722;
}
export function contrast(a: string, b: string) {
  const x = luminance(a),
    y = luminance(b);
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
}
export function validateSkin(value: unknown): Skin {
  const s = value as Skin;
  if (
    !s ||
    s.version !== 1 ||
    typeof s.name !== "string" ||
    !s.name.trim() ||
    s.name.length > 60 ||
    !["dark", "light", "glass"].includes(s.mode)
  )
    throw Error("皮肤需要 version: 1、名称及 dark / light / glass 模式");
  const colors = {} as Skin["colors"];
  for (const key of Object.keys(
    builtins[0].colors,
  ) as (keyof Skin["colors"])[]) {
    const c = s.colors?.[key];
    if (typeof c !== "string" || !/^#[a-f\d]{6}$/i.test(c))
      throw Error(`${key} 需要 #RRGGBB 颜色`);
    colors[key] = c;
  }
  if (
    contrast(colors.text, colors.bg) < 4.5 ||
    contrast(colors.text, colors.surface) < 4.5 ||
    contrast(colors.text, colors.raised) < 4.5 ||
    contrast(colors.muted, colors.bg) < 4.5 ||
    contrast(colors.muted, colors.raised) < 4.5 ||
    contrast(colors.muted, colors.surface) < 4.5 ||
    contrast(colors.accent, colors.surface) < 3 ||
    contrast(colors.onAccent, colors.accent) < 4.5
  )
    throw Error("文字或按钮对比度不足，请调整颜色后再导入");
  if (
    !Number.isFinite(s.radius) ||
    s.radius < 0 ||
    s.radius > 28 ||
    !Number.isFinite(s.blur) ||
    s.blur < 0 ||
    s.blur > 40 ||
    !["comfortable", "compact"].includes(s.density) ||
    !["system", "serif"].includes(s.font)
  )
    throw Error(
      "圆角 0–28、模糊 0–40；密度 comfortable / compact；字体 system / serif",
    );
  return {
    version: 1,
    id:
      typeof s.id === "string" && /^[\w-]{1,70}$/.test(s.id) ? s.id : "custom",
    name: s.name.trim(),
    mode: s.mode,
    colors,
    radius: s.radius,
    density: s.density,
    font: s.font,
    blur: s.blur,
  };
}
export function parseDesign(markdown: string): Skin {
  if (markdown.length > 65536) throw Error("design.md 不能超过 64 KB");
  const block = markdown.match(/```(?:json|awake-skin)\s*\n([\s\S]*?)```/i);
  try {
    return validateSkin(JSON.parse(block ? block[1] : markdown));
  } catch (e) {
    if (e instanceof SyntaxError)
      throw Error("请使用模板中的 JSON 设计区块；说明文字可写在区块外");
    throw e;
  }
}
function persist() {
  try {
    localStorage.setItem(
      storage,
      JSON.stringify({
        selected: selectedSkin.value,
        custom: customSkins.value,
      }),
    );
  } catch {
    throw Error("外观保存失败：本地存储空间不足或不可用");
  }
}
export function applySkin(s: Skin) {
  const root = document.documentElement;
  activeSkin.value = s;
  root.dataset.skin = s.mode;
  root.dataset.density = s.density;
  root.style.colorScheme = s.mode === "light" ? "light" : "dark";
  const mapping: Record<string, string> = {
    bg: "bg",
    surface: "surface",
    raised: "raised",
    text: "text",
    muted: "muted",
    accent: "accent",
    onAccent: "on-accent",
    border: "line",
  };
  for (const [k, v] of Object.entries(s.colors))
    root.style.setProperty("--" + mapping[k], v);
  root.style.setProperty("--dim", s.colors.muted);
  root.style.setProperty("--green", s.colors.accent);
  root.style.setProperty(
    "--accent-hover",
    `color-mix(in srgb, ${s.colors.accent}, ${s.colors.text} 15%)`,
  );
  root.style.setProperty("--radius", s.radius + "px");
  root.style.setProperty("--glass-blur", s.blur + "px");
  root.style.setProperty(
    "--display-font",
    s.font === "serif" ? '"Songti SC", serif' : "inherit",
  );
}
export function chooseSkin(id: string) {
  selectedSkin.value = id;
  const actual =
    id === "system"
      ? matchMedia("(prefers-color-scheme: light)").matches
        ? "light"
        : "dark"
      : id;
  applySkin(
    [...builtins, ...customSkins.value].find((s) => s.id === actual) ||
      builtins[0],
  );
  persist();
}
export function saveSkin(s: Skin) {
  const clean = validateSkin(s);
  clean.id = clean.id.startsWith("custom-")
    ? clean.id
    : "custom-" + crypto.randomUUID();
  customSkins.value = [
    ...customSkins.value.filter((x) => x.id !== clean.id),
    clean,
  ].slice(-30);
  chooseSkin(clean.id);
}
export function removeSkin(id: string) {
  customSkins.value = customSkins.value.filter((x) => x.id !== id);
  if (selectedSkin.value === id) chooseSkin("dark");
  else persist();
}
export function designMarkdown(s: Skin = activeSkin.value) {
  return (
    "# Awake design.md\n\n在 JSON 中描述颜色、圆角、密度与玻璃效果。可以把这份文件交给设计师或 AI 修改，再导入 Awake；不执行 CSS、脚本、外部字体或远程资源。\n\n```json\n" +
    JSON.stringify(s, null, 2) +
    "\n```\n"
  );
}
export function initializeThemes() {
  try {
    const p = JSON.parse(localStorage.getItem(storage) || "{}");
    customSkins.value = (Array.isArray(p.custom) ? p.custom : [])
      .slice(0, 30)
      .map(validateSkin)
      .filter((s: Skin) => s.id.startsWith("custom-"));
    if (typeof p.selected === "string") selectedSkin.value = p.selected;
  } catch {
    customSkins.value = [];
  }
  const id = selectedSkin.value;
  const actual =
    id === "system"
      ? matchMedia("(prefers-color-scheme: light)").matches
        ? "light"
        : "dark"
      : id;
  applySkin(
    [...builtins, ...customSkins.value].find((s) => s.id === actual) ||
      builtins[0],
  );
  matchMedia("(prefers-color-scheme: light)").addEventListener("change", () => {
    if (selectedSkin.value === "system") chooseSkin("system");
  });
}
