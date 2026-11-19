import test from "node:test";
import assert from "node:assert/strict";

import {
  DEFAULT_GEOMETRY,
  EQ_FREQS,
  curvePath,
  dbLabel,
  fillPath,
  freqLabel,
  isFlatCurve,
  normaliseGains,
  peakBand,
  xForFrequency,
  yForGain,
} from "./stageCurve.ts";

test("频段表与 rust 的 31 段一致：20 Hz 到 20 kHz，31 个点", () => {
  assert.equal(EQ_FREQS.length, 31);
  assert.equal(EQ_FREQS[0], 20);
  assert.equal(EQ_FREQS[30], 20000);
});

test("传入的增益被规整成 31 个有限值，并夹到 ±12 dB", () => {
  const out = normaliseGains([3, NaN as unknown as number, 99, -99]);
  assert.equal(out.length, 31);
  assert.equal(out[0], 3);
  assert.equal(out[1], 0);
  assert.equal(out[2], 12);
  assert.equal(out[3], -12);
  assert.ok(out.slice(4).every((v) => v === 0));
});

test("0 dB 落在中线，+12 在顶，−12 在底", () => {
  const g = DEFAULT_GEOMETRY;
  const middle = yForGain(0, g);
  assert.ok(Math.abs(middle - (g.inset + (g.height - g.inset - g.labelBand) / 2)) < 0.001);
  assert.ok(yForGain(12, g) < middle);
  assert.ok(yForGain(-12, g) > middle);
});

test("20 Hz 在最左、20 kHz 在最右，且随频率单调递增", () => {
  const g = DEFAULT_GEOMETRY;
  const left = xForFrequency(20, g);
  const right = xForFrequency(20000, g);
  assert.ok(Math.abs(left - g.inset) < 0.001);
  assert.ok(Math.abs(right - (g.width - g.inset)) < 0.001);
  const points = [20, 200, 2000, 20000].map((f) => xForFrequency(f, g));
  for (let i = 1; i < points.length; i += 1) assert.ok(points[i] > points[i - 1]);
});

test("峰值取绝对值最大的那一段，平直曲线被识别为平直", () => {
  const flat = normaliseGains([]);
  assert.equal(isFlatCurve(flat), true);
  const gains = flat.slice();
  gains[5] = -6;
  gains[20] = 2;
  assert.deepEqual(peakBand(gains), { index: 5, value: -6 });
  assert.equal(isFlatCurve(gains), false);
});

test("曲线路径点数等于频段数，填充路径闭合到 0 dB 基线", () => {
  const gains = normaliseGains([1, 2, 3]);
  const path = curvePath(gains);
  assert.equal((path.match(/[ML]/g) || []).length, 31);
  assert.ok(path.startsWith("M"));
  const fill = fillPath(gains);
  assert.ok(fill.endsWith("Z"));
  assert.ok(fill.includes(yForGain(0).toFixed(2)));
});

test("频率与增益的显示格式统一", () => {
  assert.equal(freqLabel(31.5), "31.5");
  assert.equal(freqLabel(125), "125");
  assert.equal(freqLabel(1000), "1kHz");
  assert.equal(freqLabel(16000), "16kHz");
  assert.equal(dbLabel(0), "+0.0 dB");
  assert.equal(dbLabel(-3.55), "-3.5 dB");
});
