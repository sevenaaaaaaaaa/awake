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

/** `plex_account_get` 返回的账号状态：授权过就记在磁盘上，重启后照旧可用。 */
export interface PlexAccount {
  signed_in: boolean;
  client_id: string;
  token: string;
  server_url: string;
  server_name: string;
  section_key: string;
  section_title: string;
  saved_at: number;
}

/**
 * 账号状态的一句话，直接显示在「音乐来源 → Plex」里。
 * 用户要能一眼看出「这次不用重新登录」。
 */
export function plexAccountLabel(account: PlexAccount | null | undefined): string {
  if (!account || !account.signed_in) return "还没有登录 Plex";
  const parts = ["已登录"];
  if (account.server_name.trim()) parts.push(account.server_name.trim());
  if (account.section_title.trim()) parts.push(account.section_title.trim());
  return parts.join(" · ");
}

function normaliseUrl(url: string): string {
  return url.trim().replace(/\/+$/, "").toLowerCase();
}

/**
 * 上次用的服务器在候选列表里的位置。按地址匹配（忽略末尾斜杠与大小写），
 * 找不到就退回第一条 —— 服务器换了线路也不该让用户面对一个空选择框。
 */
export function plexServerIndexFor(
  account: PlexAccount | null | undefined,
  servers: { url: string }[],
): number {
  if (!servers.length) return -1;
  const want = normaliseUrl(account?.server_url ?? "");
  if (!want) return 0;
  const index = servers.findIndex((server) => normaliseUrl(server.url) === want);
  return index >= 0 ? index : 0;
}

/** 上次选的音乐库在分区列表里的位置，规则同上。 */
export function plexSectionIndexFor(
  account: PlexAccount | null | undefined,
  sections: { key: string }[],
): number {
  if (!sections.length) return -1;
  const want = (account?.section_key ?? "").trim();
  if (!want) return 0;
  const index = sections.findIndex((section) => section.key === want);
  return index >= 0 ? index : 0;
}

/** 来源显示名：带上音乐库名，方便一个服务器挂多个库时区分。 */
export function plexSourceName(serverName: string, sectionTitle: string): string {
  const name = serverName.trim();
  const title = sectionTitle.trim();
  if (!title) return name;
  return `${name} · ${title}`;
}
