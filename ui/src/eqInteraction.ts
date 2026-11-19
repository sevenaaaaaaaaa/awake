/**
 * 曲线编辑器里与界面无关的换算。
 *
 * 拖曲线时最容易错的三件事：指针落在哪一段、纵坐标换算成多少 dB、
 * Shift 涂抹时中间有没有漏段。它们都在这里，并且有测试。
 */

export const EQ_LIMIT = 12;

/** 横向比例（0..1）→ 频段序号，四舍五入并夹在两端。 */
export function bandFromRatio(ratioX: number, count: number): number {
  if (!Number.isFinite(ratioX) || count <= 0) return 0;
  const clamped = Math.max(0, Math.min(1, ratioX));
  return Math.max(0, Math.min(count - 1, Math.round(clamped * (count - 1))));
}

/** 纵向比例（0..1，0 在顶部）→ 增益，一位小数，夹在 ±12 dB。 */
export function gainFromRatio(ratioY: number): number {
  if (!Number.isFinite(ratioY)) return 0;
  const clamped = Math.max(0, Math.min(1, ratioY));
  const value = (0.5 - clamped) * 2 * EQ_LIMIT;
  return Math.round(Math.max(-EQ_LIMIT, Math.min(EQ_LIMIT, value)) * 10) / 10;
}

/** 涂抹时经过的频段序号（含首尾，方向无关）。 */
export function paintIndices(from: number, to: number): number[] {
  const start = Math.min(from, to);
  const end = Math.max(from, to);
  const out: number[] = [];
  for (let i = start; i <= end; i += 1) out.push(i);
  return out;
}

/** 把值写进数组的指定位置，返回新数组（不改入参）。 */
export function withGains(
  gains: number[],
  indices: number[],
  value: number,
): number[] {
  const next = gains.slice();
  for (const index of indices) {
    if (index >= 0 && index < next.length) next[index] = value;
  }
  return next;
}
