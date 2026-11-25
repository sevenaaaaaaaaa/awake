import test from "node:test";
import assert from "node:assert/strict";

import {
  composeHome,
  IDLE_DAYS_LIMIT,
  MAX_TILES,
  SHELF_MIN_TRACKS,
  TODAY_MIN_TRACKS,
  type HomeSnapshot,
} from "./homeLayout.ts";

function base(overrides: Partial<HomeSnapshot> = {}): HomeSnapshot {
  return { trackCount: 500, stationCount: 0, hasCalibration: true, ...overrides };
}

test("空库只给两个入口，不出现一排暂无数据", () => {
  const tiles = composeHome({ trackCount: 0 });
  assert.deepEqual(
    tiles.map((t) => t.kind),
    ["addMusic", "connectRadio"],
  );

  const withRadio = composeHome({ trackCount: 0, stationCount: 120 });
  assert.deepEqual(
    withRadio.map((t) => t.kind),
    ["addMusic", "radio"],
  );
});

test("有未播完的曲目时，继续听排第一", () => {
  const tiles = composeHome(
    base({ continueAt: { title: "夜航", remainingSec: 72 } }),
  );
  assert.equal(tiles[0].kind, "continue");
  assert.equal(tiles[0].title, "夜航");
  assert.match(tiles[0].subtitle, /还剩 1 分钟/);
});

test("待适配为 0 时整块消失，而不是显示「暂无」", () => {
  const none = composeHome(base({ pendingAdapt: 0 }));
  assert.equal(none.some((t) => t.kind === "adapt"), false);

  const some = composeHome(base({ pendingAdapt: 32 }));
  const adapt = some.find((t) => t.kind === "adapt");
  assert.ok(adapt);
  assert.match(adapt.title, /32 首/);
});

test("今日一首要过库容门槛", () => {
  const small = composeHome(base({ trackCount: TODAY_MIN_TRACKS, today: "某曲" }));
  assert.equal(small.some((t) => t.kind === "today"), false);
  const big = composeHome(base({ trackCount: TODAY_MIN_TRACKS + 1, today: "某曲" }));
  assert.equal(big.some((t) => t.kind === "today"), true);
});

test("专架要过 8 首门槛，且理由写明命中数", () => {
  const below = composeHome(base({ shelves: { classical: SHELF_MIN_TRACKS - 1 } }));
  assert.equal(below.some((t) => t.kind === "shelf"), false);

  const above = composeHome(
    base({ shelves: { classical: SHELF_MIN_TRACKS, light: 3, live: 12 } }),
  );
  const shelf = above.find((t) => t.kind === "shelf");
  assert.ok(shelf);
  assert.match(shelf.title, /古典 8 首/);
  assert.match(shelf.title, /现场 12 首/);
  assert.doesNotMatch(shelf.title, /轻音乐/, "没到门槛的不许露出来");
  assert.match(shelf.reason, /古典命中 8 首/);
});

test("连续 3 天没点会自动降权，钉住可以抵消", () => {
  const dropped = composeHome(
    base({ today: "某曲", idleDays: { today: IDLE_DAYS_LIMIT } }),
  );
  assert.equal(dropped.some((t) => t.kind === "today"), false);

  const pinned = composeHome(
    base({
      today: "某曲",
      idleDays: { today: IDLE_DAYS_LIMIT },
      pinned: ["today"],
    }),
  );
  assert.equal(pinned[0].kind, "today", "钉住的排最前且不降权");
});

test("首屏最多 6 块，且每块都有非空理由", () => {
  const tiles = composeHome(
    base({
      continueAt: { title: "夜航", remainingSec: 60 },
      pendingAdapt: 10,
      today: "某曲",
      shelves: { classical: 20, light: 10, live: 9 },
      stationCount: 300,
      hasCalibration: false,
    }),
  );
  assert.ok(tiles.length <= MAX_TILES, `tile 数 ${tiles.length} 超过上限`);
  for (const tile of tiles) {
    assert.ok(tile.reason.trim().length > 0, `${tile.kind} 缺少理由`);
    assert.ok(tile.title.trim().length > 0, `${tile.kind} 缺少标题`);
  }
});

test("同样的输入永远同样的输出", () => {
  const snapshot = base({
    continueAt: { title: "夜航", remainingSec: 60 },
    pendingAdapt: 3,
    today: "某曲",
    shelves: { classical: 9 },
    stationCount: 10,
  });
  assert.deepEqual(composeHome(snapshot), composeHome(snapshot));
});
