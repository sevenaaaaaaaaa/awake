import test from "node:test";
import assert from "node:assert/strict";

import {
  flatGains,
  hasAudibleEq,
  isBypassKey,
  isTypingTarget,
} from "./bypassKey.ts";

const key = (over: Partial<Record<string, unknown>> = {}) => ({
  key: "b",
  metaKey: false,
  ctrlKey: false,
  altKey: false,
  repeat: false,
  ...over,
});

test("B 的大小写都算旁路键；带修饰键不算", () => {
  assert.equal(isBypassKey(key()), true);
  assert.equal(isBypassKey(key({ key: "B" })), true);
  assert.equal(isBypassKey(key({ key: "b", metaKey: true })), false);
  assert.equal(isBypassKey(key({ key: "b", ctrlKey: true })), false);
  assert.equal(isBypassKey(key({ key: "b", altKey: true })), false);
  assert.equal(isBypassKey(key({ key: "v" })), false);
});

test("长按的重复事件不算新的一次按下——否则快照被覆盖，松手回不到原曲线", () => {
  assert.equal(isBypassKey(key({ repeat: true })), false);
});

test("输入控件里的按键不触发旁路", () => {
  assert.equal(isTypingTarget("INPUT"), true);
  assert.equal(isTypingTarget("TEXTAREA"), true);
  assert.equal(isTypingTarget("SELECT"), true);
  assert.equal(isTypingTarget("DIV", true), true);
  assert.equal(isTypingTarget("DIV"), false);
  assert.equal(isTypingTarget("BUTTON"), false);
});

test("平直曲线没有可旁路的东西", () => {
  assert.equal(hasAudibleEq(Array(31).fill(0)), false);
  const g = Array(31).fill(0);
  g[7] = -3.5;
  assert.equal(hasAudibleEq(g), true);
});

test("旁路曲线与当前曲线等长、全零，且不动传入数组", () => {
  const original = [3, -2, 1];
  const flat = flatGains(original.length);
  assert.deepEqual(flat, [0, 0, 0]);
  assert.deepEqual(original, [3, -2, 1]);
  assert.notEqual(flat, original);
});

test("长度不合法时不造出烂数组", () => {
  assert.deepEqual(flatGains(0), []);
  assert.deepEqual(flatGains(-5), []);
  assert.deepEqual(flatGains(Number.NaN), []);
  assert.equal(flatGains(31).length, 31);
});
