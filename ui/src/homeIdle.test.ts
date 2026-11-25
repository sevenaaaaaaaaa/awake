import test from "node:test";
import assert from "node:assert/strict";

import { idleDays, memoryStore, recordTileClick } from "./homeIdle.ts";

const DAY = 24 * 60 * 60 * 1000;

test("记过点击就按天数算空闲", () => {
  const store = memoryStore();
  const now = 1_000 * DAY;
  recordTileClick(store, "today", now - 4 * DAY);
  assert.deepEqual(idleDays(store, now), { today: 4 });
});

test("没点过的 tile 不出现——没有历史不等于很久没点", () => {
  assert.deepEqual(idleDays(memoryStore(), 5 * DAY), {});
});

test("当天点过不算空闲", () => {
  const store = memoryStore();
  const now = 10 * DAY;
  recordTileClick(store, "adapt", now - 1000);
  assert.deepEqual(idleDays(store, now), {});
});

test("坏数据当没点过，不抛错", () => {
  assert.deepEqual(idleDays(memoryStore({ "awake.home.tileClicks": "{not json" }), 3 * DAY), {});
  const odd = memoryStore({ "awake.home.tileClicks": '{"today":"yesterday"}' });
  assert.deepEqual(idleDays(odd, 3 * DAY), {}, "非数字值要忽略");
});

test("多次点击只保留最后一次", () => {
  const store = memoryStore();
  const now = 9 * DAY;
  recordTileClick(store, "radio", now - 6 * DAY);
  recordTileClick(store, "radio", now - 2 * DAY);
  assert.deepEqual(idleDays(store, now), { radio: 2 });
});
