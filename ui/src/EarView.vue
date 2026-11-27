<script setup lang="ts">
/**
 * 耳形：整屏就是一只耳朵。31 段 EQ 画成耳蜗螺旋（内圈低频、外圈高频），
 * 四个动作直接长在它上面：按住=松开成原样（真旁路，App 的 beginBypass），
 * 拖动=捏那一段（真写 set_eq_curve），点中心=说（走 suggest_curve → 自动应用），
 * 轨道节点=接下来听。没有曲目时耳朵睡着。
 * 几何在 earShape.ts（有单测）；本组件只管画与转发，不自己判断「能不能放」。
 */
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import type { EarPick } from "./types";
import {
  BANDS,
  EQ_FREQS,
  RING,
  THETA_MAX,
  bandExtremes,
  bandTheta,
  baseRadius,
  freqLong,
  locateBand,
  polar,
  spiralPaths,
} from "./earShape";

const props = defineProps<{
  gains: number[];
  bypassed: boolean;
  ask: boolean;
  busy: boolean;
  track: { title: string; artist: string } | null;
  position: number;
  duration: number;
  picks: EarPick[];
  source: string;
  headphone: string;
  prior: string;
  summary: string;
  staleHint: string;
}>();

const emit = defineEmits<{
  hold: [];
  release: [heldMs: number];
  vote: [answer: "adapted" | "raw"];
  band: [index: number, gain: number];
  bandEnd: [];
  say: [text: string];
  pick: [pick: EarPick];
  goList: [];
}>();

const CX = 840;
const CY = 530;
const NS = "http://www.w3.org/2000/svg";
const svg = ref<SVGSVGElement | null>(null);
const sayOpen = ref(false);
const sayText = ref("");

type Mode = "sleep" | "play" | "hold" | "ask" | "say";
const mode = computed<Mode>(() => {
  if (props.ask) return "ask";
  if (sayOpen.value) return "say";
  if (props.bypassed) return "hold";
  return props.track ? "play" : "sleep";
});

const fmt = (sec: number) => {
  const s = Math.max(0, Math.round(sec));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
};

// ── 静态节点：点、刻度、峰标、轨道、投票、说菜单 ──
const dotEls: SVGCircleElement[] = [];
const tickEls: SVGTextElement[] = [];
const TICK_AT = [50, 100, 200, 500, 1000, 2000, 5000, 10000];
const peakEls: SVGTextElement[] = [];
const nodesG = ref<SVGGElement | null>(null);
const votesG = ref<SVGGElement | null>(null);
const sayG = ref<SVGGElement | null>(null);
const sayInput = ref<HTMLInputElement | null>(null);
const tipG = ref<SVGGElement | null>(null);
const tipT = ref<SVGTextElement | null>(null);
const tipS = ref<SVGTextElement | null>(null);

function el(name: string, attrs: Record<string, string | number>): SVGElement {
  const e = document.createElementNS(NS, name);
  for (const k in attrs) e.setAttribute(k, String(attrs[k]));
  return e;
}

const ribbonBoost = ref<SVGPathElement | null>(null);
const ribbonCut = ref<SVGPathElement | null>(null);
const glowBoost = ref<SVGPathElement | null>(null);
const baselineEl = ref<SVGPathElement | null>(null);
const baselineHit = ref<SVGPathElement | null>(null);
const progressEl = ref<SVGPathElement | null>(null);
const c1 = ref<SVGTextElement | null>(null);
const c2 = ref<SVGTextElement | null>(null);
const c3 = ref<SVGTextElement | null>(null);
const readout = ref<SVGTextElement | null>(null);

const NODE_ANGLE = [180, 236, 304]; // 三个「接下来」节点，均匀错开、避开顶部进度起点
const PILLS: Array<{ a: number; t: string; phrase: string }> = [
  { a: 320, t: "更亮", phrase: "更亮一点" },
  { a: 40, t: "人声", phrase: "人声更靠前" },
  { a: 140, t: "收紧", phrase: "低频收紧" },
  { a: 250, t: "太吵", phrase: "太吵了" },
];

onMounted(() => {
  const g = svg.value!;
  for (let i = 0; i < BANDS; i++) {
    const c = el("circle", { fill: "#f7f8fa" });
    g.querySelector("#dots")!.appendChild(c);
    dotEls.push(c as SVGCircleElement);
  }
  for (const f of TICK_AT) {
    const t = document.createElementNS(NS, "text");
    t.textContent = f >= 1000 ? f / 1000 + "k" : String(f);
    g.querySelector("#ticks")!.appendChild(t);
    tickEls.push(t as SVGTextElement);
  }
  for (let i = 0; i < 2; i++) {
    const t = document.createElementNS(NS, "text");
    t.setAttribute("text-anchor", "middle");
    g.querySelector("#peaks")!.appendChild(t);
    peakEls.push(t as SVGTextElement);
  }
  rebuildNodes();
  // 说菜单（中心四词）
  PILLS.forEach((p) => {
    const a = (p.a * Math.PI) / 180;
    const x = CX + 74 * Math.cos(a);
    const y = CY + 74 * Math.sin(a);
    const grp = el("g", { class: "pill" });
    grp.appendChild(el("rect", { x: x - 27, y: y - 13, width: 54, height: 26, rx: 13 }));
    const t = document.createElementNS(NS, "text");
    t.setAttribute("x", String(x));
    t.setAttribute("y", String(y + 4.5));
    t.setAttribute("text-anchor", "middle");
    t.setAttribute("class", "pill-t");
    t.textContent = p.t;
    grp.appendChild(t);
    grp.addEventListener("click", (e) => {
      e.stopPropagation();
      submitSay(p.phrase);
    });
    sayG.value!.appendChild(grp);
  });
  // 投票（点形状作答）
  [
    ["adapted", "适配"],
    ["raw", "原样"],
  ].forEach(([v, label], i) => {
    const grp = el("g", { class: "vote" });
    grp.appendChild(
      el("rect", {
        x: -25,
        y: -13,
        width: 50,
        height: 26,
        rx: 13,
        class: i === 0 ? "vote-a" : "vote-r",
      }),
    );
    const t = document.createElementNS(NS, "text");
    t.setAttribute("y", "4.5");
    t.setAttribute("text-anchor", "middle");
    t.setAttribute("class", i === 0 ? "vote-at" : "vote-rt");
    t.textContent = label;
    grp.appendChild(t);
    grp.addEventListener("click", (e) => {
      e.stopPropagation();
      emit("vote", v as "adapted" | "raw");
    });
    votesG.value!.appendChild(grp);
  });

  drawU = 0;
  raf = requestAnimationFrame(frame);
  window.addEventListener("keydown", onKey);
});

onBeforeUnmount(() => {
  if (raf) cancelAnimationFrame(raf);
  window.removeEventListener("keydown", onKey);
});

/** 轨道节点随队列变化重建（清空重画，三个以内）。 */
function rebuildNodes() {
  const host = nodesG.value;
  if (!host) return;
  while (host.firstChild) host.removeChild(host.firstChild);
  props.picks.forEach((p, i) => {
    const a = ((NODE_ANGLE[i] ?? 20) * Math.PI) / 180;
    const x = CX + RING * Math.cos(a);
    const y = CY + RING * Math.sin(a);
    const end = Math.cos(a) < -0.2;
    const grp = el("g", { class: "node" });
    grp.appendChild(el("circle", { cx: x, cy: y, r: 14, fill: "transparent" }));
    grp.appendChild(el("circle", { cx: x, cy: y, r: 4.5, class: "node-dot" }));
    const t1 = document.createElementNS(NS, "text");
    t1.setAttribute("x", String(x + (end ? -16 : 16)));
    t1.setAttribute("y", String(y - 2));
    t1.setAttribute("text-anchor", end ? "end" : "start");
    t1.setAttribute("class", "node-title");
    t1.textContent = p.title;
    const t2 = document.createElementNS(NS, "text");
    t2.setAttribute("x", String(x + (end ? -16 : 16)));
    t2.setAttribute("y", String(y + 14));
    t2.setAttribute("text-anchor", end ? "end" : "start");
    t2.setAttribute("class", "node-sub");
    t2.textContent = p.why;
    grp.appendChild(t1);
    grp.appendChild(t2);
    grp.addEventListener("click", (e) => {
      e.stopPropagation();
      emit("pick", p);
    });
    host.appendChild(grp);
  });
}
watch(() => props.picks, rebuildNodes, { deep: true });

function arcPath(radius: number, a0: number, a1: number): string {
  const x0 = CX + radius * Math.cos(a0);
  const y0 = CY + radius * Math.sin(a0);
  const x1 = CX + radius * Math.cos(a1);
  const y1 = CY + radius * Math.sin(a1);
  return `M${x0.toFixed(1)} ${y0.toFixed(1)} A${radius} ${radius} 0 ${a1 - a0 > Math.PI ? 1 : 0} 1 ${x1.toFixed(1)} ${y1.toFixed(1)}`;
}

// ── 呼吸与入场 ──
let raf = 0;
let drawU = 0;
let drawnFor = "";
const t0 = performance.now();
watch(
  () => props.track?.title,
  (t) => {
    if (t && t !== drawnFor) {
      drawU = 0;
      drawnFor = t;
    }
  },
);

function wobble(theta: number, now: number): number {
  if (mode.value === "sleep")
    return 1.6 * Math.sin(theta * 2.2 + now * 0.0007);
  if (mode.value === "play")
    return (
      3.2 *
      (0.6 * Math.sin(theta * 5.3 + now * 0.0021) +
        0.4 * Math.sin(theta * 11.7 - now * 0.0034 + 1.3))
    );
  return 0;
}

function render(now: number) {
  const m = mode.value;
  const k = m === "hold" ? 1 - holdU.value : 1;
  const tMax = THETA_MAX * (1 - Math.pow(1 - drawU, 3));
  const paths = spiralPaths(props.gains, CX, CY, tMax, k);
  // 呼吸叠加在色带上：把 wobble 并进位移，重画一遍 boost/cut。
  if (paths.boost || paths.cut) {
    const boost: string[] = [];
    const cut: string[] = [];
    const steps = 240;
    const EPS = 0.05;
    let prevB: [number, number] | null = null;
    let prevD: [number, number] | null = null;
    let prevG = 0;
    for (let s = 0; s <= steps; s++) {
      const theta = tMax * (s / steps);
      const g = sampleLive(theta) * k;
      const b = polar(theta, baseRadius(theta), CX, CY);
      const d = polar(
        theta,
        Math.max(baseRadius(theta) + 13 * g + wobble(theta, now) * (m === "hold" ? 0 : 1), baseRadius(theta) * 0.5),
        CX,
        CY,
      );
      if (prevB && prevD && (Math.abs(g) > EPS || Math.abs(prevG) > EPS)) {
        const A = prevB.join(" ");
        const B = prevD.join(" ");
        const C = d.join(" ");
        const D = b.join(" ");
        if ((prevG >= 0) === (g >= 0)) {
          (g >= 0 ? boost : cut).push(`M${A}L${B}L${C}L${D}Z`);
        } else {
          (prevG >= 0 ? boost : cut).push(`M${A}L${B}L${D}Z`);
          (prevG >= 0 ? boost : cut).push(`M${A}L${C}L${D}Z`);
        }
      }
      prevB = b;
      prevD = d;
      prevG = g;
    }
    ribbonBoost.value?.setAttribute("d", boost.join(""));
    glowBoost.value?.setAttribute("d", boost.join(""));
    ribbonCut.value?.setAttribute("d", cut.join(""));
  } else {
    ribbonBoost.value?.setAttribute("d", "");
    glowBoost.value?.setAttribute("d", "");
    ribbonCut.value?.setAttribute("d", "");
  }
  baselineEl.value?.setAttribute("d", paths.baseline);
  baselineHit.value?.setAttribute("d", paths.baseline);
  glowBoost.value?.setAttribute("opacity", m === "sleep" ? "0.25" : "0.9");
  baselineEl.value?.setAttribute(
    "stroke",
    m === "ask" ? "rgba(199,210,254,.85)" : "rgba(247,248,250,.16)",
  );
  baselineEl.value?.setAttribute("stroke-width", m === "ask" ? "2" : "1");
  baselineEl.value?.setAttribute(
    "stroke-dasharray",
    m === "ask" ? "7 5" : "none",
  );

  // 进度环
  const frac = props.duration > 0 ? Math.min(1, props.position / props.duration) : 0;
  progressEl.value?.setAttribute(
    "d",
    frac > 0.005
      ? arcPath(RING, -Math.PI / 2, -Math.PI / 2 + frac * 2 * Math.PI)
      : "M0 0",
  );

  // 点与刻度
  const ex = bandExtremes(props.gains.map((v) => v * k));
  const peakTs: number[] = [];
  if (ex && tMax >= THETA_MAX) {
    if (Math.abs(ex.max.v) >= 0.6) peakTs.push(bandTheta(ex.max.i));
    if (Math.abs(ex.min.v) >= 0.6) peakTs.push(bandTheta(ex.min.i));
  }
  for (let i = 0; i < BANDS; i++) {
    const theta = bandTheta(i);
    const on = theta <= tMax;
    const r = Math.max(baseRadius(theta) + 13 * props.gains[i] * k, baseRadius(theta) * 0.5);
    const [x, y] = polar(theta, r, CX, CY);
    const d = dotEls[i];
    d.setAttribute("cx", x.toFixed(1));
    d.setAttribute("cy", y.toFixed(1));
    d.setAttribute("r", (2.3 + Math.abs(props.gains[i]) * 0.72).toFixed(2));
    d.setAttribute("opacity", on ? "0.55" : "0");
  }
  TICK_AT.forEach((f) => {
    const i = EQ_FREQS.indexOf(f);
    const theta = bandTheta(i);
    const c = Math.cos(theta + ((135 - 288) * Math.PI) / 180);
    const r = Math.max(baseRadius(theta) + 13 * props.gains[i] * k, baseRadius(theta) * 0.5) + 18;
    const [x, y] = polar(theta, r, CX, CY);
    const t = tickEls[TICK_AT.indexOf(f)];
    t.setAttribute("x", x.toFixed(1));
    t.setAttribute("y", (y + 3.5).toFixed(1));
    t.setAttribute("text-anchor", c > 0.3 ? "start" : c < -0.3 ? "end" : "middle");
    t.setAttribute("opacity", theta > tMax || peakTs.some((pk) => Math.abs(pk - theta) < 0.24) ? "0" : "1");
  });
  peakG.setAttribute("opacity", tMax >= THETA_MAX && m !== "sleep" && m !== "hold" ? "1" : "0");
  if (ex && peakG.getAttribute("opacity") === "1") {
    [
      [ex.max, 0],
      [ex.min, 1],
    ].forEach(([p, idx]) => {
      const t = peakEls[idx as number];
      const { i, v } = p as { i: number; v: number };
      if (Math.abs(v) < 0.6) {
        t.setAttribute("opacity", "0");
        return;
      }
      const theta = bandTheta(i);
      const [x, y] = polar(
        theta + 0.13,
        Math.max(baseRadius(theta) + 13 * v, baseRadius(theta) * 0.5) + (v > 0 ? 15 : -15),
        CX,
        CY,
      );
      t.setAttribute("opacity", "1");
      t.setAttribute("x", x.toFixed(1));
      t.setAttribute("y", (y + 3.5).toFixed(1));
      t.setAttribute("fill", v > 0 ? "#c7d2fe" : "#9aa0a8");
      t.textContent = (v > 0 ? "+" : "−") + Math.abs(v).toFixed(1);
    });
  }

  // 中心文案
  const T: Record<Mode, [string, string, string]> = {
    play: [
      props.track?.title ?? "",
      props.track ? `${props.track.artist} · ${fmt(props.position)} / ${fmt(props.duration)}` : "",
      props.busy ? "搭子在调…" : props.summary,
    ],
    hold: ["原样", "松手，回到为你调的那条", ""],
    ask: ["哪一个是你要的？", "点形状作答", ""],
    say: ["", "", props.busy ? "搭子在调…" : "或者挑一个词"],
    sleep: ["耳朵在睡。", "放一首，唤醒它", ""],
  };
  const lines = T[m];
  c1.value!.textContent = lines[0];
  c2.value!.textContent = lines[1];
  c3.value!.textContent = lines[2];

  // 右下读数
  readout.value!.textContent =
    m === "hold"
      ? "EQ 旁路 · 平直输出"
      : ex
        ? `峰 +${ex.max.v.toFixed(1)} dB · ${freqLong(EQ_FREQS[ex.max.i])}　谷 −${Math.abs(ex.min.v).toFixed(1)} dB · ${freqLong(EQ_FREQS[ex.min.i])}`
        : "平直 · 没有做适配";

  // 投票位：适配贴着最大的那段，原样贴着基线
  if (m === "ask") {
    const bi = ex ? ex.max.i : 8;
    const theta = bandTheta(bi);
    const [ax, ay] = polar(theta + 0.1, baseRadius(theta) + 13 * props.gains[bi] + 30, CX, CY);
    const [rx, ry] = polar(bandTheta(2), baseRadius(bandTheta(2)) - 26, CX, CY);
    votesG.value!.children[0].setAttribute("transform", `translate(${ax.toFixed(1)} ${ay.toFixed(1)})`);
    votesG.value!.children[1].setAttribute("transform", `translate(${rx.toFixed(1)} ${ry.toFixed(1)})`);
  }
}

/** rAF 里用的采样：呼吸叠加在 props.gains 的平滑曲线上。 */
function sampleLive(theta: number): number {
  const gains = props.gains;
  const pos = (theta / THETA_MAX) * (gains.length - 1);
  const i = Math.min(gains.length - 2, Math.max(0, Math.floor(pos)));
  const u = pos - i;
  const p0 = gains[Math.max(i - 1, 0)];
  const p1 = gains[i];
  const p2 = gains[i + 1];
  const p3 = gains[Math.min(i + 2, gains.length - 1)];
  return (
    0.5 *
    ((2 * p1) +
      (-p0 + p2) * u +
      (2 * p0 - 5 * p1 + 4 * p2 - p3) * u * u +
      (-p0 + 3 * p1 - 3 * p2 + p3) * u * u * u)
  );
}

const peakG = { setAttribute(k: string, v: string) { svg.value?.querySelector("#peaks")?.setAttribute(k, v); }, getAttribute(k: string) { return svg.value?.querySelector("#peaks")?.getAttribute(k) ?? "0"; } };

let holdU = ref(0);
let holdTarget = 0;
function frame(now: number) {
  const dt = Math.min(0.05, (now - last) / 1000 || 0.016);
  last = now;
  holdU.value += (holdTarget - holdU.value) * Math.min(1, dt * 14);
  if (drawU < 1) drawU = Math.min(1, (now - t0 - 150) / 1100);
  render(now);
  raf = requestAnimationFrame(frame);
}
let last = 0;

// ── 指针交互 ──
let down: { x: number; y: number; t: number } | null = null;
let dragging = false;
let lastBandEmit = 0;
let pendingBand: { i: number; g: number } | null = null;

function toSvg(e: PointerEvent): [number, number] {
  const m = svg.value!.getScreenCTM()!;
  const p = new DOMPoint(e.clientX, e.clientY).matrixTransform(m.inverse());
  return [p.x, p.y];
}

function onPointerDown(e: PointerEvent) {
  if ((e.target as Element).closest(".pill, .node, .vote")) return;
  const [x, y] = toSvg(e);
  if (sayOpen.value) {
    if (Math.hypot(x - CX, y - CY) > 130) {
      sayOpen.value = false;
      sayText.value = "";
    }
    return;
  }
  if (mode.value === "ask") {
    if (e.target === ribbonBoost.value || e.target === ribbonCut.value || e.target === glowBoost.value)
      emit("vote", "adapted");
    else if (e.target === baselineHit.value) emit("vote", "raw");
    return;
  }
  if (mode.value === "sleep") return;
  if (Math.hypot(x - CX, y - CY) < 95) {
    sayOpen.value = true;
    setTimeout(() => sayInput.value?.focus(), 40);
    return;
  }
  svg.value!.setPointerCapture(e.pointerId);
  down = { x: e.clientX, y: e.clientY, t: performance.now() };
  dragging = false;
  emit("hold");
}

function onPointerMove(e: PointerEvent) {
  if (down) {
    if (!dragging && Math.hypot(e.clientX - down.x, e.clientY - down.y) > 7) {
      dragging = true;
      holdTarget = 0;
      emit("release", 0); // 拖动不是听辨：立刻收回旁路
    }
    if (dragging && !props.bypassed) {
      const [x, y] = toSvg(e);
      const loc = locateBand(x, y, CX, CY);
      pendingBand = { i: loc.index, g: loc.gain };
      const nowMs = performance.now();
      if (nowMs - lastBandEmit > 80) {
        lastBandEmit = nowMs;
        emit("band", pendingBand.i, pendingBand.g);
      }
    }
    return;
  }
  if (mode.value !== "play") return;
  const [x, y] = toSvg(e);
  const loc = locateBand(x, y, CX, CY);
  if (loc.near < 0.085) {
    const i = loc.index;
    const v = props.gains[i];
    const t = `${(v > 0 ? "+" : v < 0 ? "−" : "±") + Math.abs(v).toFixed(1)} dB · ${freqLong(EQ_FREQS[i])}`;
    const s =
      props.source === "song"
        ? `这首歌的记忆 · ${props.headphone || "未识别耳机"}`
        : props.staleHint || (props.headphone ? `链路曲线 · ${props.headphone}` : "没有依据：手动曲线");
    showTip(x + 22, y + 22, t, s);
  } else {
    hideTip();
  }
}

function onPointerUp() {
  if (!down) return;
  const heldMs = performance.now() - down.t;
  const wasHold = !dragging && heldMs > 140;
  down = null;
  dragging = false;
  holdTarget = 0;
  if (pendingBand) {
    emit("band", pendingBand.i, pendingBand.g);
    emit("bandEnd");
    pendingBand = null;
  }
  emit("release", wasHold ? heldMs : 0);
}

function submitSay(text: string) {
  const v = text.trim();
  if (!v || props.busy) return;
  sayOpen.value = false;
  sayText.value = "";
  emit("say", v);
}

function onKey(e: KeyboardEvent) {
  if (e.key === "Escape" && sayOpen.value) {
    sayOpen.value = false;
    sayText.value = "";
  }
}

// 悬停依据
let tipTimer = 0;
function showTip(x: number, y: number, t: string, s: string) {
  const g = tipG.value!;
  g.setAttribute("opacity", "1");
  g.setAttribute(
    "transform",
    `translate(${Math.min(Math.max(x, 12), 1400).toFixed(1)} ${Math.min(Math.max(y, 12), 960).toFixed(1)})`,
  );
  tipT.value!.textContent = t;
  tipS.value!.textContent = s;
  clearTimeout(tipTimer);
  tipTimer = window.setTimeout(hideTip, 3200);
}
function hideTip() {
  tipG.value?.setAttribute("opacity", "0");
}
</script>

<template>
  <svg
    ref="svg"
    viewBox="0 0 1680 1050"
    preserveAspectRatio="xMidYMid meet"
    class="ear-svg"
    role="img"
    aria-label="你的耳形：按住听原样，拖动捏一段，点中心说一句"
    @pointerdown="onPointerDown"
    @pointermove="onPointerMove"
    @pointerup="onPointerUp"
    @pointercancel="onPointerUp"
    @pointerleave="hideTip"
    @dblclick.prevent
  >
    <defs>
      <filter id="earGlow" x="-20%" y="-20%" width="140%" height="140%">
        <feGaussianBlur stdDeviation="12" />
      </filter>
      <radialGradient id="earHalo" cx="50%" cy="50%" r="50%">
        <stop offset="0" class="halo-0" />
        <stop offset="1" class="halo-1" />
      </radialGradient>
    </defs>
    <rect width="1680" height="1050" class="bg" />
    <circle :cx="840" cy="530" r="620" fill="url(#earHalo)" />

    <circle :cx="840" cy="530" :r="448" class="ring" />
    <path ref="progressEl" class="progress" />
    <g ref="nodesG"></g>

    <path ref="glowBoost" class="ribbon-boost glow" filter="url(#earGlow)" />
    <path ref="ribbonCut" class="ribbon-cut" />
    <path ref="ribbonBoost" class="ribbon-boost" />
    <path ref="baselineEl" class="baseline" />
    <path ref="baselineHit" class="hit" fill="none" stroke="transparent" stroke-width="24" />
    <g id="dots"></g>
    <g id="ticks" class="tick"></g>
    <g id="peaks" class="peak"></g>

    <g ref="votesG" class="votes" :opacity="mode === 'ask' ? 1 : 0"></g>
    <g ref="sayG" class="saymenu" :opacity="sayOpen ? 1 : 0"></g>
    <input
      ref="sayInput"
      v-model="sayText"
      class="say-input"
      :class="{ on: sayOpen }"
      placeholder="说一句…"
      autocomplete="off"
      @keydown.enter.prevent="submitSay(sayText)"
    />

    <text ref="c1" :x="840" y="516" text-anchor="middle" class="c1"></text>
    <text ref="c2" :x="840" y="536" text-anchor="middle" class="c2"></text>
    <text ref="c3" :x="840" y="557" text-anchor="middle" class="c3"></text>

    <g ref="tipG" class="tip" opacity="0">
      <rect width="250" height="46" rx="10" class="tip-box" />
      <text ref="tipT" x="14" y="19" class="tip-t"></text>
      <text ref="tipS" x="14" y="35" class="tip-s"></text>
    </g>

    <path
      d="M781 22c0 0 8-10 16-10s14 6 14 14c0 7-4 9-8 12s-6 5-6 9"
      transform="translate(-748 8) scale(0.62)"
      class="glyph"
    />
    <text x="76" y="44" class="wordmark">AWAKE</text>
    <text x="152" y="44" class="wordmark-sub">耳形</text>
    <circle cx="1420" cy="40" r="3" class="live-dot" />
    <text x="1644" y="44" text-anchor="end" class="status">
      {{ (headphone || '未识别耳机') + ' · ' + (source === 'song' ? '这首歌有记忆' : '链路曲线') }}
    </text>
    <g class="legend">
      <text x="36" y="1006">按住 听原样　　拖动 捏一段　　悬停 看依据</text>
      <text x="36" y="1026">点中心 说　　　 L 列表　　　⌘K 找一首</text>
    </g>
    <text ref="readout" x="1644" y="1026" text-anchor="end" class="readout"></text>
  </svg>
</template>

<style scoped>
.ear-svg {
  display: block;
  width: 100vw;
  height: 100vh;
  touch-action: none;
  user-select: none;
  -webkit-user-select: none;
  background: var(--bg);
  cursor: default;
}
.bg {
  fill: var(--bg);
}
.halo-0 {
  stop-color: var(--accent);
  stop-opacity: 0.075;
}
.halo-1 {
  stop-color: var(--accent);
  stop-opacity: 0;
}
.ring {
  fill: none;
  stroke: var(--line);
  stroke-width: 1;
}
.progress {
  fill: none;
  stroke: var(--accent);
  stroke-opacity: 0.45;
  stroke-width: 1.5;
  stroke-linecap: round;
}
.ribbon-boost {
  fill: var(--accent);
  fill-opacity: 0.78;
  cursor: grab;
}
.ribbon-boost.glow {
  fill-opacity: 0.55;
}
.ribbon-boost:not(.glow):active {
  cursor: grabbing;
}
.ribbon-cut {
  fill: var(--muted);
  fill-opacity: 0.3;
  cursor: grab;
}
.baseline {
  fill: none;
  stroke: var(--text);
  stroke-opacity: 0.16;
  stroke-width: 1;
  stroke-linecap: round;
}
.hit {
  pointer-events: all;
}
.node {
  pointer-events: all;
  cursor: pointer;
}
.node-dot {
  fill: var(--accent);
  fill-opacity: 0.85;
}
.node-title {
  font-size: 12px;
  fill: var(--text);
}
.node-sub {
  font-size: 10px;
  fill: var(--dim);
  font-family: var(--mono);
}
.tick text,
.tick {
  font-size: 9.5px;
  fill: var(--dim);
  font-family: var(--mono);
}
.peak text {
  font-size: 10px;
  font-family: var(--mono);
}
.c1 {
  font-size: 15px;
  font-weight: 600;
  fill: var(--text);
}
.c2 {
  font-size: 10.5px;
  fill: var(--dim);
  font-family: var(--mono);
}
.c3 {
  font-size: 11.5px;
  fill: var(--muted);
}
.votes,
.saymenu {
  transition: opacity 300ms;
  pointer-events: none;
}
.votes[opacity="1"],
.saymenu[opacity="1"] {
  pointer-events: all;
}
.pill rect,
.vote rect {
  fill: var(--raised);
  stroke: var(--line);
}
.pill:hover rect {
  stroke: var(--accent);
}
.vote-a {
  stroke: var(--accent) !important;
}
.pill-t,
.vote-at,
.vote-rt {
  font-size: 12px;
  fill: var(--text);
}
.vote-rt {
  fill: var(--muted);
}
.say-input {
  position: fixed;
  left: 50%;
  top: calc(50% - 14px);
  transform: translate(-50%, -50%);
  width: 170px;
  background: none;
  border: 0;
  outline: 0;
  color: var(--text);
  font-size: 14px;
  text-align: center;
  caret-color: var(--accent);
  display: none;
}
.say-input.on {
  display: block;
}
.say-input::placeholder {
  color: var(--dim);
}
.tip {
  transition: opacity 160ms;
  pointer-events: none;
}
.tip-box {
  fill: var(--raised);
  stroke: var(--line);
}
.tip-t {
  font-size: 10.5px;
  fill: var(--accent);
  font-family: var(--mono);
}
.tip-s {
  font-size: 11.5px;
  fill: var(--muted);
}
.glyph {
  fill: none;
  stroke: var(--accent);
  stroke-width: 2.4;
  stroke-linecap: round;
}
.wordmark {
  font-size: 11px;
  letter-spacing: 3px;
  fill: var(--dim);
  font-family: var(--mono);
}
.wordmark-sub {
  font-size: 11px;
  fill: var(--muted);
}
.live-dot {
  fill: var(--accent);
}
.status {
  font-size: 11px;
  fill: var(--muted);
}
.legend text {
  font-size: 10px;
  fill: var(--dim);
  font-family: var(--mono);
  letter-spacing: 0.4px;
}
.readout {
  font-size: 10px;
  fill: var(--dim);
  font-family: var(--mono);
}
</style>
