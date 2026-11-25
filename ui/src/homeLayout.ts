/**
 * 首页版面编排：把"库里现在有什么"算成一组 tile。
 *
 * 设计约束来自 docs/plan-v1-sources-home-adaptation.md 第 3 节：
 * - 版面不是编辑写死的，是每天按库状态算一次；用户只能钉住 / 隐藏 / 换位。
 * - tile 词汇表限死，多一类都不加（这里是唯一真值源）。
 * - 每个 tile 必须带一句"为什么在这里"——没有理由的 tile 不许出现在首屏。
 * - 一行最多 2 个（>=768px）、1 个（<768px），由样式负责；这里只管顺序与取舍。
 */

export type TileKind =
  | "continue"
  | "adapt"
  | "today"
  | "shelf"
  | "radio"
  | "ears"
  | "addMusic"
  | "connectRadio";

export interface ContinuePoint {
  title: string;
  remainingSec: number;
}

export interface HomeSnapshot {
  trackCount: number;
  /** 有未播完的曲目时才出现「继续听」。 */
  continueAt?: ContinuePoint | null;
  /** 待适配曲目数（来自入库适配报告）。0 或缺失时整块消失。 */
  pendingAdapt?: number;
  /** 今日一首的标题。 */
  today?: string | null;
  /** 三个专架各自的曲目数。 */
  shelves?: { classical?: number; light?: number; live?: number };
  stationCount?: number;
  hasCalibration?: boolean;
  /** 用户钉住的 tile：排最前，且免疫自动降权。 */
  pinned?: TileKind[];
  /** 连续多少天没被点过。>=3 天自动降权（隐藏），钉住可抵消。 */
  idleDays?: Partial<Record<TileKind, number>>;
}

export interface Tile {
  kind: TileKind;
  title: string;
  subtitle: string;
  /** 为什么在这里。空字符串是不允许的，测试会拦。 */
  reason: string;
}

/** 专架进首页的门槛：少于此数不单独占位（宁可没有，也不给一个只有 3 首的"专架"）。 */
export const SHELF_MIN_TRACKS = 8;
/** 今日一首的最小库容：太小的库"今日"就是"全部"，没有意义。 */
export const TODAY_MIN_TRACKS = 20;
/** 连续几天没点就自动降权。 */
export const IDLE_DAYS_LIMIT = 3;
/** 首屏最多几块。 */
export const MAX_TILES = 6;

function shelfTile(shelves: NonNullable<HomeSnapshot["shelves"]>): Tile | null {
  const entries: Array<[string, number]> = [
    ["古典", shelves.classical ?? 0],
    ["轻音乐", shelves.light ?? 0],
    ["现场", shelves.live ?? 0],
  ];
  const hit = entries.filter(([, count]) => count >= SHELF_MIN_TRACKS);
  if (hit.length === 0) return null;
  return {
    kind: "shelf",
    title: hit.map(([name, count]) => `${name} ${count} 首`).join(" · "),
    subtitle: "按作品与场景排，不按艺人",
    reason: hit.map(([name, count]) => `${name}命中 ${count} 首`).join("，"),
  };
}

/**
 * 算出版面。纯函数：同样的输入永远同样的输出（可断言、可回放）。
 * 空库是特例：只给"添加音乐"和"接一个电台源"，不出现一排"暂无数据"。
 */
export function composeHome(snapshot: HomeSnapshot): Tile[] {
  const pinned = snapshot.pinned ?? [];
  const idle = snapshot.idleDays ?? {};

  if (snapshot.trackCount <= 0) {
    const empty: Tile[] = [
      {
        kind: "addMusic",
        title: "添加我的音乐",
        subtitle: "本地文件夹、NAS 或 MusicBee 曲库",
        reason: "库里还没有曲目",
      },
    ];
    empty.push(
      (snapshot.stationCount ?? 0) > 0
        ? { kind: "radio", title: "先听电台", subtitle: "不用等库建好", reason: "已经接过电台源" }
        : { kind: "connectRadio", title: "接一个电台源", subtitle: "公开电台，一次几百个台", reason: "库里还没有曲目" },
    );
    return empty;
  }

  const tiles: Tile[] = [];

  if (snapshot.continueAt) {
    const minutes = Math.max(1, Math.round(snapshot.continueAt.remainingSec / 60));
    tiles.push({
      kind: "continue",
      title: snapshot.continueAt.title,
      subtitle: `还剩 ${minutes} 分钟`,
      reason: "上次没听完",
    });
  }

  if ((snapshot.pendingAdapt ?? 0) > 0) {
    tiles.push({
      kind: "adapt",
      title: `${snapshot.pendingAdapt} 首等你听一下`,
      subtitle: "两组候选，各 15 秒",
      reason: "新入库的曲目还没定曲线",
    });
  }

  if (snapshot.today && snapshot.trackCount > TODAY_MIN_TRACKS) {
    tiles.push({
      kind: "today",
      title: snapshot.today,
      subtitle: "今天的这一首",
      reason: `从 ${snapshot.trackCount} 首里挑的`,
    });
  }

  const shelf = shelfTile(snapshot.shelves ?? {});
  if (shelf) tiles.push(shelf);

  if ((snapshot.stationCount ?? 0) > 0) {
    tiles.push({
      kind: "radio",
      title: "公开电台",
      subtitle: `${snapshot.stationCount} 个台`,
      reason: "已经接过电台源",
    });
  }

  tiles.push(
    snapshot.hasCalibration
      ? {
          kind: "ears",
          title: "你的耳朵",
          subtitle: "校准与耳机档案已就位",
          reason: "每首歌的曲线都叠了这一层",
        }
      : {
          kind: "ears",
          title: "3 分钟校准",
          subtitle: "让每首歌更像你要的声音",
          reason: "还没有个人听感先验",
        },
  );

  const visible = tiles.filter(
    (tile) => pinned.includes(tile.kind) || (idle[tile.kind] ?? 0) < IDLE_DAYS_LIMIT,
  );

  visible.sort((a, b) => {
    const rank = (kind: TileKind) => {
      const index = pinned.indexOf(kind);
      if (index >= 0) return index;
      return pinned.length + tiles.findIndex((t) => t.kind === kind);
    };
    return rank(a.kind) - rank(b.kind);
  });

  return visible.slice(0, Math.max(MAX_TILES, pinned.length));
}
