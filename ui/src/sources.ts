import type { Album, Source, Track } from "./types";

/**
 * 一个来源里「已经添加了什么」——这是用户最想看的东西。
 * 空 sourceId 表示全部来源（曲库页的默认视图）。
 */
export function sourceTracks(tracks: Track[], sourceId: string): Track[] {
  if (!sourceId) return tracks;
  return tracks.filter((track) => track.source_id === sourceId);
}

/** 只看某个来源时，专辑格子也要跟着收窄：只留含这个来源曲目的专辑。 */
export function sourceAlbums(albums: Album[], sourceId: string): Album[] {
  if (!sourceId) return albums;
  return albums.filter((album) =>
    album.tracks.some((track) => track.source_id === sourceId),
  );
}

/**
 * 最近添加的曲目。没有加入时间的老数据按曲库顺序垫在后面，
 * 这样「刚连上的来源」永远出现在最上面。
 */
export function recentlyAdded(tracks: Track[], limit = 12): Track[] {
  const stamped = tracks.filter((track) => (track.added_at ?? 0) > 0);
  const pool = stamped.length ? stamped : tracks;
  const sorted = [...pool].sort(
    (a, b) => (b.added_at ?? 0) - (a.added_at ?? 0),
  );
  return sorted.slice(0, Math.max(0, limit));
}

/** 来源卡片上的一句话状态：多少首 + 上次更新。 */
export function sourceStatusLine(source: Source): string {
  const count = `${source.track_count ?? 0} 首`;
  if (!source.last_scan) return `${count} · 还没有扫描过`;
  return `${count} · 上次更新 ${new Date(source.last_scan).toLocaleString("zh-CN")}`;
}

/** 曲库页的筛选条：全部来源 + 每个来源。 */
export function sourceFilterOptions(
  sources: Source[],
): { id: string; label: string }[] {
  return [
    { id: "", label: "全部来源" },
    ...sources.map((source) => ({ id: source.id, label: source.name })),
  ];
}

/** 连上来源之后要选中的筛选值，保证「刚添加的内容」马上可见。 */
export function filterAfterConnect(sourceId: string): string {
  return sourceId || "";
}
