import test from "node:test";
import assert from "node:assert/strict";

import {
  insightSummary,
  loadInsight,
  shelfLine,
  type AdaptQueue,
  type InsightCaller,
  type ShelfGroup,
} from "./insight.ts";

const queue: AdaptQueue = {
  library_total: 412,
  with_curve: 2,
  queued: 410,
  blocked_by_reference: true,
  batches: [
    {
      key: "none:rock",
      label: "rock · 300 首",
      shelf: "None",
      count: 300,
      reason: "先做一次校准，这批才有参照物",
      track_ids: ["a"],
    },
  ],
};

test("报告卡的一行话只报能核对的数字", () => {
  const line = insightSummary(queue);
  assert.match(line, /库里 412 首/);
  assert.match(line, /已有曲线 2 首/);
  assert.match(line, /待适配 410 首（1 批）/);
  assert.match(line, /先做一次校准/);
});

test("没有数据时不说「0 首」，直接说没有", () => {
  assert.equal(insightSummary(null), "还没有可核对的数据");
});

test("队列空了就不提校准", () => {
  const clean: AdaptQueue = { ...queue, queued: 0, batches: [] };
  const line = insightSummary(clean);
  assert.match(line, /没有待适配的曲目/);
  assert.doesNotMatch(line, /校准/);
});

test("专架行把依据摆出来，没有依据就写横线", () => {
  const group: ShelfGroup = {
    key: "classical",
    label: "古典",
    count: 12,
    track_ids: [],
    reasons: ["genre:classical", "work-number"],
  };
  assert.equal(shelfLine(group), "古典 · 12 首 · 依据：genre:classical、work-number");
  assert.match(shelfLine({ ...group, reasons: [] }), /依据：—$/);
});

test("取数失败退回空值，不把白屏带给预览模式", async () => {
  const failing: InsightCaller = async () => {
    throw new Error("没有这个命令");
  };
  const data = await loadInsight(failing);
  assert.deepEqual(data.shelves, []);
  assert.equal(data.queue, null);
  assert.deepEqual(data.artists, []);
});

test("取数成功时原样透传", async () => {
  const caller: InsightCaller = async (command) => {
    if (command === "shelf_overview") return [{ key: "light", label: "轻音乐", count: 8, track_ids: [], reasons: ["genre:light"] }] as any;
    if (command === "adapt_queue") return queue as any;
    return [{ artist: "A", plays: 3 }] as any;
  };
  const data = await loadInsight(caller);
  assert.equal(data.shelves.length, 1);
  assert.equal(data.queue?.queued, 410);
  assert.equal(data.artists.length, 1);
});
