import test from "node:test";
import assert from "node:assert/strict";

import { aggregateGaps } from "./gaps.ts";
import type { ImportMatch } from "./types.ts";

function imported(title: string, artist: string): ImportMatch["track"] {
  return {
    title,
    artist,
    album: "",
    duration: 200,
    file_name: null,
    segment_start: null,
    segment_end: null,
    number: null,
  };
}

function hit(track: ImportMatch["track"]): ImportMatch {
  return { track, song_id: "song-1", score: 0.9, reason: "标题与艺人一致" };
}

function miss(track: ImportMatch["track"]): ImportMatch {
  return { track, song_id: null, score: 0, reason: "本地曲库没有匹配" };
}

// 下面几条与 rust/crates/awake-app/src/playlist_import.rs 的 gap_tests 一一对应：
// 桌面版走后端，浏览器预览走这里，同一个面板不能有两种答案。

test("空输入：总数与缺口都是 0，不出空分组", () => {
  const gaps = aggregateGaps([]);
  assert.deepEqual(gaps, { total: 0, matched: 0, missing: 0, artists: [] });
});

test("只聚合没匹配上的，匹配数量单独记", () => {
  const gaps = aggregateGaps([
    hit(imported("晴天", "周杰伦")),
    miss(imported("七里香", "周杰伦")),
    miss(imported("Yellow", "Coldplay")),
  ]);
  assert.equal(gaps.total, 3);
  assert.equal(gaps.matched, 1);
  assert.equal(gaps.missing, 2);
  assert.deepEqual(gaps.artists.map((a) => a.artist).sort(), ["Coldplay", "周杰伦"]);
});

test("空艺人回落「未知艺人」，每组曲名最多 5 条，条数按缺口数算", () => {
  const matches: ImportMatch[] = [];
  for (let i = 0; i < 9; i += 1) matches.push(miss(imported(`曲目 ${i}`, "  ")));
  const gaps = aggregateGaps(matches);
  assert.equal(gaps.artists.length, 1);
  assert.equal(gaps.artists[0].artist, "未知艺人");
  assert.equal(gaps.artists[0].missing, 9);
  assert.equal(gaps.artists[0].titles.length, 5, "每组的曲名只留 5 个，够提示就行");
});

test("标题为空的曲目占缺口数但不占曲名槽位", () => {
  const gaps = aggregateGaps([
    miss(imported("", "某人")),
    miss(imported("真的歌名", "某人")),
  ]);
  assert.equal(gaps.artists[0].missing, 2);
  assert.deepEqual(gaps.artists[0].titles, ["真的歌名"]);
});

test("全部匹配时不提示扫描", () => {
  const gaps = aggregateGaps([
    hit(imported("晴天", "周杰伦")),
    hit(imported("Yellow", "Coldplay")),
  ]);
  assert.equal(gaps.missing, 0);
  assert.deepEqual(gaps.artists, []);
});

test("排序：缺得多的在前，同数量按艺人码点序：桌面版和浏览器版顺序一致", () => {
  const matches: ImportMatch[] = [
    miss(imported("a", "B 艺人")),
    miss(imported("b", "A 艺人")),
    miss(imported("c", "C 艺人")),
    miss(imported("d", "C 艺人")),
  ];
  const gaps = aggregateGaps(matches);
  assert.deepEqual(gaps.artists.map((a) => a.artist), ["C 艺人", "A 艺人", "B 艺人"]);
});

test("艺人数封顶 20 组", () => {
  const matches: ImportMatch[] = [];
  for (let i = 0; i < 30; i += 1) matches.push(miss(imported(`歌 ${i}`, `艺人 ${String(i).padStart(2, "0")}`)));
  const gaps = aggregateGaps(matches);
  assert.equal(gaps.missing, 30);
  assert.equal(gaps.artists.length, 20);
});
