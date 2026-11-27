import test from "node:test";
import assert from "node:assert/strict";

import {
  BANDS,
  EQ_FREQS,
  GAIN_PX,
  THETA_MAX,
  bandExtremes,
  bandTheta,
  baseRadius,
  freqLabel,
  locateBand,
  polar,
  sampleGain,
  spiralPaths,
} from "./earShape.ts";

test("频段表与 rust 的 31 段一致：20 Hz 到 20 kHz", () => {
  assert.equal(BANDS, 31);
  assert.equal(EQ_FREQS.length, 31);
  assert.equal(EQ_FREQS[0], 20);
  assert.equal(EQ_FREQS[30], 20000);
});

test("段中心处的采样值严格等于该段增益", () => {
  const gains = Array.from({ length: 31 }, (_, i) => (i % 5) - 2);
  for (let i = 0; i < BANDS; i += 6) {
    assert.ok(
      Math.abs(sampleGain(bandTheta(i), gains) - gains[i]) < 1e-9,
      `band ${i}`,
    );
  }
});

test("平直曲线没有色带，基线仍在", () => {
  const flat = new Array(31).fill(0);
  const { boost, cut, baseline } = spiralPaths(flat, 0, 0);
  assert.equal(boost, "");
  assert.equal(cut, "");
  assert.ok(baseline.startsWith("M"));
  assert.ok(baseline.includes("L"));
});

test("抬升画进 boost，削减画进 cut，两边都不为空", () => {
  const gains = new Array(31).fill(0);
  gains[6] = 3;
  gains[24] = -2;
  const { boost, cut } = spiralPaths(gains, 0, 0);
  assert.ok(boost.length > 0);
  assert.ok(cut.length > 0);
});

test("按住（k=0）后整条曲线回到基线：没有色带", () => {
  const gains = new Array(31).fill(0);
  gains[8] = 5;
  const { boost } = spiralPaths(gains, 0, 0, THETA_MAX, 0);
  assert.equal(boost, "");
});

test("locateBand：放在第 i 圈外侧一个 GAIN_PX 处，指回第 i 段、增益 1", () => {
  for (const i of [2, 9, 17, 26]) {
    const theta = bandTheta(i);
    const r = baseRadius(theta) + GAIN_PX;
    const [x, y] = polar(theta, r, 0, 0);
    const loc = locateBand(x, y, 0, 0);
    assert.equal(loc.index, i, `band ${i} → ${loc.index}`);
    assert.ok(Math.abs(loc.gain - 1) < 0.12, `gain ${loc.gain}`);
    assert.ok(loc.near < 0.12, `near ${loc.near}`);
  }
});

test("bandExtremes：找到峰与谷；平直返回 null", () => {
  const gains = new Array(31).fill(0);
  assert.equal(bandExtremes(gains), null);
  gains[4] = 3.2;
  gains[22] = -1.5;
  const ex = bandExtremes(gains);
  assert.ok(ex);
  assert.equal(ex!.max.i, 4);
  assert.equal(ex!.max.v, 3.2);
  assert.equal(ex!.min.i, 22);
});

test("freqLabel：千赫以下原样，以上缩写", () => {
  assert.equal(freqLabel(100), "100");
  assert.equal(freqLabel(1000), "1k");
  assert.equal(freqLabel(16000), "16k");
});

test("入场动画的 tMax 只画一段弧：起点一致、终点落在 1/3 处", () => {
  const gains = new Array(31).fill(0);
  gains[10] = 2;
  const partial = spiralPaths(gains, 0, 0, THETA_MAX / 3);
  const full = spiralPaths(gains, 0, 0);
  assert.ok(partial.baseline.length < full.baseline.length);
  const firstOf = (d: string) => d.slice(0, d.indexOf("L"));
  assert.equal(firstOf(partial.baseline), firstOf(full.baseline));
  const [ex, ey] = (() => {
    const theta = THETA_MAX / 3;
    const r = baseRadius(theta) + GAIN_PX * 0; // 基线：零位移
    const a = theta + ((135 - 288) * Math.PI) / 180;
    return [Math.cos(a) * r, Math.sin(a) * r];
  })();
  const lastSeg = partial.baseline.slice(partial.baseline.lastIndexOf("L") + 1);
  const [lx, ly] = lastSeg.split(" ").map(Number);
  assert.ok(Math.abs(lx - ex) < 1.5, `x ${lx} vs ${ex}`);
  assert.ok(Math.abs(ly - ey) < 1.5, `y ${ly} vs ${ey}`);
});
