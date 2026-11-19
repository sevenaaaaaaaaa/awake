/**
 * 播放页 31 段曲线的纯计算部分。
 *
 * 频段表与 rust `awake-core` 的 31 段中心频率一致；坐标用对数频率轴，
 * 纵轴以 0 dB 为中点、±12 dB 为上下限。抽出来是为了能测：
 * 曲线画错在界面上很难看出来，但它决定用户对「现在 EQ 在做什么」的判断。
 */

export const EQ_FREQS: readonly number[] = [
  20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630,
  800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000,
  12500, 16000, 20000,
];

export const EQ_RANGE = 12;
export const EQ_TICKS = [31.5, 125, 500, 2000, 8000, 16000];

/** 把传入的增益规整成 31 个有限值，超出 ±12 dB 的夹到边界。 */
export function normaliseGains(gains: number[] | undefined | null): number[] {
  const list = gains || [];
  return Array.from({ length: EQ_FREQS.length }, (_, i) => {
    const v = Number(list[i]);
    if (!Number.isFinite(v)) return 0;
    return Math.max(-EQ_RANGE, Math.min(EQ_RANGE, v));
  });
}

export function peakBand(gains: number[]): { index: number; value: number } {
  let index = 0;
  gains.forEach((v, i) => {
    if (Math.abs(v) > Math.abs(gains[index])) index = i;
  });
  return { index, value: gains[index] ?? 0 };
}

export function isFlatCurve(gains: number[]): boolean {
  return Math.abs(peakBand(gains).value) < 0.05;
}

export function freqLabel(value: number): string {
  if (!Number.isFinite(value) || value <= 0) return "—";
  if (value >= 1000) {
    const k = value / 1000;
    return (Number.isInteger(k) ? k.toFixed(0) : k.toFixed(1)) + "kHz";
  }
  return Number.isInteger(value) ? String(value) : value.toFixed(1);
}

export function dbLabel(value: number): string {
  if (!Number.isFinite(value)) return "—";
  return (value >= 0 ? "+" : "") + value.toFixed(1) + " dB";
}

export interface CurveGeometry {
  width: number;
  height: number;
  inset: number;
  /** 底部留给频率标签的高度 */
  labelBand: number;
}

export const DEFAULT_GEOMETRY: CurveGeometry = {
  width: 320,
  height: 132,
  inset: 10,
  labelBand: 18,
};

function plotHeight(g: CurveGeometry): number {
  return Math.max(1, g.height - g.inset - g.labelBand);
}

/** 频率 → 横坐标（对数轴）。 */
export function xForFrequency(frequency: number, g: CurveGeometry = DEFAULT_GEOMETRY): number {
  const lo = Math.log10(20);
  const hi = Math.log10(20000);
  const clamped = Math.max(20, Math.min(20000, frequency));
  const ratio = (Math.log10(clamped) - lo) / (hi - lo);
  return g.inset + ratio * (g.width - g.inset * 2);
}

/** 增益 → 纵坐标（0 dB 在中线）。 */
export function yForGain(gain: number, g: CurveGeometry = DEFAULT_GEOMETRY): number {
  const clamped = Math.max(-EQ_RANGE, Math.min(EQ_RANGE, gain));
  return g.inset + plotHeight(g) * (0.5 - clamped / (2 * EQ_RANGE));
}

export function curvePath(gains: number[], g: CurveGeometry = DEFAULT_GEOMETRY): string {
  return gains
    .map((gain, i) => {
      const x = xForFrequency(EQ_FREQS[i], g).toFixed(2);
      const y = yForGain(gain, g).toFixed(2);
      return `${i === 0 ? "M" : "L"}${x},${y}`;
    })
    .join(" ");
}

export function fillPath(gains: number[], g: CurveGeometry = DEFAULT_GEOMETRY): string {
  const base = yForGain(0, g).toFixed(2);
  const right = xForFrequency(20000, g).toFixed(2);
  const left = xForFrequency(20, g).toFixed(2);
  return `${curvePath(gains, g)} L${right},${base} L${left},${base} Z`;
}
