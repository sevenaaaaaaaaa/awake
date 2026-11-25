/**
 * 曲库洞察的取数与文案。
 *
 * 三个命令都是只读的（Rust 侧 `library_insight.rs`），所以界面可以随便刷新。
 * 取数失败一律退回空值：浏览器预览模式没有这些命令，不能因此白屏。
 */

export type Shelf = "Classical" | "Light" | "Live" | "None";

/** 古典的作品视图：四个维度在专架层解析，不在 Track schema 里。 */
export interface ClassicalWork {
  composer: string;
  work: string;
  /** 空字符串表示这张专辑里没有作品号——不编。 */
  catalogue: string;
  movement_count: number;
  track_ids: string[];
}

export interface ShelfGroup {
  key: string;
  label: string;
  count: number;
  track_ids: string[];
  reasons: string[];
  /** 只有古典专架会填。 */
  works?: ClassicalWork[];
}

export interface QueueBatch {
  key: string;
  label: string;
  shelf: Shelf;
  count: number;
  reason: string;
  track_ids: string[];
}

export interface AdaptQueue {
  library_total: number;
  with_curve: number;
  queued: number;
  blocked_by_reference: boolean;
  batches: QueueBatch[];
}

export interface ArtistProfile {
  artist: string;
  tracks: number;
  plays: number;
  completions: number;
  skips: number;
  seconds: number;
  last_played_ms: number | null;
  top_genres: string[];
  hours_utc: number[];
  completion_rate: number;
  skip_rate: number;
  line: string;
}

export type InsightCaller = <T>(
  command: string,
  args?: Record<string, any>,
) => Promise<T>;

export interface Insight {
  shelves: ShelfGroup[];
  queue: AdaptQueue | null;
  artists: ArtistProfile[];
}

/** 报告卡上的一行话。数字全部来自同一份队列，不另算。 */
export function insightSummary(queue: AdaptQueue | null): string {
  if (!queue) return "还没有可核对的数据";
  const parts = [
    `库里 ${queue.library_total} 首`,
    `已有曲线 ${queue.with_curve} 首`,
    queue.queued === 0
      ? "没有待适配的曲目"
      : `待适配 ${queue.queued} 首（${queue.batches.length} 批）`,
  ];
  // 没有待适配的曲目时，提"去校准"只是噪音——队列空了就不催。
  if (queue.blocked_by_reference && queue.queued > 0) {
    parts.push("缺参照物：先做一次校准");
  }
  return parts.join(" · ");
}

/** 专架标题下的一行依据。没有依据就写"—"，不编。 */
export function shelfLine(group: ShelfGroup): string {
  const why = group.reasons.length ? group.reasons.join("、") : "—";
  return `${group.label} · ${group.count} 首 · 依据：${why}`;
}

async function safe<T>(
  caller: InsightCaller,
  command: string,
  fallback: T,
): Promise<T> {
  try {
    const value = await caller<T>(command);
    return value ?? fallback;
  } catch {
    return fallback;
  }
}

export async function loadInsight(caller: InsightCaller): Promise<Insight> {
  const [shelves, queue, artists] = await Promise.all([
    safe<ShelfGroup[]>(caller, "shelf_overview", []),
    safe<AdaptQueue | null>(caller, "adapt_queue", null),
    safe<ArtistProfile[]>(caller, "artist_profiles", []),
  ]);
  return { shelves, queue, artists };
}
