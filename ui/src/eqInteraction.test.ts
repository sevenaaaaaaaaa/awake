import test from "node:test";
import assert from "node:assert/strict";

import {
  bandFromRatio,
  gainFromRatio,
  paintIndices,
  withGains,
} from "./eqInteraction.ts";

test("横向比例落在两端与中间时对应正确的频段", () => {
  assert.equal(bandFromRatio(0, 31), 0);
  assert.equal(bandFromRatio(1, 31), 30);
  assert.equal(bandFromRatio(0.5, 31), 15);
  assert.equal(bandFromRatio(-3, 31), 0);
  assert.equal(bandFromRatio(9, 31), 30);
});

test("纵向比例换算成 dB：中线 0，顶部 +12，底部 −12，并保留一位小数", () => {
  assert.equal(gainFromRatio(0.5), 0);
  assert.equal(gainFromRatio(0), 12);
  assert.equal(gainFromRatio(1), -12);
  assert.equal(gainFromRatio(0.25), 6);
  assert.equal(gainFromRatio(-1), 12);
  assert.ok(Number.isFinite(gainFromRatio(0.123)));
});

test("涂抹区间包含首尾，方向无关，不重不漏", () => {
  assert.deepEqual(paintIndices(3, 6), [3, 4, 5, 6]);
  assert.deepEqual(paintIndices(6, 3), [3, 4, 5, 6]);
  assert.deepEqual(paintIndices(4, 4), [4]);
});

test("写值返回新数组，不修改原数组，越界下标被忽略", () => {
  const original = [0, 0, 0];
  const next = withGains(original, [1, 9], 3.5);
  assert.deepEqual(original, [0, 0, 0]);
  assert.deepEqual(next, [0, 3.5, 0]);
});
