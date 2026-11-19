/**
 * 播放页「按住键旁路」的判定与增益换算。
 *
 * 抽成纯函数是因为两件错在界面上都看不出来：长按的重复事件把「一次按下」
 * 当成多次按下（快照被覆盖，松手回不到原曲线），以及在曲库搜索框里敲 b
 * 时把整条 EQ 旁路掉。node --test 直接跑这些函数。
 */

/** 旁路键：按住 B 临时把整条曲线压平，松手恢复。 */
export const BYPASS_KEY = "b";

export interface KeyLike {
  key: string;
  metaKey: boolean;
  ctrlKey: boolean;
  altKey: boolean;
  repeat: boolean;
}

/**
 * 只认不带修饰键的 B。⌘B / ⌃B 留给别的功能，长按的 repeat 事件不是新的一次按下。
 */
export function isBypassKey(e: KeyLike): boolean {
  if (e.metaKey || e.ctrlKey || e.altKey) return false;
  if (e.repeat) return false;
  return e.key.toLowerCase() === BYPASS_KEY;
}

/** 在输入框里敲 b 是在打字，不是在旁路。 */
export function isTypingTarget(
  tagName: string,
  isContentEditable = false,
): boolean {
  return isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(tagName);
}

/** 平直曲线没有可旁路的东西：此时按下 B 不写后端，也不显示「旁路中」。 */
export function hasAudibleEq(gains: ReadonlyArray<number>): boolean {
  return gains.some((g) => g !== 0);
}

/** 旁路期间交给后端的曲线：与当前曲线等长的全零；不改动传入的数组。 */
export function flatGains(length: number): number[] {
  const n = Number.isFinite(length) ? Math.max(0, Math.trunc(length)) : 0;
  return Array(n).fill(0);
}
