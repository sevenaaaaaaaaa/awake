/**
 * S1：按歌记忆的前端类型。
 *
 * 字段名跟着 Rust 侧走（snake_case）——Tauri 只对**命令参数**做 camelCase 映射，
 * 返回值是 serde 原样序列化。混用两种命名会让「看着有值其实取不到」这类错查很久。
 */
export type CurveBasis = {
  headphone: string;
  track: string;
  prior: string;
};

export type CurveResolution = {
  track_id: string;
  title: string;
  /** "song" = 这首歌有记忆；"chain" = 回落链路曲线。 */
  source: "song" | "chain";
  gains: number[];
  base: number[] | null;
  basis: CurveBasis | null;
  basis_stale: boolean;
  /** 失效时可直接显示的一句话；成立时为空串。 */
  stale_hint: string;
  headphone_now: string;
  headphone_saved: string | null;
  prior_applied: boolean;
  prior_display: string;
};

export type CurveCandidate = {
  id: string;
  title: string;
  artist: string;
  duration: number;
};

/** 导入了但没对上本地曲目的一条曲线，等着用户指定。 */
export type PendingCurve = {
  ios_id: string;
  title: string;
  reason: string;
  candidates: CurveCandidate[];
};
