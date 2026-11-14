/** `plex_resources` 返回的服务器候选里，表单需要的三个字段。 */
export interface PlexServerLike {
  url: string;
  token: string;
  name: string;
}

/** 选中服务器后写进「音乐来源」表单的内容。 */
export interface PlexSourceDraft {
  kind: "plex";
  path: string;
  secret: string;
  name: string;
}

/** 去掉末尾斜杠再补一个，让后端拿到的根地址形态稳定。 */
export function plexRootUrl(url: string): string {
  return `${url.replace(/\/+$/, "")}/`;
}

/**
 * 选中服务器后要写进表单的值。
 *
 * `kind` 必须是 "plex"。留着上一次选的 "local"，点「连接曲库」就会走本地扫描分支，
 * 把 `http://…` 当文件路径递归扫一遍，结果是一首也扫不出来——这是 0.9.0 的 P0 缺陷，
 * 0.9.1 修好但当时只有代码复核，没有测试拦着。这条注释和 `plex.test.ts` 一起守着它。
 */
export function plexSourceDraft(server: PlexServerLike): PlexSourceDraft {
  return {
    kind: "plex",
    path: plexRootUrl(server.url),
    secret: server.token,
    name: server.name,
  };
}

/** 选中的音乐库分区 key。没有分区时给空串，后端据此报「分区不存在」。 */
export function plexSectionKey(
  sections: { key: string }[],
  index: number,
): string {
  if (!Number.isInteger(index) || index < 0 || index >= sections.length) return "";
  return sections[index]?.key ?? "";
}

/** 来源显示名：带上音乐库名，方便一个服务器挂多个库时区分。 */
export function plexSourceName(serverName: string, sectionTitle: string): string {
  const name = serverName.trim();
  const title = sectionTitle.trim();
  if (!title) return name;
  return `${name} · ${title}`;
}
