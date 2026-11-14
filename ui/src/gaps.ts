import type { ImportMatch } from "./types";

export interface MatchGap {
  artist: string;
  missing: number;
  titles: string[];
}

export interface MatchGaps {
  total: number;
  matched: number;
  missing: number;
  artists: MatchGap[];
}

export const GAP_ARTIST_LIMIT = 20;
export const GAP_TITLE_LIMIT = 5;
export const UNKNOWN_ARTIST = "未知艺人";

/**
 * 按码点比较，与 Rust 侧 `String` 的字节序（UTF-8 = 码点序）一致。
 * 不用 localeCompare：那套排序依赖系统区域设置，桌面版和浏览器版会给出不同顺序。
 */
export function compareByCodePoint(a: string, b: string): number {
  const left = [...a];
  const right = [...b];
  const shared = Math.min(left.length, right.length);
  for (let i = 0; i < shared; i += 1) {
    const diff = left[i].codePointAt(0)! - right[i]!.codePointAt(0)!;
    if (diff !== 0) return diff < 0 ? -1 : 1;
  }
  if (left.length === right.length) return 0;
  return left.length < right.length ? -1 : 1;
}

/**
 * 歌单匹配后的缺口聚合：谁缺、缺几首。
 * 口径与 `rust/crates/awake-app/src/playlist_import.rs` 的 `match_gaps` 一致：
 * 空艺人回落「未知艺人」，每组曲名最多留 5 条，按缺得多的排前面、同数量按艺人码点序，
 * 最多 20 组。桌面版走后端，浏览器预览走这里，两边不应该给出不同的面板。
 */
export function aggregateGaps(
  matches: ImportMatch[],
  artistLimit: number = GAP_ARTIST_LIMIT,
  titleLimit: number = GAP_TITLE_LIMIT,
): MatchGaps {
  const groups = new Map<string, { missing: number; titles: string[] }>();
  let matched = 0;
  for (const item of matches) {
    if (item.song_id) {
      matched += 1;
      continue;
    }
    const artist = (item.track.artist ?? "").trim() || UNKNOWN_ARTIST;
    const slot = groups.get(artist) ?? { missing: 0, titles: [] };
    slot.missing += 1;
    if (slot.titles.length < titleLimit) {
      const title = (item.track.title ?? "").trim();
      if (title) slot.titles.push(title);
    }
    groups.set(artist, slot);
  }
  const artists = [...groups.entries()]
    .map(([artist, slot]) => ({
      artist,
      missing: slot.missing,
      titles: slot.titles,
    }))
    .sort((a, b) => b.missing - a.missing || compareByCodePoint(a.artist, b.artist))
    .slice(0, artistLimit);
  return {
    total: matches.length,
    matched,
    missing: matches.length - matched,
    artists,
  };
}
