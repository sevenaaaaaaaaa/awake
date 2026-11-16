import test from "node:test";
import assert from "node:assert/strict";
import {
  filterAfterConnect,
  recentlyAdded,
  sourceAlbums,
  sourceFilterOptions,
  sourceStatusLine,
  sourceTracks,
} from "./sources.ts";
import type { Album, Source, Track } from "./types.ts";

function track(partial: Partial<Track>): Track {
  return {
    id: partial.id ?? "t",
    title: partial.title ?? "曲",
    artist: "",
    album_artist: "",
    album: partial.album ?? "",
    genre: "",
    year: null,
    track_number: null,
    disc_number: null,
    duration: 180,
    sample_rate: 44100,
    bit_depth: 16,
    channels: 2,
    codec: "flac",
    source_id: partial.source_id ?? "s1",
    locator: partial.locator ?? "a.flac",
    file_size: 1,
    artwork_path: null,
    play_count: 0,
    favorite: false,
    is_remote: false,
    added_at: partial.added_at,
  };
}

test("只显示某个来源时，曲目按 source_id 收窄", () => {
  const tracks = [
    track({ id: "a", source_id: "plex" }),
    track({ id: "b", source_id: "local" }),
  ];
  assert.deepEqual(
    sourceTracks(tracks, "plex").map((t) => t.id),
    ["a"],
  );
  assert.equal(sourceTracks(tracks, "").length, 2, "空筛选等于全部来源");
});

test("专辑格子跟着来源收窄，不会出现空专辑", () => {
  const local = track({ id: "a", source_id: "local" });
  const plex = track({ id: "b", source_id: "plex" });
  const albums: Album[] = [
    { id: "1", title: "本地", artist: "", year: null, artwork_path: null, tracks: [local] },
    { id: "2", title: "Plex", artist: "", year: null, artwork_path: null, tracks: [plex] },
  ];
  assert.deepEqual(
    sourceAlbums(albums, "plex").map((album) => album.id),
    ["2"],
  );
  assert.equal(sourceAlbums(albums, "").length, 2);
});

test("最近添加按加入时间倒序，刚连上的来源排最前", () => {
  const tracks = [
    track({ id: "old", added_at: 100 }),
    track({ id: "new", added_at: 900 }),
    track({ id: "none" }),
  ];
  assert.deepEqual(
    recentlyAdded(tracks).map((t) => t.id),
    ["new", "old"],
  );
  assert.equal(recentlyAdded(tracks, 1).length, 1);
});

test("来源状态行说清楚多少首、上次什么时候更新", () => {
  const source: Source = {
    id: "s",
    kind: "plex",
    name: "客厅",
    url: "https://nas.local:32400",
    track_count: 42,
  };
  assert.match(sourceStatusLine(source), /42 首/);
  assert.match(sourceStatusLine(source), /还没有扫描过/);
  const scanned = { ...source, last_scan: Date.UTC(2026, 0, 2, 3, 4) };
  assert.match(sourceStatusLine(scanned), /上次更新/);
});

test("筛选条永远带「全部来源」，连接后自动选中新来源", () => {
  const sources: Source[] = [
    { id: "a", kind: "local", name: "本地", url: "/m", track_count: 1 },
  ];
  assert.deepEqual(sourceFilterOptions(sources), [
    { id: "", label: "全部来源" },
    { id: "a", label: "本地" },
  ]);
  assert.equal(filterAfterConnect("a"), "a");
  assert.equal(filterAfterConnect(""), "", "没有来源时退回全部");
});
