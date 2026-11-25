/**
 * 首页 tile 的「多久没被点过」。
 *
 * composeHome 里有一条规则：连续 3 天没点过的 tile 自动降权，钉住可抵消。
 * 规则写了但一直没有数据源——这个文件就是那个数据源：只记"最后一次点击时间"，
 * 存在 localStorage 里；读不到或读坏了都当作"没点过"（不降权）。
 */

import type { TileKind } from "./homeLayout";

const STORAGE_KEY = "awake.home.tileClicks";
const DAY_MS = 24 * 60 * 60 * 1000;

export interface ClickStore {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

type Clicks = Partial<Record<TileKind, number>>;

function read(store: ClickStore): Clicks {
  try {
    const raw = store.getItem(STORAGE_KEY);
    if (!raw) return {};
    const parsed = JSON.parse(raw) as unknown;
    if (!parsed || typeof parsed !== "object") return {};
    const out: Clicks = {};
    for (const [key, value] of Object.entries(parsed as Record<string, unknown>)) {
      if (typeof value === "number" && Number.isFinite(value)) {
        out[key as TileKind] = value;
      }
    }
    return out;
  } catch {
    // 坏数据不阻塞首页：当作没点过。
    return {};
  }
}

export function recordTileClick(store: ClickStore, kind: TileKind, nowMs: number): void {
  const clicks = read(store);
  clicks[kind] = nowMs;
  try {
    store.setItem(STORAGE_KEY, JSON.stringify(clicks));
  } catch {
    // 存不进去就算了：降权是锦上添花，不该影响播放。
  }
}

/** 没点过的 tile 不出现在结果里——没有历史不等于"很久没点"。 */
export function idleDays(store: ClickStore, nowMs: number): Partial<Record<TileKind, number>> {
  const clicks = read(store);
  const out: Partial<Record<TileKind, number>> = {};
  for (const [kind, at] of Object.entries(clicks)) {
    if (typeof at !== "number") continue;
    const days = Math.floor((nowMs - at) / DAY_MS);
    if (days > 0) out[kind as TileKind] = days;
  }
  return out;
}

/** 内存实现，给测试与浏览器预览用。 */
export function memoryStore(seed: Record<string, string> = {}): ClickStore {
  const data = new Map(Object.entries(seed));
  return {
    getItem: (key) => data.get(key) ?? null,
    setItem: (key, value) => void data.set(key, value),
  };
}
