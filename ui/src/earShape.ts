/**
 * 耳形几何：把 31 段 EQ 画成一条耳蜗螺旋（内圈低频、外圈高频，频率按耳蜗基底膜的排布对数展开）。
 * 这里只管算：给定增益，给三段 path（抬升/削除/基线）与「指到的是哪一段」。
 * 画与交互在 EarView.vue；数值与阈值在这里，可被单测锁住。
 */

export const BANDS = 31;
/** 螺旋圈数：2.8 圈让相邻两圈之间留出一臂的距离，拖动不会误捏到隔壁频段。 */
export const TURNS = 2.8;
export const THETA_MAX = TURNS * 2 * Math.PI;
/** 耳蜗中心孔半径与外缘；S 是每 dB 的像素位移。 */
export const R_IN = 112;
export const R_OUT = 384;
export const GAIN_PX = 13;
/** 外圈轨道（进度环与「接下来」节点）的半径。 */
export const RING = 448;

/** 31 段中心频率，与 rust/awake-core 的 EQ 频段表一致。 */
export const EQ_FREQS = [
  20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630,
  800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000,
  12500, 16000, 20000,
];

/** 螺旋的开口方向：让缺口停在左上，给右下的进度环让位。 */
export const START_ANGLE = (135 - 288) * (Math.PI / 180);

export function bandTheta(i: number): number {
  return (THETA_MAX * i) / (BANDS - 1);
}

/** 对数展开：内圈 20 Hz、外圈 20 kHz。 */
export function baseRadius(theta: number): number {
  return R_IN * Math.pow(R_OUT / R_IN, theta / THETA_MAX);
}

export function polar(
  theta: number,
  radius: number,
  cx: number,
  cy: number,
): [number, number] {
  const a = theta + START_ANGLE;
  return [cx + radius * Math.cos(a), cy + radius * Math.sin(a)];
}

function clampedRadius(theta: number, gain: number): number {
  return Math.max(baseRadius(theta) + GAIN_PX * gain, baseRadius(theta) * 0.5);
}

/** Catmull-Rom：31 段之间连成一条平滑的线；段中心处严格等于该段增益。 */
export function sampleGain(theta: number, gains: number[]): number {
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

export interface SpiralPaths {
  /** 正增益色带（抬升的部分，基线到曲线之间）。 */
  boost: string;
  /** 负增益色带（削除的部分）。 */
  cut: string;
  /** 零增益基线螺旋。 */
  baseline: string;
}

/** 三段 path；tMax 用来做「从中心长出来」的入场动画，k 是全局松开系数（按住旁路时→0）。 */
export function spiralPaths(
  gains: number[],
  cx: number,
  cy: number,
  tMax: number = THETA_MAX,
  k = 1,
): SpiralPaths {
  const boost: string[] = [];
  const cut: string[] = [];
  let baseline = "";
  const steps = 240;
  /** 低于这个 dB 的段画不出一个像素，直接当作没有色带。 */
  const EPS = 0.05;
  let prevB: [number, number] | null = null;
  let prevD: [number, number] | null = null;
  let prevG = 0;
  for (let s = 0; s <= steps; s++) {
    const theta = tMax * (s / steps);
    const g = sampleGain(theta, gains) * k;
    const b = polar(theta, baseRadius(theta), cx, cy);
    const d = polar(theta, clampedRadius(theta, g), cx, cy);
    baseline += (s ? "L" : "M") + b[0].toFixed(1) + " " + b[1].toFixed(1);
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
  return { boost: boost.join(""), cut: cut.join(""), baseline };
}

/** 指针落在哪一段：按对数半径挑最接近的一圈，换算成频段与增益。near 是对数距离，越小越贴。 */
export function locateBand(
  x: number,
  y: number,
  cx: number,
  cy: number,
): { index: number; gain: number; near: number } {
  const dx = x - cx;
  const dy = y - cy;
  const r = Math.hypot(dx, dy) || 0.001;
  let a = Math.atan2(dy, dx) - START_ANGLE;
  a = ((a % (2 * Math.PI)) + 2 * Math.PI) % (2 * Math.PI);
  let best = 0;
  let bestDist = Infinity;
  for (let k = 0; k <= Math.ceil(TURNS); k++) {
    const theta = a + 2 * Math.PI * k;
    if (theta > THETA_MAX + 0.3) continue;
    const dist = Math.abs(
      Math.log(r / baseRadius(Math.min(theta, THETA_MAX))),
    );
    if (dist < bestDist) {
      bestDist = dist;
      best = theta;
    }
  }
  return {
    index: Math.max(
      0,
      Math.min(BANDS - 1, Math.round((best / THETA_MAX) * (BANDS - 1))),
    ),
    gain: Math.max(
      -12,
      Math.min(12, (r - baseRadius(Math.min(best, THETA_MAX))) / GAIN_PX),
    ),
    near: bestDist,
  };
}

/** 可闻差：|gain| 低于它不标数值。 */
export const PEAK_MIN_DB = 0.6;

/** 峰与谷：耳形上只标这两个数，别的交给悬停。平直时返回 null。 */
export function bandExtremes(
  gains: number[],
): { max: { i: number; v: number }; min: { i: number; v: number } } | null {
  if (!gains.length) return null;
  let imax = 0;
  let imin = 0;
  for (let i = 1; i < gains.length; i++) {
    if (gains[i] > gains[imax]) imax = i;
    if (gains[i] < gains[imin]) imin = i;
  }
  if (
    Math.abs(gains[imax]) < PEAK_MIN_DB &&
    Math.abs(gains[imin]) < PEAK_MIN_DB
  )
    return null;
  return { max: { i: imax, v: gains[imax] }, min: { i: imin, v: gains[imin] } };
}

export function freqLabel(f: number): string {
  return f >= 1000 ? f / 1000 + "k" : String(f);
}

/** 悬停依据里的完整频率名。 */
export function freqLong(f: number): string {
  return f >= 1000 ? f / 1000 + " kHz" : f + " Hz";
}
