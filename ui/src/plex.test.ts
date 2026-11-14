import test from "node:test";
import assert from "node:assert/strict";

import {
  plexRootUrl,
  plexSectionKey,
  plexSourceDraft,
  plexSourceName,
} from "./plex.ts";

const server = {
  url: "https://plex.example.com:32400",
  token: "token-abc",
  name: "客厅 NAS",
};

// 0.9.0 的 P0：applyPlexServer() 只填了地址 / Token / 名称，kind 留在上一次选的 "local"，
// 于是「连接曲库」走本地扫描分支，把 https://… 当文件夹扫，一首也扫不出来。
// 这条用例就是那次的回归锁：kind 一旦不是 "plex"，它先红。
test("选中服务器后来源类型必须是 plex，不能留成上一次选的 local", () => {
  const draft = plexSourceDraft(server);
  assert.equal(draft.kind, "plex");
  assert.notEqual(draft.kind, "local");
});

test("连接分支判定：draft 只会进 plex 分支，不会进本地扫描分支", () => {
  const draft = plexSourceDraft(server);
  // 与 App.vue connectSource() 的分支条件保持一致。
  const takesLocalScan = draft.kind === "local" || draft.kind === "smb";
  const takesFeed = draft.kind === "rss";
  assert.equal(takesLocalScan, false, "Plex 地址被当成文件夹扫就是 0.9.0 的那个 bug");
  assert.equal(takesFeed, false);
});

test("地址归一化：末尾斜杠折叠成一个，根地址形态稳定", () => {
  assert.equal(plexRootUrl("https://a.example.com:32400"), "https://a.example.com:32400/");
  assert.equal(plexRootUrl("https://a.example.com:32400/"), "https://a.example.com:32400/");
  assert.equal(plexRootUrl("https://a.example.com:32400///"), "https://a.example.com:32400/");
  assert.equal(plexSourceDraft({ ...server, url: "https://a.example.com///" }).path,
    "https://a.example.com/");
});

test("Token 只放进 secret 字段，不拼进地址", () => {
  const draft = plexSourceDraft(server);
  assert.equal(draft.secret, "token-abc");
  assert.equal(draft.path.includes("token-abc"), false, "Token 不进资源 URL");
  assert.equal(draft.name, "客厅 NAS");
});

test("分区 key：越界与未选时给空串，选中时给对应 key", () => {
  const sections = [{ key: "1" }, { key: "7" }];
  assert.equal(plexSectionKey(sections, 0), "1");
  assert.equal(plexSectionKey(sections, 1), "7");
  assert.equal(plexSectionKey(sections, -1), "");
  assert.equal(plexSectionKey(sections, 2), "");
  assert.equal(plexSectionKey([], 0), "");
  assert.equal(plexSectionKey(sections, 1.5), "");
  assert.equal(plexSectionKey(sections, Number.NaN), "");
});

test("来源显示名带上音乐库，便于同一服务器挂多个库时区分", () => {
  assert.equal(plexSourceName("客厅 NAS", "音乐"), "客厅 NAS · 音乐");
  assert.equal(plexSourceName("客厅 NAS", ""), "客厅 NAS");
  assert.equal(plexSourceName(" 客厅 NAS ", "  "), "客厅 NAS");
});
