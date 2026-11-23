<script setup lang="ts">
import {
  computed,
  nextTick,
  onMounted,
  onUnmounted,
  reactive,
  ref,
  watch,
} from "vue";
import Icon from "./Icon.vue";
import Appearance from "./Appearance.vue";
import SoundChain from "./SoundChain.vue";
import MediaInspector from "./MediaInspector.vue";
import TelegramSource from "./TelegramSource.vue";
import TelegramSponsored from "./TelegramSponsored.vue";
import StageInstrument from "./StageInstrument.vue";
import EqCurveEditor from "./EqCurveEditor.vue";
import { BYPASS_KEY, flatGains, hasAudibleEq, isBypassKey } from "./bypassKey";
import Artwork from "./Artwork.vue";
import TrackList from "./TrackList.vue";
import SwipeMode from "./SwipeMode.vue";
import PlaylistImport from "./PlaylistImport.vue";
import DataTransfer from "./DataTransfer.vue";
import BooksView from "./BooksView.vue";
import WeeklySummary from "./WeeklySummary.vue";
import PluginSearch from "./PluginSearch.vue";
import {
  invalidatePlugin,
  parsePluginRegistry,
  pluginFileNameFromURL,
  validatePluginCode,
  type PluginRegistryEntry,
} from "./plugins";
import { useAwake } from "./useAwake";
import { call, desktop } from "./bridge";
import {
  plexAccountLabel,
  plexSectionIndexFor,
  plexSectionKey,
  plexServerIndexFor,
  plexSourceDraft,
  plexSourceName,
  type PlexAccount,
} from "./plex";
import {
  filterAfterConnect,
  recentlyAdded,
  sourceAlbums,
  sourceFilterOptions,
  sourceStatusLine,
  sourceTracks,
} from "./sources";
import { APP_VERSION_LINE } from "./version";
import {
  aiPresets,
  libraryCoverage,
  listeningAchievements,
  type Achievement,
  type AiPreset,
  type Coverage,
} from "./bridge";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { listen } from "@tauri-apps/api/event";
import {
  duration,
  format,
  frequencies,
  type Track,
  type Album,
  type Source,
  type Playlist,
  type PlaylistEntry,
  type Book,
  type WeeklySummary as Weekly,
} from "./types";

const s = reactive(useAwake());
const editingMedia = ref<Track | null>(null);
type View =
  | "appearance"
  | "home"
  | "library"
  | "favorites"
  | "agent"
  | "sources"
  | "sound"
  | "studio"
  | "stage"
  | "books"
  | "summary"
  | "playlist";
const view = ref<View>("home"),
  libraryMode = ref("albums"),
  /** 曲库页按来源收窄：空串表示全部来源。 */
  librarySource = ref(""),
  query = ref("");
const album = ref<Album | null>(null),
  playlistId = ref(""),
  queueOpen = ref(false),
  commandOpen = ref(false),
  sourceOpen = ref(false),
  swipeOpen = ref(false),
  importOpen = ref(false),
  dataOpen = ref(false);
const sourcePath = ref(""),
  saveOpen = ref(false),
  playlistName = ref(""),
  saveSmart = ref(true);
/** 本地内置版：包内示例的状态与两个维护动作。 */
const builtinStatus = ref<{ available: number; imported: number; seeded: boolean } | null>(null);
const builtinBusy = ref(false);
const builtinNote = ref("");
async function refreshBuiltinStatus() {
  if (!desktop) return;
  try {
    builtinStatus.value = await call("builtin_demo_status");
  } catch {
    builtinStatus.value = null;
  }
}
async function installBuiltinDemo() {
  if (!desktop || builtinBusy.value) return;
  builtinBusy.value = true;
  builtinNote.value = "";
  try {
    const added = await call<number>("builtin_demo_install");
    builtinNote.value = `已导入 ${added} 首`;
    await s.refresh();
  } catch (error) {
    builtinNote.value = String(error);
  } finally {
    builtinBusy.value = false;
    await refreshBuiltinStatus();
  }
}
async function removeBuiltinDemo() {
  if (!desktop || builtinBusy.value) return;
  if (!confirm("只移除包内示例那一批曲目？其余本地导入会保留。")) return;
  builtinBusy.value = true;
  builtinNote.value = "";
  try {
    const removed = await call<number>("builtin_demo_remove");
    builtinNote.value = `已移除 ${removed} 首内置示例`;
    await s.refresh();
  } catch (error) {
    builtinNote.value = String(error);
  } finally {
    builtinBusy.value = false;
    await refreshBuiltinStatus();
  }
}
async function clearLocalRecords() {
  if (!desktop || builtinBusy.value) return;
  if (!confirm("删除本机导入的曲目（含内置示例）？远程来源与设置会保留。")) return;
  builtinBusy.value = true;
  builtinNote.value = "";
  try {
    const removed = await call<number>("local_records_clear");
    builtinNote.value = `已清空 ${removed} 首`;
    await s.refresh();
  } catch (error) {
    builtinNote.value = String(error);
  } finally {
    builtinBusy.value = false;
    await refreshBuiltinStatus();
  }
}
const useCloud = ref(false),
  curatorEndpoint = ref("https://api.openai.com/v1"),
  curatorModel = ref(""),
  curatorKey = ref("");
const musicEndpoint = ref("https://api.elevenlabs.io/v1/music"),
  musicModel = ref("music_v1"),
  musicKey = ref("");
watch(
  () => s.services,
  (settings) => {
    if (settings.curator) {
      curatorEndpoint.value = settings.curator.endpoint;
      curatorModel.value = settings.curator.model;
    }
    if (settings.music) {
      musicEndpoint.value = settings.music.endpoint;
      musicModel.value = settings.music.model;
    }
  },
  { deep: true },
);
const generationDuration = ref(30),
  instrumental = ref(true),
  usePreferences = ref(true);
async function saveAIService(kind: "curator" | "music") {
  await s.run(async () => {
    s.services = await call("save_service", {
      req: {
        kind,
        endpoint:
          kind === "curator" ? curatorEndpoint.value : musicEndpoint.value,
        model: kind === "curator" ? curatorModel.value : musicModel.value,
        api_key: kind === "curator" ? curatorKey.value : musicKey.value,
      },
    });
    curatorKey.value = "";
    musicKey.value = "";
    s.toast("服务配置已保存，密钥保存在系统钥匙串");
  });
}
async function generateTrack() {
  await s.run(async () => {
    await call("start_generation", {
      prompt: studioPrompt.value,
      durationSeconds: generationDuration.value,
      instrumental: instrumental.value,
      usePreferences: usePreferences.value,
    });
    await s.refreshTaste();
    s.toast("已提交创作任务，完成后自动保存到曲库");
  });
}
async function cancelGeneration(id: string) {
  await s.run(async () => {
    await call("cancel_generation", { id });
    s.toast("已请求停止接收；已发出的服务请求可能仍产生费用");
  });
}
function playGeneration(id: string | null) {
  const track = s.tracks.find((t) => t.id === id);
  if (track) void s.start(track, [track]);
}
async function revealGeneration(id: string) {
  await s.run(async () => {
    await call("reveal_generation", { id });
  });
}
const jobLabel = (state: string) =>
  ({
    queued: "等待提交",
    running: "正在生成",
    completed: "作品已保存",
    failed: "生成失败",
    cancelled: "已停止",
    interrupted: "任务中断",
  })[state] || state;
/** 添加来源分两步：先选类型，再只填这一类需要的字段。 */
const sourceStep = ref<"type" | "fields">("type");
const sourceTypes = [
  { kind: "local", icon: "folder", label: "本地文件夹", hint: "原地读取，不复制、不移动" },
  { kind: "smb", icon: "database", label: "NAS / 已挂载网盘", hint: "挂载点直接扫描" },
  { kind: "webdav", icon: "wave", label: "WebDAV", hint: "自己的网盘或 NAS" },
  { kind: "plex", icon: "play", label: "Plex", hint: "用 Plex 账号授权" },
  { kind: "telegram", icon: "mic", label: "Telegram 个人媒体库", hint: "自托管连接器" },
  { kind: "plugin", icon: "spark", label: "网络音乐插件", hint: "MusicFree 兼容 .js" },
  { kind: "rss", icon: "list", label: "RSS / Atom 元数据匹配", hint: "只匹配元数据，不下载音频" },
];
function chooseSourceType(kind: string) {
  sourceKind.value = kind;
  sourceStep.value = "fields";
}
const sourceKind = ref("local"),
  sourceName = ref(""),
  sourceUsername = ref(""),
  sourceSecret = ref("");
/** 网络音乐插件（枪弹分离）：选中的插件代码、文件名与试运行结果。 */
const pluginCode = ref(""),
  pluginFileName = ref(""),
  pluginPlatform = ref(""),
  pluginError = ref(""),
  pluginRegistryURL = ref(
    "https://fastly.jsdelivr.net/gh/Huibq/keep-alive/Music_Free/myPlugins.json"),
  pluginRegistry = ref<PluginRegistryEntry[]>([]),
  registryBusy = ref(false),
  registryError = ref("");
/** 正在搜索的插件来源：非空时打开搜索面板。 */
const pluginSearchSource = ref<Source | null>(null);
function resetPluginDraft() {
  pluginCode.value = "";
  pluginFileName.value = "";
  pluginPlatform.value = "";
  pluginError.value = "";
}
async function readPluginFile(event: Event) {
  const input = event.target as HTMLInputElement;
  const file = input.files?.[0];
  resetPluginDraft();
  if (!file) return;
  if (file.size > 512 * 1024) {
    pluginError.value = "插件文件超过 512 KB，请确认这是音乐插件";
    input.value = "";
    return;
  }
  try {
    const code = await file.text();
    const info = validatePluginCode(code);
    pluginCode.value = code;
    pluginFileName.value = file.name;
    pluginPlatform.value = info.platform || "未命名插件";
    if (!info.hasSearch) {
      pluginError.value = "这个插件没有 search 接口，只能解析固定来源";
    }
  } catch (error) {
    pluginError.value = String(error).replace(/^Error: /, "");
  }
  input.value = "";
}
async function openPluginSearch(source: Source) {
  pluginSearchSource.value = source;
}
async function onPluginImported() {
  await s.refresh();
}
const correctionName = ref(""),
  measurementSource = ref(""),
  correctionTarget = ref(""),
  correctionText = ref("");
const activeCorrection = computed(() =>
  s.taste.headphone_profiles.find(
    (p) => p.id === s.taste.active_corrections[s.deviceKey || s.device],
  ),
);
const processing = computed(
  () => s.gains.some((g) => g !== 0) || !!activeCorrection.value,
);
async function resetSound() {
  if (desktop) await selectCorrection("");
  await s.preset("flat");
}
const sourceLabel = (kind: string) =>
  ({
    local: "本地文件夹",
    smb: "NAS / 网盘挂载目录",
    webdav: "WebDAV",
    plex: "Plex",
    telegram: "Telegram 个人媒体库",
    plugin: "网络音乐插件",
  })[kind] || kind;
const telegramReady = computed(() => /\/v1\/libraries\/[a-f0-9]{24}\/?$/.test(sourcePath.value));
const activeTelegramSource = computed(() => s.sources.find(source => source.id === s.now?.source_id && source.kind === "telegram"));
interface PlexServer {
  name: string;
  client_identifier: string;
  url: string;
  token: string;
  local: boolean;
  relay: boolean;
  connection: string;
}
interface PlexSection {
  key: string;
  title: string;
}
const trustSelfSigned = ref(false);
const plex = reactive({
  busy: false,
  polling: false,
  probing: false,
  status: "",
  error: "",
  token: "",
  signedIn: false,
  savedAt: 0,
  account: null as PlexAccount | null,
  servers: [] as PlexServer[],
  sections: [] as PlexSection[],
  serverIndex: -1,
  sectionIndex: -1,
});
let plexTimer: number | undefined;
function plexClientId(): string {
  const stored = localStorage.getItem("awake-plex-client-id");
  if (stored) return stored;
  const id = (
    globalThis.crypto?.randomUUID?.() ??
    `${Date.now()}-${Math.random().toString(16).slice(2)}`
  ).toUpperCase();
  localStorage.setItem("awake-plex-client-id", id);
  return id;
}
function stopPlexPoll() {
  if (plexTimer !== undefined) window.clearTimeout(plexTimer);
  plexTimer = undefined;
  plex.polling = false;
}
function cancelPlexLogin() {
  stopPlexPoll();
  plex.status = "已停止等待 Plex 授权";
}
async function loadPlexSections() {
  const server = plex.servers[plex.serverIndex];
  if (!server) return;
  plex.sections = [];
  plex.sectionIndex = -1;
  try {
    plex.sections = await call<PlexSection[]>("plex_sections", {
      token: server.token,
      url: server.url,
    });
    if (plex.sections.length) {
      plex.sectionIndex = 0;
      plex.status = "选择服务器与音乐库，确认后点击“连接曲库”";
    } else {
      plex.status = "这个服务器上没有 Plex 音乐库";
    }
  } catch (e) {
    plex.error = String(e);
  }
}
async function applyPlexServer() {
  const server = plex.servers[plex.serverIndex];
  if (!server) return;
  // 来源类型必须一起换成 plex，否则「连接曲库」会走本地扫描分支（0.9.0 的 P0）。
  const draft = plexSourceDraft(server);
  sourceKind.value = draft.kind;
  sourcePath.value = draft.path;
  sourceSecret.value = draft.secret;
  sourceName.value = draft.name;
  plex.error = "";
  plex.sections = [];
  plex.sectionIndex = -1;
  if (!desktop) {
    plex.status = "服务器地址与 Token 已填入，可点击“连接曲库”";
    return;
  }
  plex.probing = true;
  try {
    const reachable = await call<boolean>("plex_probe", {
      url: server.url,
      token: server.token,
    });
    if (!reachable) throw new Error("服务器拒绝了这次访问");
    plex.status = "线路可用，正在读取音乐库…";
  } catch (reason) {
    plex.error =
      "这条线路连不上（" +
      String(reason).replace(/^Error: /, "") +
      "），换一条线路再试。";
  } finally {
    plex.probing = false;
  }
  await loadPlexSections();
}
function applyPlexSection() {
  const server = plex.servers[plex.serverIndex];
  const section = plex.sections[plex.sectionIndex];
  if (server && section) sourceName.value = plexSourceName(server.name, section.title);
}
async function loadPlexResources(clientId: string, token: string) {
  plex.status = "正在读取 Plex 服务器…";
  plex.token = token;
  plex.servers = await call<PlexServer[]>("plex_resources", { clientId, token });
  if (!plex.servers.length) {
    plex.status = "这个 Plex 账号下没有可用的服务器，请确认服务器在线并已分享给该账号";
    return;
  }
  plex.serverIndex = 0;
  // 默认选中第一个服务器并填入地址 / Token；不做自动连接或扫描。
  await applyPlexServer();
}
async function retryPlexResources() {
  if (!plex.token) {
    plex.error = "请先重新用 Plex 账号登录";
    return;
  }
  plex.error = "";
  try {
    await loadPlexResources(plexClientId(), plex.token);
  } catch (reason) {
    plex.error = "读取 Plex 服务器失败：" + String(reason).replace(/^Error: /, "");
  }
}

/**
 * 启动时恢复 Plex 登录。授权一次之后，Token 与上次的服务器 / 音乐库都在磁盘上，
 * 这里直接用它们列服务器 —— 不打开浏览器，也不用用户再点一次登录。
 */
async function restorePlexAccount() {
  if (!desktop) return;
  try {
    const account = await call<PlexAccount>("plex_account_get");
    plex.account = account;
    plex.signedIn = account.signed_in;
    plex.savedAt = account.saved_at;
    if (!account.signed_in) return;
    plex.token = account.token;
    if (account.client_id) localStorage.setItem("awake-plex-client-id", account.client_id);
    plex.status = "已恢复上次的 Plex 登录，正在读取服务器…";
    await loadPlexResources(account.client_id || plexClientId(), account.token);
    plex.serverIndex = plexServerIndexFor(account, plex.servers);
    if (plex.serverIndex >= 0) await applyPlexServer();
    plex.sectionIndex = plexSectionIndexFor(account, plex.sections);
    if (plex.sectionIndex >= 0) applyPlexSection();
    plex.status = plexAccountLabel(account) + " · 选好音乐库就能直接连接";
  } catch (reason) {
    plex.signedIn = false;
    plex.servers = [];
    plex.sections = [];
    plex.serverIndex = -1;
    plex.sectionIndex = -1;
    plex.error =
      "上次的 Plex 登录已失效（可能是 Plex 端撤销了授权），重新登录一次即可：" +
      String(reason).replace(/^Error: /, "");
  }
}
async function forgetPlexAccount() {
  await s.run(async () => {
    await call("plex_account_forget");
    plex.signedIn = false;
    plex.token = "";
    plex.account = null;
    plex.servers = [];
    plex.sections = [];
    plex.serverIndex = -1;
    plex.sectionIndex = -1;
    plex.status = "已退出 Plex 账号；已连接的音乐来源不受影响";
    s.toast("已退出 Plex 账号");
  });
}

interface MusicPathProbe {
  kind: string;
  path: string;
  audio_count: number;
  sample: string[];
  message: string;
}
const sourceProbe = ref<MusicPathProbe | null>(null);
/**
 * 连接之前先验一遍路径：归一化（引号 / file:// / ~ / 末尾斜杠）+ 数一数里面有多少音频。
 * 「选好文件夹却扫不出东西」多数是路径形态或权限问题，这一步把它变成一句人话。
 */
async function checkSourcePath(): Promise<MusicPathProbe | null> {
  if (!desktop) return null;
  // 只有本地来源需要验路径；WebDAV / Plex 的地址由各自的连通性检查负责。
  if (!["local", "smb"].includes(sourceKind.value)) return null;
  if (!sourcePath.value.trim()) {
    sourceProbe.value = null;
    return null;
  }
  const probe = await call<MusicPathProbe>("probe_music_path", {
    path: sourcePath.value,
  });
  sourceProbe.value = probe;
  if (probe.path) sourcePath.value = probe.path;
  return probe;
}

/** 连接成功后跳到曲库，并且只显示这个来源的曲目 —— 「刚加的东西」必须马上看得见。 */
function focusSource(url: string, kind?: string) {
  const normalise = (value: string) => value.trim().replace(/\/+$/, "");
  const source = s.sources.find(
    (item) => normalise(item.url) === normalise(url) && (!kind || item.kind === kind),
  );
  openSourceLibrary(filterAfterConnect(source?.id ?? ""));
}

const removingSource = ref("");
async function removeSource(source: Source) {
  if (removingSource.value !== source.id) {
    removingSource.value = source.id;
    return;
  }
  removingSource.value = "";
  await s.run(async () => {
    await call("remove_source", { id: source.id });
    if (librarySource.value === source.id) librarySource.value = "";
    await s.refresh();
    s.toast("已移除来源：" + source.name);
  });
}

async function connectPlex() {
  const server = plex.servers[plex.serverIndex];
  if (!server || s.busy) return;
  const section = plex.sections[plex.sectionIndex];
  s.busy = true;
  await s.run(async () => {
    const count = await call<number>("connect_source", {
      req: {
        kind: "plex",
        name: section ? `${server.name} · ${section.title}` : server.name,
        url: server.url,
        username: "",
        secret: server.token,
        trust_self_signed: trustSelfSigned.value,
        section: section?.key ?? "",
      },
    });
    sourceSecret.value = "";
    // 连接成功就把账号与所选音乐库记下来：下次启动不用再授权一次。
    await call<PlexAccount>("plex_account_save", {
      clientId: plexClientId(),
      token: server.token,
      serverUrl: server.url,
      serverName: server.name,
      sectionKey: section?.key ?? "",
      sectionTitle: section?.title ?? "",
    })
      .then((account) => {
        plex.account = account;
        plex.signedIn = account.signed_in;
        plex.savedAt = account.saved_at;
      })
      .catch(() => {});
    await s.refresh();
    sourceOpen.value = false;
    focusSource(server.url, "plex");
    s.toast(
      "Plex 曲库已连接：" +
        count +
        " 首" +
        (section ? "（" + section.title + "）" : "") +
        "，已在曲库中显示",
    );
  });
  s.busy = false;
}

async function startPlexLogin() {
  if (!desktop || plex.busy || plex.polling) return;
  plex.busy = true;
  plex.error = "";
  plex.status = "";
  plex.servers = [];
  plex.sections = [];
  plex.serverIndex = -1;
  plex.sectionIndex = -1;
  try {
    const clientId = plexClientId();
    const pin = await call<{ id: number; code: string; auth_token: string | null }>(
      "plex_pin_create",
      { clientId },
    );
    await call("plex_open_auth", { clientId, code: pin.code });
    plex.polling = true;
    plex.status = "已在浏览器打开 Plex 登录页；完成授权后这里会自动继续";
    const deadline = Date.now() + 1_800_000;
    const poll = async () => {
      if (!plex.polling) return;
      if (Date.now() > deadline) {
        stopPlexPoll();
        plex.error = "Plex 登录超时，请重新开始";
        return;
      }
      try {
        const result = await call<{ id: number; code: string; auth_token: string | null }>(
          "plex_pin_poll",
          { clientId, id: pin.id, code: pin.code },
        );
        if (result.auth_token) {
          stopPlexPoll();
          plex.status = "Plex 账号已授权";
          await loadPlexResources(clientId, result.auth_token);
          return;
        }
      } catch (e) {
        plex.error = String(e);
      }
      if (plex.polling) plexTimer = window.setTimeout(poll, 2000);
    };
    plexTimer = window.setTimeout(poll, 2000);
  } catch (e) {
    plex.error = String(e);
    stopPlexPoll();
  } finally {
    plex.busy = false;
  }
}
const sourceConfigError = ref("");
async function importSourceConfig(event: Event) {
  const input = event.target as HTMLInputElement;
  const file = input.files?.[0];
  if (!file) return;
  sourceConfigError.value = "";
  try {
    if (file.size > 65536) throw new Error("配置文件不能超过 64 KB");
    const config = await call<{ kind: string; name: string; url: string; username: string }>("parse_source_configuration", { text: await file.text(), format: file.name.split(".").pop()?.toLowerCase() });
    sourceKind.value = config.kind; sourceName.value = config.name;
    sourcePath.value = config.url; sourceUsername.value = config.username;
    sourceSecret.value = "";
    s.toast("配置已读取，请填写凭据后连接");
  } catch (e) { sourceConfigError.value = String(e); }
  finally { input.value = ""; }
}
/** 载入插件源：一个 JSON 列出若干插件，比让用户逐个找 .js 现实。 */
async function loadPluginRegistry() {
  const url = pluginRegistryURL.value.trim();
  if (!url) return;
  registryBusy.value = true;
  registryError.value = "";
  try {
    const response = await fetch(url);
    if (!response.ok) throw new Error("插件源返回 " + response.status);
    pluginRegistry.value = parsePluginRegistry(await response.json());
  } catch (e) {
    pluginRegistry.value = [];
    registryError.value = String(e).replace(/^Error: /, "");
  } finally {
    registryBusy.value = false;
  }
}

/** 选中一条：下载它的 .js，交给现有校验流程，只是替用户省掉「找文件」这一步。 */
async function pickRegistryPlugin(item: PluginRegistryEntry) {
  registryBusy.value = true;
  registryError.value = "";
  pluginError.value = "";
  try {
    const response = await fetch(item.url);
    if (!response.ok) throw new Error("插件下载失败：" + response.status);
    const code = await response.text();
    if (code.length > 512 * 1024) throw new Error("插件文件超过 512 KB，请确认这是音乐插件");
    const info = validatePluginCode(code);
    pluginCode.value = code;
    pluginFileName.value = pluginFileNameFromURL(item.url);
    pluginPlatform.value = info.platform || item.name;
    if (!sourceName.value.trim()) sourceName.value = item.name;
  } catch (e) {
    pluginError.value = String(e).replace(/^Error: /, "");
  } finally {
    registryBusy.value = false;
  }
}

async function connectSource() {
  if (sourceKind.value === "telegram" && !telegramReady.value) { s.fault = "请先选择 Telegram 频道或收藏夹"; return; }
  if (sourceKind.value === "plugin") {
    if (!pluginCode.value) {
      s.fault = "请先选择一个插件文件（.js，MusicFree 兼容）";
      return;
    }
    s.busy = true;
    await s.run(async () => {
      // 试运行一次：坏插件当场报错，不会把半截来源写进曲库。
      validatePluginCode(pluginCode.value);
      const imported = await call<{ id: string; name: string }>("import_plugin", {
        code: pluginCode.value,
        name: sourceName.value.trim() || null,
      });
      // 同一来源重新导入 = 更新插件：丢掉沙箱缓存，下一次搜索用新代码。
      invalidatePlugin(imported.id);
      await s.refresh();
      sourceOpen.value = false;
      s.toast(`插件来源已添加：${imported.name}，先搜索再入库`);
      resetPluginDraft();
      const source = s.sources.find((item) => item.id === imported.id);
      if (source) pluginSearchSource.value = source;
    });
    s.busy = false;
    return;
  }
  if (sourceKind.value === "local" || sourceKind.value === "smb") {
    // 先验路径，再扫描：路径形态不对或权限被拒时，直接说清楚原因。
    const probe = await checkSourcePath();
    if (probe && probe.audio_count === 0) {
      s.fault = probe.message;
      return;
    }
    await s.scan(sourcePath.value, sourceName.value, sourceKind.value);
    if (!s.fault) {
      sourceOpen.value = false;
      focusSource(sourcePath.value, sourceKind.value);
    }
  } else if (sourceKind.value === "rss") {
    s.busy = true;
    await s.run(async () => {
      await call("subscribe_feed", {
        req: {
          name: sourceName.value,
          url: sourcePath.value,
          username: sourceUsername.value,
          secret: sourceSecret.value,
          source_ids: [...s.sourceFilter],
        },
      });
      sourceSecret.value = "";
      await s.refreshTaste();
      s.toast("订阅已保存，匹配到的曲目已生成歌单");
    });
    s.busy = false;
  } else {
    s.busy = true;
    await s.run(async () => {
      const count = await call<number>("connect_source", {
        req: {
          kind: sourceKind.value,
          name: sourceName.value,
          url: sourcePath.value,
          username: sourceUsername.value,
          secret: sourceSecret.value,
          trust_self_signed: trustSelfSigned.value,
          section:
            sourceKind.value === "plex"
              ? plexSectionKey(plex.sections, plex.sectionIndex)
              : "",
        },
      });
      sourceSecret.value = "";
      await s.refresh();
      sourceOpen.value = false;
      focusSource(sourcePath.value, sourceKind.value);
      s.toast("音乐来源已连接：" + count + " 首，已在曲库中显示");
    });
    s.busy = false;
  }
  if (!s.fault) sourceOpen.value = false;
}
async function importCorrection() {
  await s.run(async () => {
    await call("import_headphone_profile", {
      name: correctionName.value,
      measurementSource: measurementSource.value,
      target: correctionTarget.value,
      text: correctionText.value,
      device: s.deviceKey || s.device,
    });
    await s.refreshTaste();
    s.toast("已启用参数校正，并绑定当前设备");
  });
}
async function selectCorrection(id: string) {
  await s.run(async () => {
    const curve = await call<{ preamp: number }>("select_correction", {
      device: s.deviceKey || s.device,
      profileId: id || null,
    });
    s.preamp = curve.preamp;
    await s.refreshTaste();
  });
}
async function readCorrection(e: Event) {
  const file = (e.target as HTMLInputElement).files?.[0];
  if (file) {
    if (file.size > 65536) {
      s.fault = "参数文件超过 64 KB";
      return;
    }
    correctionText.value = await file.text();
  }
}
const studioPrompt = ref(""),
  briefBusy = ref(false),
  fileInput = ref<HTMLInputElement | null>(null),
  commandInput = ref<HTMLInputElement | null>(null);
const stageSourceName = computed(() => {
  const t = s.now;
  if (!t) return "";
  return (
    s.sources.find((x) => x.id === t.source_id)?.name ??
    (t.is_remote ? "远程来源" : "本机曲库")
  );
});
const stageFacts = computed(() => {
  const t = s.now;
  if (!t) return { format: "—", duration: "—", source: "—", added: "—" };
  const rate = t.sample_rate > 0
    ? `${Number.isInteger(t.sample_rate / 1000) ? t.sample_rate / 1000 : (t.sample_rate / 1000).toFixed(1)} kHz`
    : "";
  const format = [
    t.codec || "音频",
    t.bit_depth > 0 ? `${t.bit_depth} bit` : "",
    rate,
    t.channels > 0 ? (t.channels === 1 ? "单声道" : `${t.channels} 声道`) : "",
  ].filter(Boolean).join(" · ");
  const total = Math.max(0, Math.round(t.duration));
  return {
    format,
    duration: `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`,
    source: stageSourceName.value,
    added: t.added_at ? new Date(t.added_at).toLocaleDateString("zh-CN") : "—",
  };
});
const analysis = ref<number[]>([]),
  analysisNote = ref(""),
  lyrics = ref<{ time: number; text: string }[]>([]);
const activePlaylist = computed(() =>
  s.taste.playlists.find((p) => p.id === playlistId.value),
);
const currentLyric = computed(() =>
  lyrics.value.reduce(
    (found, l, i) => (l.time <= s.playback.position ? i : found),
    -1,
  ),
);
const suggested = computed(() => s.recommendations.map((r) => r.track));
const reasons = computed(() =>
  Object.fromEntries(s.recommendations.map((r) => [r.track.id, r.reason])),
);
const filtered = computed(() =>
  s.tracks.filter((t) =>
    `${t.title} ${t.artist} ${t.album}`
      .toLowerCase()
      .includes(query.value.toLowerCase()),
  ),
);
const favoriteTracks = computed(() =>
  s.tracks.filter((t) => s.favorites.has(t.id)),
);
/** 曲库页的来源筛选条。 */
const librarySourceOptions = computed(() => sourceFilterOptions(s.sources));
/** 只显示当前选中的来源（加上搜索词）。 */
const libraryTracks = computed(() =>
  sourceTracks(filtered.value, librarySource.value),
);
const libraryAlbums = computed(() =>
  sourceAlbums(
    s.albums.filter((a) =>
      `${a.title} ${a.artist}`.toLowerCase().includes(query.value.toLowerCase()),
    ),
    librarySource.value,
  ),
);
/** 「最近添加」：刚连上的来源会排在最前面。 */
const recentTracks = computed(() => recentlyAdded(s.tracks, 12));
const playlistEntries = computed(() => {
  const playlist = activePlaylist.value;
  if (!playlist) return [];
  const entries =
    playlist.entries && playlist.entries.length
      ? playlist.entries
      : playlist.track_ids.map((id) => {
          const track = s.tracks.find((t) => t.id === id);
          return {
            track_id: id,
            title: track?.title || "",
            artist: track?.artist || "",
            album: track?.album || "",
          };
        });
  return entries.map((entry) => ({
    ...entry,
    track: entry.track_id
      ? s.tracks.find((t) => t.id === entry.track_id)
      : undefined,
  }));
});
const playlistTracks = computed(() =>
  playlistEntries.value.flatMap((entry) => (entry.track ? [entry.track] : [])),
);
const unmatchedEntries = computed(() =>
  playlistEntries.value
    .map((entry, index) => ({ ...entry, index }))
    .filter((entry) => !entry.track),
);
const pinnedPlaylist = computed(() =>
  s.taste.playlists.find((playlist) => playlist.id === "awake-for-you"),
);
const userPlaylists = computed(() =>
  s.taste.playlists.filter((playlist) => playlist.id !== "awake-for-you"),
);
const weekly = ref<Weekly | null>(null),
  weeklyLoading = ref(false),
  pendingBookSeek = ref<number | null>(null);
function weekRange(): [number, number] {
  const now = new Date();
  const offset = (now.getDay() + 6) % 7;
  const start = new Date(now.getFullYear(), now.getMonth(), now.getDate() - offset);
  const end = new Date(start);
  end.setDate(start.getDate() + 7);
  return [start.getTime(), end.getTime()];
}
async function loadWeekly() {
  if (!desktop) {
    weekly.value = null;
    return;
  }
  weeklyLoading.value = true;
  await s.run(async () => {
    const [since, until] = weekRange();
    await s.refreshWeekly(since, until);
    weekly.value = s.weekly;
  });
  weeklyLoading.value = false;
}
async function resumeBook(book: Book) {
  const track =
    book.chapters.find((chapter) => chapter.id === book.current_track) ||
    book.chapters[0];
  if (!track) return;
  pendingBookSeek.value = book.position > 3 ? book.position : null;
  await s.start(track, book.chapters);
}
function playBookChapter(track: Track, chapters: Track[]) {
  pendingBookSeek.value = null;
  void s.start(track, chapters);
}
watch(
  () => s.playback.state,
  (state) => {
    if (state === "playing" && pendingBookSeek.value !== null) {
      const position = pendingBookSeek.value;
      pendingBookSeek.value = null;
      void s.seek(position);
    }
  },
);
function playWeeklyTrack(id: string) {
  const track = s.tracks.find((item) => item.id === id);
  if (track) void s.start(track, s.tracks);
}
async function openRecommended(name: string, prompt: string) {
  const existing = s.taste.playlists.find(
    (playlist) => playlist.name === name,
  );
  if (existing) {
    openPlaylist(existing);
    return;
  }
  await s.run(async () => {
    const saved = await s.savePlaylist(name, true, [], prompt);
    if (saved) openPlaylist(saved);
  });
}
const title = computed(
  () =>
    album.value?.title ||
    {
      appearance: "外观与皮肤",
      home: "为你而鸣",
      library: "你的音乐",
      favorites: "喜欢的音乐",
      agent: "你的听歌搭子",
      sources: "音乐来源",
      sound: "声音实验室",
      studio: "灵感工作室",
      stage: "此刻，沉浸",
      books: "听书与播报",
      summary: "本周总结",
      playlist: activePlaylist.value?.name || "我的歌单",
    }[view.value],
);
const heroAlbum = computed(
  () =>
    s.albums.find((a) =>
      a.tracks.some((t) => t.id === suggested.value[0]?.id),
    ) || s.albums[0],
);
/** 曲线编辑器交回来的新增益：就地写回，保持 s.gains 这个引用不变。 */
function updateGains(next: number[]) {
  s.gains.splice(0, s.gains.length, ...next);
}
const tuneText = ref("");
const tuneBusy = ref(false);
const tuneLines = ref<string[]>([]);
const tuneWhy = ref("");
const tuneNote = ref("");
const tuneGains = ref<number[] | null>(null);
let tunePrev: number[] | null = null;

const soundRegions = [
  { name: "低频", lo: 20, hi: 200, up: "鼓更近、下潜更实", down: "去掉低频的糊" },
  { name: "中低", lo: 200, hi: 800, up: "厚度更足", down: "减掉箱音" },
  { name: "中高", lo: 800, hi: 4000, up: "人声更靠前", down: "人声退后、不刺" },
  { name: "高频", lo: 4000, hi: 20000, up: "更亮、空气感", down: "压住齿音" },
];
/** 一句话说清「这条曲线在干什么」——只描述真实增益，平直就直说。 */
const soundSummary = computed(() => {
  const bands = frequencies
    .map((f, i) => [f, s.gains[i] ?? 0] as [number, number])
    .filter(([, g]) => Math.abs(g) >= 1);
  if (!bands.length) {
    return { headline: "平直曲线：这首歌没有做任何适配", has: false };
  }
  const parts: string[] = [];
  for (const region of soundRegions) {
    const slice = bands.filter(([f]) => f >= region.lo && f < region.hi);
    if (!slice.length) continue;
    const mean = slice.reduce((sum, [, g]) => sum + g, 0) / slice.length;
    if (Math.abs(mean) < 0.5) continue;
    const sign = mean > 0 ? "+" : "";
    parts.push(
      `${region.name} ${sign}${mean.toFixed(0)} dB：${mean > 0 ? region.up : region.down}`,
    );
  }
  return {
    headline: parts.slice(0, 2).join("；") || "有轻微调整（每段不足 1 dB）",
    has: true,
  };
});

async function suggestTuning() {
  if (!desktop || tuneBusy.value) return;
  const request = tuneText.value.trim();
  if (!request) return;
  tuneBusy.value = true;
  tuneLines.value = [];
  tuneWhy.value = "";
  tuneNote.value = "";
  try {
    const result = await call<{ gains: number[]; lines: string[]; why: string }>(
      "suggest_curve",
      { req: { request, current: [...s.gains] } },
    );
    tunePrev = [...s.gains];
    tuneGains.value = result.gains;
    tuneLines.value = result.lines;
    tuneWhy.value = result.why;
    tuneNote.value = "预览已生成，点「应用」才会改曲线。";
  } catch (error) {
    tuneNote.value = String(error);
  } finally {
    tuneBusy.value = false;
  }
}
const profileNote = ref("");
/** R4：导入另一台设备导出的听感档案——只有先验可以立刻叠加，按歌曲线暂存到本地待用。 */
async function importListeningProfile(event: Event) {
  const input = event.target as HTMLInputElement;
  const file = input.files?.[0];
  input.value = "";
  if (!file || !desktop) return;
  profileNote.value = "";
  try {
    const text = await file.text();
    const data = JSON.parse(text) as {
      prior?: { gains?: number[] } | null;
      curves?: Record<string, unknown>;
    };
    const prior = (data.prior?.gains ?? []).filter(
      (value): value is number => typeof value === "number" && Number.isFinite(value),
    );
    if (prior.length !== 31) throw new Error("档案里没有可用的 31 段先验");
    const next = s.gains.map((gain, index) =>
      Math.max(-12, Math.min(12, gain + prior[index])),
    );
    updateGains(next);
    await s.applyEq();
    const curves = Object.keys(data.curves ?? {}).length;
    profileNote.value =
      "已叠加先验；档案含 " + curves + " 首按歌曲线（桌面暂按歌记忆，已记录数量）";
    localStorage.setItem("awake-listening-profile", JSON.stringify({ prior }));
  } catch (error) {
    profileNote.value = String(error);
  }
}
async function applyTuning() {
  if (!tuneGains.value) return;
  updateGains(tuneGains.value);
  await s.applyEq();
  tuneNote.value = "已应用；不满意可以撤销。";
}
async function undoTuning() {
  if (!tunePrev) return;
  updateGains(tunePrev);
  await s.applyEq();
  tunePrev = null;
  tuneGains.value = null;
  tuneLines.value = [];
  tuneWhy.value = "";
  tuneNote.value = "已撤销，回到调音前。";
}

/**
 * 演奏式旁路：按住 B 期间把整条曲线压平（真写后端，不是视觉切换），
 * 松手把按下前的曲线写回去。平直曲线没有可旁路的东西，就不闪这一下。
 */
const bypassed = ref(false);
let bypassSnapshot: number[] | null = null;
const bypassable = computed(() => bypassed.value || hasAudibleEq(s.gains));
// 按下与松手是两个 IPC 调用；不串起来的话，快按快放时后发的"原始曲线"
// 可能先到，最终停在平直曲线上而没有任何报错。
let bypassWave: Promise<void> = Promise.resolve();
function pushEq(next: number[]) {
  bypassWave = bypassWave.then(() => s.applyEq(next)).catch(() => {});
  return bypassWave;
}
function beginBypass() {
  if (bypassed.value || view.value !== "stage" || !bypassable.value) return;
  bypassSnapshot = [...s.gains];
  bypassed.value = true;
  void pushEq(flatGains(bypassSnapshot.length));
}
function endBypass() {
  if (!bypassed.value || !bypassSnapshot) return;
  const restore = bypassSnapshot;
  bypassSnapshot = null;
  bypassed.value = false;
  void pushEq(restore);
}
watch(view, (next) => {
  if (next !== "stage") endBypass();
});
const eqPoints = computed(() =>
  s.gains.map((g, i) => `${(i * 600) / 30},${80 - g * 4}`).join(" "),
);
const totalMinutes = computed(() =>
  Math.round(s.tracks.reduce((n, t) => n + t.duration, 0) / 60),
);
const nav = [
  { id: "home", icon: "home", name: "为你而鸣" },
  { id: "library", icon: "disc", name: "音乐资料库" },
  { id: "favorites", icon: "heart", name: "喜欢的音乐" },
  { id: "books", icon: "book", name: "听书与播报" },
  { id: "agent", icon: "spark", name: "听歌搭子" },
  { id: "summary", icon: "chart", name: "本周总结" },
] as const;
function resetScroll() {
  requestAnimationFrame(() =>
    document.getElementById("main-content")?.scrollTo({ top: 0 }),
  );
}
function go(v: View) {
  view.value = v;
  album.value = null;
  query.value = "";
  // 进曲库默认看全部来源；要看某一个来源请用 openSourceLibrary()。
  librarySource.value = "";
  resetScroll();
}
/** 打开曲库并只看这个来源（空串 = 全部来源）。 */
function openSourceLibrary(sourceId: string) {
  go("library");
  libraryMode.value = "songs";
  librarySource.value = sourceId;
}
function openAlbum(a: Album) {
  album.value = a;
  view.value = "library";
  resetScroll();
}
function openPlaylist(p: Playlist) {
  playlistId.value = p.id;
  go("playlist");
}
function openPlaylistById(id: string) {
  const playlist = s.taste.playlists.find((item) => item.id === id);
  if (playlist) openPlaylist(playlist);
}
async function removePlaylistEntry(index: number) {
  const playlist = activePlaylist.value;
  if (!playlist) return;
  const entries = playlistEntries.value
    .filter((_entry, i) => i !== index)
    .map((entry) => ({
      track_id: entry.track_id ?? null,
      title: entry.title,
      artist: entry.artist,
      album: entry.album,
    }));
  const track_ids = entries.flatMap((entry) =>
    entry.track_id ? [entry.track_id] : [],
  );
  await s.run(async () => {
    await call("save_playlist", {
      playlist: { ...playlist, entries, track_ids },
    });
    await s.refreshTaste();
    s.toast("已从歌单移除");
  });
}

const swipeQueue = computed<Track[]>(() =>
  s.queue.length > 1 ? s.queue : s.tracks.length ? s.tracks : s.queue,
);
const swipeIndex = computed(() => {
  const index = swipeQueue.value.findIndex((t) => t.id === s.now?.id);
  return index < 0 ? 0 : index;
});
const swipeNextTrack = computed<Track | null>(() => {
  const list = swipeQueue.value;
  return list.length > 1
    ? list[(swipeIndex.value + 1) % list.length]
    : null;
});
const swipePreviousTrack = computed<Track | null>(() => {
  const list = swipeQueue.value;
  return list.length > 1
    ? list[(swipeIndex.value - 1 + list.length) % list.length]
    : null;
});
function openSwipe() {
  if (!s.now) {
    s.toast("先播放一首音乐，再来刷音乐。");
    return;
  }
  swipeOpen.value = true;
}
async function swipeStep(direction: 1 | -1) {
  const track = s.now;
  if (!track) return;
  const list = swipeQueue.value;
  if (list.length < 2) {
    s.toast("队列里只有这一首音乐，先去曲库添加更多吧。");
    return;
  }
  const index = list.findIndex((t) => t.id === track.id);
  const current = index < 0 ? 0 : index;
  const target = list[(current + direction + list.length) % list.length];
  if (target && target.id !== track.id) await s.start(target, list);
}
async function swipeNext() {
  await swipeStep(1);
}
async function swipePrevious() {
  await swipeStep(-1);
}
async function swipeLike(track: Track) {
  if (!s.favorites.has(track.id)) void s.favorite(track);
  // 拖动期间如果歌曲自然播完，就不要再额外跳一首。
  if (s.now?.id === track.id) await swipeStep(1);
}
function toggleSwipeFavorite() {
  if (s.now) void s.favorite(s.now);
}
function onPlaylistImported(playlist: Playlist) {
  importOpen.value = false;
  openPlaylist(playlist);
}
function saveImportedPlaylist(
  name: string,
  smart: boolean,
  items: Track[],
  entries: PlaylistEntry[],
) {
  return s.savePlaylist(name, smart, items, s.prompt, entries);
}
async function importChange(e: Event) {
  const files = (e.target as HTMLInputElement).files;
  if (files) await s.importFiles(files);
  (e.target as HTMLInputElement).value = "";
}
function addMusic() {
  if (desktop) {
    sourceStep.value = "type";
    sourceOpen.value = true;
  } else fileInput.value?.click();
}
async function pickFolder() {
  await s.run(async () => {
    const path = await call<string | null>("pick_music_folder");
    if (!path) return;
    sourcePath.value = path;
    const probe = await checkSourcePath();
    s.toast(probe ? probe.message : "已选择文件夹，点“连接曲库”开始扫描");
  });
}
async function pickFiles() {
  await s.run(async () => {
    const paths = await call<string[]>("pick_music_files");
    if (!paths.length) return;
    const result = await s.importPaths(paths);
    if (result && !s.fault) {
      sourceOpen.value = false;
    }
  });
}
async function handleDrop(paths: string[]) {
  if (!paths.length) return;
  if (paths.length === 1) await s.scan(paths[0]);
  else await s.importPaths(paths);
}
watch([sourceOpen, saveOpen], async ([source, save]) => {
  if (source || save) {
    await nextTick();
    document.getElementById(source ? "source-path" : "playlist-name")?.focus();
  }
});
async function generate(text?: string) {
  if (text !== undefined) s.prompt = text;
  await s.generateRecommendations(view.value === "agent" && useCloud.value);
  go("agent");
}
async function saveList() {
  const saved = await s.savePlaylist(
    playlistName.value,
    saveSmart.value,
    suggested.value,
  );
  if (saved) {
    saveOpen.value = false;
    openPlaylist(saved);
  }
}
function openSave() {
  saveSmart.value = s.curationMode !== "cloud";
  playlistName.value = s.prompt.trim().slice(0, 24) || "我的每日声景";
  saveOpen.value = true;
}
async function saveBrief() {
  briefBusy.value = true;
  await s.run(async () => {
    await call("save_creation_brief", { prompt: studioPrompt.value });
    await s.refreshTaste();
    studioPrompt.value = "";
    s.toast("创作灵感已保存，连接音乐生成服务后可继续");
  });
  briefBusy.value = false;
}
function exportBrief(prompt: string) {
  const blob = new Blob(
    [
      JSON.stringify(
        {
          version: 1,
          prompt,
          provider: null,
          status: "draft",
          output: { kind: "audio", original: true },
          created_at: new Date().toISOString(),
        },
        null,
        2,
      ),
    ],
    { type: "application/json" },
  );
  const url = URL.createObjectURL(blob),
    a = document.createElement("a");
  a.href = url;
  a.download = "awake-creation-brief.json";
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
function trapFocus(e: KeyboardEvent) {
  const nodes = Array.from(
    (e.currentTarget as HTMLElement).querySelectorAll<HTMLElement>(
      "button:not(:disabled),input,select,textarea",
    ),
  );
  const first = nodes[0],
    last = nodes[nodes.length - 1];
  if (e.shiftKey && document.activeElement === first) {
    e.preventDefault();
    last?.focus();
  } else if (!e.shiftKey && document.activeElement === last) {
    e.preventDefault();
    first?.focus();
  }
}
function keyup(e: KeyboardEvent) {
  if (e.key.toLowerCase() === BYPASS_KEY) endBypass();
}
function keydown(e: KeyboardEvent) {
  // 刷音乐 / 歌单导入自己处理方向键与空格，避免一次按键触发两次。
  if (
    (swipeOpen.value || importOpen.value || dataOpen.value) &&
    e.key !== "Escape"
  )
    return;
  const target = e.target as HTMLElement;
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
    e.preventDefault();
    commandOpen.value = !commandOpen.value;
    return;
  }
  if (e.key === "Escape") {
    commandOpen.value = false;
    sourceOpen.value = false;
    saveOpen.value = false;
    queueOpen.value = false;
    swipeOpen.value = false;
    importOpen.value = false;
    dataOpen.value = false;
    return;
  }
  if (
    ["INPUT", "TEXTAREA", "SELECT", "BUTTON"].includes(target.tagName) ||
    target.isContentEditable
  )
    return;
  if (isBypassKey(e)) {
    e.preventDefault();
    beginBypass();
    return;
  }
  if (e.code === "Space") {
    e.preventDefault();
    void s.toggle();
  }
  if (e.metaKey && e.key === "ArrowRight") {
    e.preventDefault();
    void s.next();
  }
  if (e.metaKey && e.key === "ArrowLeft") {
    e.preventDefault();
    void s.previous();
  }
}
watch(
  () => s.now,
  (track) => {
    if (!track) swipeOpen.value = false;
  },
);
watch(swipeOpen, async (open) => {
  if (open) return;
  await nextTick();
  document.getElementById("swipe-launch")?.focus();
});
watch(importOpen, async (open) => {
  if (open) return;
  await nextTick();
  document.getElementById("playlist-import-launch")?.focus();
});
watch(dataOpen, async (open) => {
  if (open) return;
  await nextTick();
  document.getElementById("data-launch")?.focus();
});
watch(sourceKind, (kind) => {
  if (kind !== "plex") stopPlexPoll();
});
watch(sourceOpen, (open) => {
  if (!open) stopPlexPoll();
});
watch(commandOpen, (open) => {
  if (open) setTimeout(() => commandInput.value?.focus(), 0);
});
let analysisGeneration = 0;
watch(
  () => [view.value, s.now?.id, s.now?.lyrics],
  async () => {
    if (view.value !== "stage" || !s.now) return;
    const token = ++analysisGeneration;
    analysis.value = [];
    lyrics.value = [];
    analysisNote.value = "正在读取曲目…";
    if (!desktop) {
      analysisNote.value = "频谱画像与本地 LRC 歌词可在桌面版查看";
      return;
    }
    const track = s.now;
    const results = await Promise.allSettled([
      call<{ bands: number[] }>("analyze_track", {
        sourceId: track.source_id,
        locator: track.locator,
      }),
      call<{ time: number; text: string }[]>("load_lyrics", {
        sourceId: track.source_id,
        locator: track.locator,
      }),
    ]);
    if (token !== analysisGeneration) return;
    if (results[0].status === "fulfilled") {
      analysis.value = results[0].value.bands;
      analysisNote.value = "抽样频谱画像 · 3 个片段";
    } else analysisNote.value = "频谱分析暂不可用";
    if (results[1].status === "fulfilled") lyrics.value = results[1].value;
  },
);
let dropCleanup: (() => void) | undefined;
const scanProgress = ref<{ done: number; total: number; title: string } | null>(
  null,
);
let scanCleanup: (() => void) | undefined;
function browserDragOver(event: DragEvent) {
  event.preventDefault();
}
function browserDrop(event: DragEvent) {
  event.preventDefault();
  const files = event.dataTransfer?.files;
  if (files?.length) void s.importFiles(files);
}
watch(view, (value) => {
  if (value === "summary") void loadWeekly();
});
const coverage = ref<Coverage | null>(null);
const achievements = ref<Achievement[]>([]);
const insightError = ref("");
const presets = ref<AiPreset[]>([]);
const curatorPreset = ref("");
const musicPreset = ref("");

async function loadInsight() {
  if (!desktop) {
    // 浏览器预览里没有本地曲库，这两个命令只会抛「需要桌面版」。
    // 原先直接 return，面板静默消失，看起来像功能坏了；现在把原因说出来。
    insightError.value =
      "曲库覆盖度与成就要读完整个本地曲库，浏览器预览读不到，请在 Awake 桌面应用中查看。";
    return;
  }
  try {
    const [cov, list] = await Promise.all([
      libraryCoverage(),
      listeningAchievements(),
    ]);
    coverage.value = cov;
    achievements.value = list;
    insightError.value = "";
  } catch (reason) {
    insightError.value = String(reason).replace(/^Error: /, "");
  }
}

const coldestBucket = computed(() => {
  const buckets = coverage.value?.by_artist ?? [];
  if (!buckets.length) return null;
  return [...buckets].sort(
    (a, b) => a.heard / Math.max(a.total, 1) - b.heard / Math.max(b.total, 1),
  )[0];
});

async function loadPresets() {
  try {
    presets.value = await aiPresets();
  } catch {
    presets.value = [];
  }
}

function applyPreset(kind: "curator" | "music", id: string) {
  const preset = presets.value.find((item) => item.id === id);
  if (!preset) return;
  if (kind === "curator") {
    curatorEndpoint.value = preset.endpoint;
    curatorModel.value = preset.model;
  } else {
    musicEndpoint.value = preset.endpoint;
    musicModel.value = preset.model;
  }
  s.toast(`已填入 ${preset.label} 的地址与模型，只剩 token 需要你粘`);
}

/** 歌单缺口引导用：选一个文件夹扫进曲库，返回是否真的扫到了曲目。 */
async function rescanForImport(): Promise<boolean> {
  if (!desktop) return false;
  const path = await call<string | null>("pick_music_folder");
  if (!path) return false;
  const before = s.tracks.length;
  await s.scan(path);
  void loadInsight();
  return s.tracks.length > before;
}

onMounted(() => {
  void refreshBuiltinStatus();
  window.addEventListener("keydown", keydown);
  window.addEventListener("keyup", keyup);
  // 切走应用时 keyup 收不到：不补这一条，旁路会一直挂在开着的状态上。
  window.addEventListener("blur", endBypass);
  if (desktop) {
    void getCurrentWebview()
      .onDragDropEvent((event) => {
        if (event.payload.type === "drop") void handleDrop(event.payload.paths);
      })
      .then((unlisten) => (dropCleanup = unlisten))
      .catch(() => {});
  } else {
    window.addEventListener("dragover", browserDragOver);
    window.addEventListener("drop", browserDrop);
  }
  void listen<{ done: number; total: number; title: string }>(
    "awake://scan-progress",
    (event) => {
      scanProgress.value = event.payload;
      if (event.payload.done >= event.payload.total) {
        window.setTimeout(() => (scanProgress.value = null), 1500);
      }
    },
  )
    .then((unlisten) => (scanCleanup = unlisten))
    .catch(() => {});
  void loadWeekly();
  void loadInsight();
  void loadPresets();
  // 启动就恢复 Plex 登录：不用打开浏览器，也不用再点一次授权。
  void restorePlexAccount();
});
onUnmounted(() => {
  window.removeEventListener("keydown", keydown);
  window.removeEventListener("keyup", keyup);
  window.removeEventListener("blur", endBypass);
  window.removeEventListener("dragover", browserDragOver);
  window.removeEventListener("drop", browserDrop);
  dropCleanup?.();
  scanCleanup?.();
  stopPlexPoll();
});
</script>

<template>
  <div class="app-shell">
    <input
      ref="fileInput"
      class="sr-only"
      type="file"
      multiple
      accept="audio/*,.flac,.aiff,.alac,.ogg"
      aria-label="导入本地音乐"
      @change="importChange"
    />
    <aside class="sidebar">
      <div class="brand" data-tauri-drag-region>
        <Icon name="wave" :size="30" /><span
          >awake<span class="brand-dot">.</span></span
        >
      </div>
      <button class="search-launch" @click="commandOpen = true">
        <Icon name="search" /><span>找一首音乐</span><kbd>⌘ K</kbd>
      </button>
      <div class="nav-caption">聆听</div>
      <nav aria-label="主导航">
        <button
          v-for="item in nav"
          :key="item.id"
          :aria-label="item.name"
          class="nav-item"
          :class="{ active: view === item.id }"
          :aria-current="view === item.id ? 'page' : undefined"
          @click="go(item.id)"
        >
          <Icon :name="item.icon" :size="19" /><span>{{ item.name }}</span
          ><span v-if="item.id === 'agent'" class="local-dot" />
        </button>
      </nav>
      <div class="nav-caption between">
        <span>我的歌单</span
        ><span class="caption-actions"
          ><button
            id="playlist-import-launch"
            class="tiny-button"
            aria-label="导入歌单"
            title="从网易云 / QQ / YouTube / 文件等导入歌单"
            @click="importOpen = true"
          >
            <Icon name="folder" :size="15" /></button
          ><button
            class="tiny-button"
            aria-label="创建歌单"
            @click="
              go('agent');
              openSave();
            "
          >
            <Icon name="plus" :size="15" />
          </button></span
        >
      </div>
      <div class="playlist-nav">
        <button
          v-if="pinnedPlaylist"
          class="nav-item playlist-link pinned"
          :class="{ active: view === 'playlist' && playlistId === pinnedPlaylist.id }"
          @click="openPlaylist(pinnedPlaylist)"
        >
          <Icon name="spark" /><span>{{ pinnedPlaylist.name }}</span
          ><span class="small-tag">每日</span>
        </button>
        <button
          v-for="p in userPlaylists"
          :key="p.id"
          class="nav-item playlist-link"
          :class="{ active: view === 'playlist' && playlistId === p.id }"
          @click="openPlaylist(p)"
        >
          <Icon :name="p.smart ? 'spark' : 'list'" /><span>{{ p.name }}</span>
        </button>
        <div v-if="!s.taste.playlists.length" class="nav-empty">
          把喜欢的此刻，存成歌单。
        </div>
      </div>
      <div class="nav-caption">探索更多</div>
      <button
        class="nav-item"
        aria-label="灵感工作室"
        :class="{ active: view === 'studio' }"
        @click="go('studio')"
      >
        <Icon name="orbit" :size="19" /><span>灵感工作室</span
        ><span class="small-tag">LAB</span>
      </button>
      <button
        class="nav-item"
        aria-label="音乐来源"
        :class="{ active: view === 'sources' }"
        @click="go('sources')"
      >
        <Icon name="database" :size="19" /><span>音乐来源</span>
      </button>
      <button
        class="nav-item"
        aria-label="外观与皮肤"
        :class="{ active: view === 'appearance' }"
        @click="go('appearance')"
      >
        <Icon name="sliders" :size="19" /><span>外观与皮肤</span>
      </button>
      <div class="sidebar-bottom">
        <button class="device-card" @click="go('sound')">
          <span class="device-icon"><Icon name="headphones" :size="22" /></span
          ><span
            ><strong>{{ s.device }}</strong
            ><small
              ><span class="status-dot" />{{
                processing ? "个性听感已开启" : "EQ 直通"
              }}</small
            ></span
          ><Icon name="chevron" :size="14" />
        </button>
        <div class="version-line">
          <span>为好音乐而生</span><span>{{ APP_VERSION_LINE }}</span>
        </div>
      </div>
    </aside>

    <div class="workspace">
      <header class="topbar" data-tauri-drag-region>
        <div class="breadcrumb">
          你的聆听空间<span>/</span><strong>{{ title }}</strong>
        </div>
        <div class="top-actions">
          <span class="private-label"
            ><span class="status-dot" />本地个性化</span
          ><button
            class="icon-btn"
            :class="{ selected: view === 'sound' }"
            aria-label="声音设置"
            @click="go('sound')"
          >
            <Icon name="sliders" :size="19" /></button
          ><button
            class="avatar"
            aria-label="查看听歌偏好"
            @click="go('agent')"
          >
            我
          </button>
        </div>
      </header>
      <div v-if="scanProgress" class="scan-status" role="status">
        <span class="spinner" />
        <span
          >正在扫描 {{ scanProgress.title || "曲库" }} ·
          {{ scanProgress.done }} / {{ scanProgress.total }}</span
        >
      </div>
      <main id="main-content" class="main-content">
      <TelegramSponsored v-if="activeTelegramSource && view !== 'sources'" :source-id="activeTelegramSource.id" />
        <Appearance v-if="view === 'appearance'" :services="s.services" />
        <template v-else-if="view === 'home'">
          <div class="page-intro">
            <div>
              <p class="eyebrow">YOUR DAILY RESONANCE</p>
              <h1>好音乐，<span class="serif">刚好懂你。</span></h1>
              <p>从熟悉的旋律，到下一次心动。让耳朵带路。</p>
            </div>
            <button class="text-button" @click="go('agent')">
              我的聆听偏好 <Icon name="arrow" />
            </button>
          </div>
          <section class="daily-hero">
            <div class="hero-copy">
              <span class="hero-label"
                ><Icon name="spark" :size="14" />{{
                  s.learned ? "从你的聆听中发现" : "从你的音乐开始"
                }}</span
              >
              <h2>
                {{
                  s.learned
                    ? "属于你的，\n下一段频率。"
                    : "让今天，\n有自己的声场。"
                }}
              </h2>
              <p>
                {{
                  s.tracks.length
                    ? `从 ${s.tracks.length} 首音乐里，找到适合此刻的旋律。收藏和跳过，都会让下次更合拍。`
                    : "把你的音乐带进来。每一次播放、收藏与跳过，都会成为下一次推荐的线索。"
                }}
              </p>
              <div class="hero-actions">
                <button
                  class="button primary"
                  @click="
                    s.tracks.length
                      ? s.start(suggested[0], suggested)
                      : addMusic()
                  "
                >
                  <Icon
                    :name="s.tracks.length ? 'play' : 'plus'"
                    :size="17"
                  />{{
                    s.tracks.length ? "开始我的电台" : "添加我的音乐"
                  }}</button
                ><button class="hero-secondary" @click="generate('探索 新鲜')">
                  换一点新鲜感 <Icon name="arrow" :size="16" />
                </button>
              </div>
              <div class="hero-footer">
                <span class="mini-wave"><i /><i /><i /><i /><i /></span
                ><span>{{
                  s.learned ? `${s.learned} 次聆听，正在认识你` : "越听，越合拍"
                }}</span
                ><span class="hero-rule" /><span>ONLY YOUR VIBE</span>
              </div>
            </div>
            <div class="hero-visual">
              <div class="vinyl">
                <div class="vinyl-label">
                  <Artwork
                    :path="heroAlbum?.artwork_path"
                    seed="daily-resonance"
                  /><span>AWAKE<br />DAILY MIX</span>
                </div>
              </div>
              <div class="floating-cover">
                <Artwork
                  :path="heroAlbum?.artwork_path"
                  seed="daily-resonance"
                /><span>{{ heroAlbum?.title || "YOUR NEXT FAVORITE" }}</span>
              </div>
              <span class="hero-index"
                >01 — ∞<br /><small>A LITTLE CLOSER TO YOU</small></span
              >
            </div>
          </section>
          <div class="section-heading">
            <div>
              <h2>为此刻，选一种心情<span class="heading-dot">.</span></h2>
              <p>告诉搭子你想怎么听。</p>
            </div>
          </div>
          <div class="mood-grid">
            <button
              class="mood-card mood-focus"
              @click="generate('专注 ambient instrumental')"
            >
              <span class="mood-art focus-art" /><span class="mood-caption"
                ><strong>进入心流</strong><small>把世界调小声</small></span
              ><Icon name="arrow" /></button
            ><button
              class="mood-card mood-explore"
              @click="generate('探索 新鲜')"
            >
              <span class="mood-art explore-art" /><span class="mood-caption"
                ><strong>偶遇新频率</strong><small>给耳朵一点意外</small></span
              ><Icon name="arrow" /></button
            ><button class="mood-card mood-favorites" @click="go('favorites')">
              <span class="mood-art favorite-art" /><span class="mood-caption"
                ><strong>回到喜欢</strong
                ><small>那些反复心动的旋律</small></span
              ><Icon name="arrow" />
            </button>
          </div>
          <div class="section-heading">
            <div>
              <h2>你与音乐的交集</h2>
              <p>
                {{
                  s.albums.length
                    ? `${s.albums.length} 张专辑，等你重新发现。`
                    : "你的私人音乐档案，从这里开始。"
                }}
              </p>
            </div>
            <button class="text-button" @click="go('library')">
              全部音乐 <Icon name="arrow" />
            </button>
          </div>
          <div v-if="s.albums.length" class="album-grid">
            <button
              v-for="a in s.albums.slice(0, 5)"
              :key="a.id"
              class="album-card"
              @click="openAlbum(a)"
            >
              <Artwork :path="a.artwork_path" :seed="a.title" /><strong>{{
                a.title
              }}</strong
              ><small
                >{{ a.artist || "未知艺人" }} · {{ a.tracks.length }} 首</small
              >
            </button>
          </div>
          <button v-else class="import-strip" @click="addMusic()">
            <span class="import-icon"><Icon name="plus" :size="24" /></span
            ><span
              ><strong>音乐在你那里，体验从这里开始。</strong
              ><small>{{
                desktop
                  ? "添加本地音乐文件夹或直接选择文件，也可以把文件拖进窗口。"
                  : "导入音频即可试听；浏览器内的音频仅保留在本次会话。"
              }}</small></span
            ><Icon name="arrow" :size="20" />
          </button>
          <div class="section-heading">
            <div>
              <h2>推荐歌单</h2>
              <p>其中有一份，是每天照着你的聆听重新生成的。</p>
            </div>
            <button class="text-button" @click="go('summary')">
              本周总结 <Icon name="chart" />
            </button>
          </div>
          <div class="recommend-grid">
            <button
              class="recommend-card for-you"
              @click="pinnedPlaylist && openPlaylist(pinnedPlaylist)"
            >
              <span class="recommend-badge">FOR YOU · 每日更新</span>
              <strong>为你生成</strong>
              <small>按这周听到的、跳过的和收藏的，重新排一次。</small>
              <span class="recommend-meta"
                >{{ pinnedPlaylist?.track_ids.length || 0 }} 首 · 打开即听</span
              >
            </button>
            <button
              class="recommend-card"
              @click="openRecommended('专注时刻', '专注 ambient instrumental')"
            >
              <span class="recommend-badge">FOCUS</span>
              <strong>专注时刻</strong>
              <small>把人声和鼓点调低，留一段不被打断的时间。</small>
              <span class="recommend-meta">动态歌单 · 随偏好更新</span>
            </button>
            <button
              class="recommend-card"
              @click="openRecommended('偶遇新频率', '探索 新鲜')"
            >
              <span class="recommend-badge">DISCOVER</span>
              <strong>偶遇新频率</strong>
              <small>优先曲库里还没完整听过的部分。</small>
              <span class="recommend-meta">动态歌单 · 随曲库更新</span>
            </button>
          </div>
          <section class="week-teaser">
            <div>
              <p class="eyebrow">THIS WEEK</p>
              <h2>
                本周，你听了
                <span class="serif"
                  >{{ Math.round((weekly?.seconds || 0) / 60) }} 分钟。</span
                >
              </h2>
              <p>
                {{
                  weekly?.lines?.[0] ||
                  "再听几首，这里会写出属于这一周的声场。"
                }}
              </p>
            </div>
            <button class="button" @click="go('summary')">
              看完整总结 <Icon name="arrow" />
            </button>
          </section>
        </template>

        <template
          v-else-if="
            view === 'library' || view === 'favorites' || view === 'playlist'
          "
        >
          <button
            v-if="album"
            class="text-button back-link"
            @click="album = null"
          >
            <Icon name="back" />返回资料库
          </button>
          <div v-if="album" class="album-detail">
            <Artwork :path="album.artwork_path" :seed="album.title" />
            <div>
              <p class="eyebrow">ALBUM / {{ album.year || "你的收藏" }}</p>
              <h1>{{ album.title }}</h1>
              <p>
                {{ album.artist }} · {{ album.tracks.length }} 首 ·
                {{
                  Math.round(
                    album.tracks.reduce((sum, t) => sum + t.duration, 0) / 60,
                  )
                }}
                分钟
              </p>
              <button
                class="button primary"
                @click="s.start(album.tracks[0], album.tracks)"
              >
                <Icon name="play" />播放专辑
              </button>
            </div>
          </div>
          <div v-else class="page-intro">
            <div>
              <p class="eyebrow">
                {{
                  view === "favorites"
                    ? "CLOSE TO YOUR HEART"
                    : view === "playlist"
                      ? "YOUR PERSONAL MIX"
                      : "YOUR SOUND ARCHIVE"
                }}
              </p>
              <h1>{{ title }}</h1>
              <p>
                {{
                  view === "favorites"
                    ? `${favoriteTracks.length} 首，每一次喜欢都算数。`
                    : view === "playlist"
                      ? (activePlaylist?.smart
                          ? "动态歌单 · 曲库与听歌偏好变化时自动更新"
                          : "静态歌单 · 保留此刻的选择") +
                        " · " +
                        playlistTracks.length +
                        " 首可播放" +
                        (unmatchedEntries.length
                          ? " · " + unmatchedEntries.length + " 首待匹配"
                          : "")
                      : `${s.albums.length} 张专辑 · ${s.tracks.length} 首 · ${totalMinutes} 分钟`
                }}
              </p>
            </div>
            <button
              v-if="view === 'library'"
              class="button"
              @click="addMusic()"
            >
              <Icon name="plus" />添加音乐</button
            ><button
              v-if="view === 'playlist'"
              class="button"
              :disabled="!playlistTracks.length"
              @click="s.start(playlistTracks[0], playlistTracks)"
            >
              <Icon name="play" />播放歌单
            </button>
          </div>
          <template v-if="view === 'library' && !album"
            ><div class="library-toolbar">
              <div class="segmented">
                <button
                  :class="{ active: libraryMode === 'albums' }"
                  @click="libraryMode = 'albums'"
                >
                  专辑</button
                ><button
                  :class="{ active: libraryMode === 'songs' }"
                  @click="libraryMode = 'songs'"
                >
                  歌曲
                </button>
              </div>
              <label class="inline-search"
                ><Icon name="search" /><input
                  v-model="query"
                  placeholder="搜索音乐、艺人或专辑"
                  aria-label="搜索曲库"
              /></label>
            </div>
            <div v-if="s.sources.length > 1" class="source-filter" role="group" aria-label="按来源筛选曲库">
              <span>来源</span>
              <button
                v-for="option in librarySourceOptions"
                :key="option.id || 'all'"
                :class="{ active: librarySource === option.id }"
                @click="librarySource = option.id"
              >
                {{ option.label }}
              </button>
            </div>
            <div v-if="libraryMode === 'albums'" class="album-grid">
              <button
                v-for="a in libraryAlbums"
                :key="a.id"
                class="album-card"
                @click="openAlbum(a)"
              >
                <Artwork :path="a.artwork_path" :seed="a.title" /><strong>{{
                  a.title
                }}</strong
                ><small
                  >{{ a.artist || "未知艺人" }} ·
                  {{ a.tracks.length }} 首</small
                >
              </button>
              <div v-if="!s.albums.length" class="empty-state">
                <Icon name="disc" :size="40" />
                <h2>留一个位置，给你的音乐。</h2>
                <p>连接本地曲库，开始你的私人聆听空间。</p>
                <button class="button primary" @click="addMusic()">
                  添加音乐
                </button>
              </div>
            </div>
            <TrackList
              v-else
              :tracks="libraryTracks"
              :current-id="s.now?.id"
              :favorites="s.favorites"
              @play="s.start($event, libraryTracks)"
              @favorite="s.favorite"
              @edit="editingMedia = $event"
          /></template>
          <TrackList
            v-else
            :tracks="
              album?.tracks ||
              (view === 'favorites' ? favoriteTracks : playlistTracks)
            "
            :current-id="s.now?.id"
            :favorites="s.favorites"
            :empty="
              view === 'favorites'
                ? '遇到喜欢的音乐，点一下爱心。搭子会记得。'
                : view === 'playlist'
                  ? unmatchedEntries.length
                    ? '这份歌单的曲目还没匹配到本地文件，见下方待匹配条目。'
                    : '这份歌单还没有曲目。'
                  : undefined
            "
            @play="
              s.start(
                $event,
                album?.tracks ||
                  (view === 'favorites' ? favoriteTracks : playlistTracks),
              )
            "
            @favorite="s.favorite"
              @edit="editingMedia = $event"
          />
          <section
            v-if="view === 'playlist' && unmatchedEntries.length"
            class="unmatched-block"
          >
            <div class="section-heading">
              <div>
                <h3>待匹配曲目</h3>
                <p>
                  这些歌单条目已保存；导入对应文件或曲库更新后会自动匹配，不用重新导入歌单。
                </p>
              </div>
            </div>
            <div class="unmatched-list">
              <div
                v-for="entry in unmatchedEntries"
                :key="entry.index"
                class="unmatched-row"
              >
                <span class="unmatched-badge">未匹配</span>
                <span class="unmatched-copy"
                  ><strong>{{ entry.title || "未命名曲目" }}</strong
                  ><small
                    >{{ entry.artist || "未知艺人"
                    }}{{ entry.album ? " · " + entry.album : "" }}</small
                  ></span
                >
                <button
                  class="text-button danger"
                  @click="removePlaylistEntry(entry.index)"
                >
                  移除
                </button>
              </div>
            </div>
          </section>
          <div
            v-if="view === 'playlist' && activePlaylist"
            class="playlist-footer"
          >
            <span class="muted">{{
              activePlaylist.id === "awake-for-you"
                ? "每天按你的聆听重新生成；不会改动其他歌单。"
                : activePlaylist.prompt || "从你的曲库创建"
            }}</span
            ><button
              v-if="activePlaylist.id !== 'awake-for-you'"
              class="text-button danger"
              @click="
                s.removePlaylist(activePlaylist.id);
                go('library');
              "
            >
              删除歌单
            </button>
          </div>
        </template>

        <template v-else-if="view === 'agent'">
          <div class="page-intro">
            <div>
              <p class="eyebrow">A LITTLE MORE YOU, EVERY DAY</p>
              <h1>音乐很多，<span class="serif">我陪你挑。</span></h1>
              <p>把此刻的心情交给搭子，把选择留给耳朵。</p>
            </div>
            <span class="subtle-badge"
              ><span class="status-dot" />本地个性化已启用</span
            >
          </div>
          <div v-if="coverage" class="info-panel insight-panel">
            <Icon name="chart" :size="18" />
            <div>
              <p>
                <strong>听歌覆盖度 {{ coverage.percent }}%</strong>
                · 已听 {{ coverage.heard }} / {{ coverage.total }} 首 · 还有
                {{ coverage.unheard }} 首一次都没碰过
              </p>
              <p v-if="coldestBucket" class="muted">
                最冷的角落：{{ coldestBucket.label }}（{{
                  coldestBucket.heard
                }}
                / {{ coldestBucket.total }}）
              </p>
              <ul class="achievement-list">
                <li v-for="item in achievements" :key="item.id">
                  <span :class="{ unlocked: item.unlocked }">{{ item.title }}</span>
                  <small class="muted">{{ item.detail }}</small>
                  <small v-if="item.unlocked" class="unlocked-note"
                    >{{ item.punchline }}</small
                  >
                </li>
              </ul>
            </div>
          </div>
          <p v-if="insightError" class="muted">{{ insightError }}</p>
          <div class="agent-composer">
            <div class="agent-avatar"><Icon name="spark" :size="26" /></div>
            <form @submit.prevent="generate()">
              <label for="music-intent">这会儿，想听些什么？</label>
              <div class="intent-input">
                <input
                  id="music-intent"
                  v-model="s.prompt"
                  placeholder="试试：想听一点 ambient，安静地工作一会儿"
                /><button
                  class="button primary"
                  type="submit"
                  :disabled="s.curating"
                >
                  <Icon name="spark" />{{
                    s.curating ? "正在选曲…" : "为我选曲"
                  }}
                </button>
              </div>
              <label class="cloud-option"
                ><input
                  v-model="useCloud"
                  type="checkbox"
                  :disabled="!desktop || !s.services.curator"
                />本次使用云端策展<span
                  >仅在点击选曲时，将候选曲目信息和精简偏好发送到已配置服务。</span
                ></label
              >
              <div class="suggestion-chips">
                <button
                  type="button"
                  @click="generate('专注 ambient instrumental')"
                >
                  进入心流</button
                ><button type="button" @click="generate('探索 新鲜')">
                  来点没听过的</button
                ><button type="button" @click="generate('')">
                  跟着我的喜好走
                </button>
              </div>
            </form>
          </div>
          <div class="agent-context">
            <div>
              <Icon name="heart" /><strong>{{
                s.taste.favorites.length
              }}</strong
              ><span>首喜欢</span>
            </div>
            <div>
              <Icon name="wave" /><strong>{{ s.learned }}</strong
              ><span>次有效聆听</span>
            </div>
            <div>
              <Icon name="database" /><strong>{{ s.sources.length }}</strong
              ><span>个音乐来源</span>
            </div>
            <p>
              {{
                s.learned
                  ? "你的喜欢、完整收听与主动跳过，会影响下一次选曲。"
                  : "还在认识你。先听几首、收藏几首，让推荐有迹可循。"
              }}
            </p>
          </div>
          <div class="source-filter">
            <span>从哪里选</span
            ><button
              :class="{ active: !s.sourceFilter.length }"
              @click="
                s.sourceFilter = [];
                s.generateRecommendations(false);
              "
            >
              全部曲库</button
            ><button
              v-for="source in s.sources"
              :key="source.id"
              :class="{ active: s.sourceFilter.includes(source.id) }"
              @click="
                s.sourceFilter = s.sourceFilter.includes(source.id)
                  ? s.sourceFilter.filter((id) => id !== source.id)
                  : [...s.sourceFilter, source.id];
                s.generateRecommendations(false);
              "
            >
              {{ source.name }}
            </button>
          </div>
          <div class="section-heading">
            <div>
              <h2>给你的下一段旋律</h2>
              <p>每一首都有原因。描述会匹配曲名、艺人、专辑与风格标签。</p>
            </div>
            <div class="button-row">
              <button
                class="button"
                :disabled="!suggested.length"
                @click="openSave()"
              >
                <Icon name="plus" />存为歌单</button
              ><button
                class="button primary"
                :disabled="!suggested.length"
                @click="s.start(suggested[0], suggested)"
              >
                <Icon name="play" />全部播放
              </button>
            </div>
          </div>
          <TrackList
            :tracks="suggested"
            :current-id="s.now?.id"
            :favorites="s.favorites"
            :reasons="reasons"
            @play="s.start($event, suggested)"
            @favorite="s.favorite"
              @edit="editingMedia = $event"
          />
          <p class="capability-note">
            <Icon name="shield" />听歌偏好保存在这台设备。云端 AI
            尚未连接；当前选曲来自本地标签和听歌习惯。
          </p>
          <details class="eq-card">
            <summary>
              云端策展服务 · {{ s.services.curator ? "已配置" : "未配置" }}
            </summary>
            <form
              class="connection-form"
              @submit.prevent="saveAIService('curator')"
            >
              <label
                >预置平台<select
                  v-model="curatorPreset"
                  @change="applyPreset('curator', curatorPreset)"
                >
                  <option value="">选一个平台，自动填好地址与模型</option>
                  <option
                    v-for="preset in presets"
                    :key="preset.id"
                    :value="preset.id"
                  >
                    {{ preset.label }} · {{ preset.model }}
                  </option>
                </select></label
              ><p
                v-if="curatorPreset && presets.find((p) => p.id === curatorPreset)"
                class="muted"
              >
                {{ presets.find((p) => p.id === curatorPreset)?.note }} ·
                <a
                  :href="presets.find((p) => p.id === curatorPreset)?.docs"
                  target="_blank"
                  rel="noreferrer"
                  >取 token</a
                >
              </p>
              <label
                >兼容 API 的 Base URL<input
                  v-model="curatorEndpoint"
                  type="url"
                  required /></label
              ><label
                >模型名称<input
                  v-model="curatorModel"
                  required
                  placeholder="服务商支持的模型 ID" /></label
              ><label
                >API 密钥<input
                  v-model="curatorKey"
                  type="password"
                  autocomplete="off"
                  placeholder="仅写入系统钥匙串；留空保留原密钥"
              /></label>
              <p>
                支持 Chat Completions 与 JSON
                输出的服务。配置后仍由你主动选择是否使用云端，日常反馈更新继续使用本地引擎。
              </p>
              <button class="button" :disabled="!desktop">保存策展服务</button>
            </form>
          </details>
        </template>

        <template v-else-if="view === 'sources'">
          <div class="page-intro">
            <div>
              <p class="eyebrow">ALL YOUR MUSIC, ONE PLACE</p>
              <h1>让音乐，汇集于此。</h1>
              <p>用你的音乐来源，养成自己的聆听空间。</p>
            </div>
            <button
              class="button primary"
              :disabled="s.busy"
              @click="addMusic()"
            >
              <Icon name="plus" />添加音乐来源
            </button>
          </div>
          <article class="source-card">
            <span class="source-icon"><Icon name="folder" :size="28" /></span>
            <div>
              <span class="subtle-badge">本地内置版</span>
              <h2>内置示例曲库</h2>
              <p class="source-path">
                包内 {{ builtinStatus?.available ?? 0 }} 首 · 已入库
                {{ builtinStatus?.imported ?? 0 }} 首<template v-if="builtinStatus?.seeded">
                  · 已播种</template
                >
              </p>
              <small>示例音频随包分发，不联网；重装或清空后会重新导入。</small>
              <p v-if="builtinNote" class="job-error">{{ builtinNote }}</p>
              <p>
                <button
                  class="button"
                  :disabled="builtinBusy || !desktop"
                  @click="installBuiltinDemo"
                >
                  重新导入
                </button>
                <button
                  class="button"
                  :disabled="builtinBusy || !desktop"
                  @click="removeBuiltinDemo"
                >
                  移除内置示例
                </button>
                <button
                  class="button"
                  :disabled="builtinBusy || !desktop"
                  @click="clearLocalRecords"
                >
                  清空本地记录
                </button>
              </p>
            </div>
          </article>
          <div class="source-cards">
            <article
              v-for="source in s.sources"
              :key="source.id"
              class="source-card"
            >
              <span class="source-icon"><Icon name="folder" :size="28" /></span>
              <div>
                <span class="subtle-badge">{{ sourceLabel(source.kind) }}</span>
                <h2>{{ source.name }}</h2>
                <p class="source-path">
                  <template v-if="source.kind === 'plugin'"
                    >插件文件 · 搜索入库</template
                  ><template v-else
                    >{{ source.url
                    }}<template v-if="source.files?.length">
                      · {{ source.files.length }} 个文件（原地读取）</template
                    ><template v-else-if="source.section">
                      · 音乐库 {{ source.section }}</template
                    ></template
                  >
                </p>
                <TelegramSponsored v-if="source.kind === 'telegram'" :source-id="source.id" />
                <small>{{ sourceStatusLine(source) }}</small>
                <p v-if="s.sourceStatuses[source.id]?.error" class="job-error">
                  更新失败，保留上次曲库：{{
                    s.sourceStatuses[source.id].error
                  }}
                </p>
                <label v-if="source.kind !== 'plugin'" class="cloud-option"
                  ><input
                    type="checkbox"
                    :checked="source.enabled !== false"
                    :disabled="!desktop"
                    @change="
                      s.setSourceAuto(
                        source,
                        ($event.target as HTMLInputElement).checked,
                      )
                    "
                  />每 15 分钟自动更新</label
                >
              </div>
              <div class="source-actions">
                <button
                  v-if="source.kind === 'plugin'"
                  class="button primary"
                  :disabled="!desktop"
                  @click="openPluginSearch(source)"
                >
                  <Icon name="search" />搜索并入库
                </button>
                <button
                  class="button"
                  :disabled="!source.track_count"
                  @click="openSourceLibrary(source.id)"
                >
                  <Icon name="list" />查看曲目
                </button>
                <button
                  v-if="source.kind !== 'plugin'"
                  class="button"
                  :disabled="s.busy || !desktop"
                  @click="s.refreshSource(source)"
                >
                  <Icon name="refresh" />{{ s.busy ? "扫描中…" : "更新曲库" }}
                </button>
                <button
                  class="text-button"
                  :disabled="s.busy"
                  @click="removeSource(source)"
                >
                  {{
                    removingSource === source.id
                      ? "再点一次确认移除"
                      : "移除来源"
                  }}
                </button>
              </div>
            </article>
            <div v-if="!s.sources.length" class="empty-state">
              <Icon name="database" :size="40" />
              <h2>好音乐，值得一个好住处。</h2>
              <p>添加本地文件夹、直接选择音频文件，或连接 Plex / WebDAV。</p>
              <button class="button primary" @click="addMusic()">
                添加音乐
              </button>
            </div>
          </div>
          <template v-if="recentTracks.length">
            <div class="section-heading">
              <div>
                <h2>最近添加</h2>
                <p>刚扫描进来的曲目，按加入时间排序。</p>
              </div>
              <button class="text-button" @click="openSourceLibrary('')">
                打开曲库 <Icon name="arrow" />
              </button>
            </div>
            <TrackList
              :tracks="recentTracks"
              :current-id="s.now?.id"
              :favorites="s.favorites"
              @play="s.start($event, recentTracks)"
              @favorite="s.favorite"
              @edit="editingMedia = $event"
            />
          </template>
          <section class="info-panel">
            <Icon name="spark" :size="24" />
            <div>
              <h3>把来源，变成会生长的歌单。</h3>
              <p>
                在听歌搭子中选定曲库来源，保存为动态歌单。来源更新和听歌偏好会一起影响选曲。
              </p>
              <button class="text-button" @click="go('agent')">
                创建动态歌单 <Icon name="arrow" />
              </button>
            </div>
          </section>
          <div v-if="s.taste.feeds.length" class="section-heading">
            <div>
              <h2>我的元数据订阅</h2>
              <p>
                每 15
                分钟读取标题，并只匹配自己的曲库；不会读取或传播订阅中的音频链接。
              </p>
            </div>
          </div>
          <article
            v-for="feed in s.taste.feeds"
            :key="feed.id"
            class="source-card"
          >
            <Icon name="list" :size="24" />
            <div>
              <h2>{{ feed.name }}</h2>
              <p>
                {{ feed.matched }} / {{ feed.total }} 条已匹配 ·
                {{
                  feed.refreshed_at
                    ? new Date(feed.refreshed_at).toLocaleString("zh-CN")
                    : "等待更新"
                }}
              </p>
              <p v-if="feed.error" class="job-error">{{ feed.error }}</p>
            </div>
            <button
              class="button"
              @click="
                playlistId = feed.playlist_id;
                go('playlist');
              "
            >
              打开歌单
            </button>
          </article>
          <div class="info-panel">
            <Icon name="shield" />
            <div>
              <h3>连接你自己的音乐</h3>
              <p>
                NAS 与网盘可通过系统挂载目录或服务商提供的 WebDAV 连接，Plex
                使用自己的服务器与访问令牌。播放器不提供公共音乐源目录或分享入口。
              </p>
              <p>
                请确认你拥有来源与内容的使用权限，在授权范围内个人使用。不要制造、上传或传播侵权内容，请支持正版音乐。
              </p>
            </div>
          </div>
        </template>

        <template v-else-if="view === 'sound'">
          <div class="page-intro">
            <div>
              <p class="eyebrow">MAKE IT SOUND LIKE YOU</p>
              <h1>好声音，<span class="serif">也有你的偏好。</span></h1>
              <p>听感没有标准答案。找到舒服的那个位置。</p>
            </div>
            <button class="button primary" @click="s.rememberSound()">
              <Icon name="heart" />记住这个声音
            </button>
          </div>
          <SoundChain
            :context="s.listeningContext"
            :chains="s.taste.listening_chains"
            :services="s.services"
            :device="s.device"
            :output-rate="s.playback.output_rate || s.deviceRate"
            @changed="
              async () => {
                await s.refreshTaste();
                await s.checkDevice(true);
              }
            "
          />
          <div class="signal-path">
            <div>
              <span>音乐文件</span
              ><strong>{{ s.now ? format(s.now) : "等待播放" }}</strong>
            </div>
            <Icon name="arrow" />
            <div>
              <span>听感处理</span
              ><strong>{{
                processing
                  ? activeCorrection
                    ? "参数校正 + 听感曲线"
                    : "31 段 EQ 已开启"
                  : "EQ 直通"
              }}</strong>
            </div>
            <Icon name="arrow" />
            <div>
              <span>输出设备</span><strong>{{ s.device }}</strong
              ><small>{{
                s.playback.output_rate || s.deviceRate
                  ? `${((s.playback.output_rate || s.deviceRate) / 1000).toFixed(1)} kHz`
                  : "由系统管理"
              }}</small>
            </div>
          </div>
          <section class="eq-card">
            <div class="section-heading">
              <div>
                <h2>这首歌的声音</h2>
                <p>{{ soundSummary.headline }}</p>
              </div>
              <span class="muted">{{ processing ? "EQ 增强中" : "原声" }} · 按住 B 对比</span>
            </div>
            <div class="tune-row">
              <button
                v-for="phrase in ['人声太靠后', '低频糊', '想更亮', '太吵']"
                :key="phrase"
                class="text-button"
                :disabled="tuneBusy || !desktop"
                @click="tuneText = phrase"
              >
                {{ phrase }}
              </button>
            </div>
            <div class="tune-input">
              <input
                v-model="tuneText"
                :disabled="tuneBusy"
                placeholder="说一句话，例如：人声再靠前一点，低频别那么糊"
              />
              <button
                class="button primary"
                :disabled="tuneBusy || !desktop || !tuneText.trim()"
                @click="suggestTuning"
              >
                {{ tuneBusy ? "调音中…" : "让 AI 调" }}
              </button>
            </div>
            <p v-if="tuneNote" class="muted">{{ tuneNote }}</p>
            <div class="profile-import">
              <label class="text-button">
                导入听感档案（跨设备）
                <input type="file" accept=".json" hidden @change="importListeningProfile" />
              </label>
              <span v-if="profileNote" class="muted">{{ profileNote }}</span>
            </div>

            <div v-if="tuneLines.length" class="tune-preview">
              <p v-for="line in tuneLines" :key="line" class="muted">{{ line }}</p>
              <p v-if="tuneWhy" class="muted">{{ tuneWhy }}</p>
              <button class="button primary" :disabled="tuneBusy" @click="applyTuning">
                应用
              </button>
              <button class="button" :disabled="tuneBusy" @click="undoTuning">撤销</button>
            </div>
          </section>
          <section class="eq-card">
            <div class="section-heading">
              <div>
                <h2>你的声音曲线</h2>
                <p>
                  {{
                    processing
                      ? `前级 ${s.preamp.toFixed(1)} dB · 自动预留叠加增益余量`
                      : "EQ 平直 · 前级 0 dB"
                  }}
                </p>
              </div>
              <button class="text-button" @click="resetSound">
                恢复原声 <Icon name="refresh" />
              </button>
            </div>
            <EqCurveEditor
              :gains="s.gains"
              :frequencies="frequencies"
              @update:gains="updateGains"
              @apply="s.applyEq()"
            />
            <details class="eq-sliders-toggle">
              <summary>精确调整（31 段滑块）</summary>
              <div class="eq-sliders">
                <label v-for="(f, i) in frequencies" :key="f"
                  ><span class="sr-only">{{ f }} Hz</span
                  ><input
                    v-model.number="s.gains[i]"
                    type="range"
                    min="-12"
                    max="12"
                    step="0.5"
                    :aria-label="`${f} Hz 均衡增益`"
                    @change="s.applyEq()"
                  /><small>{{ f >= 1000 ? f / 1000 + "k" : f }}</small></label
                >
              </div>
            </details>
            <div class="preset-row">
              <span>从一种听感开始</span
              ><button @click="s.preset('warm')">温暖低频</button
              ><button @click="s.preset('vocal')">清晰人声</button
              ><button @click="s.preset('soft')">柔和耐听</button
              ><button @click="resetSound">原声</button>
            </div>
          </section>
          <section class="eq-card correction-panel">
            <div class="section-heading">
              <div>
                <h2>耳机测量校正</h2>
                <p>
                  导入你选择的 AutoEQ / Equalizer APO 参数文件。保留原始 PK / LS
                  / HS 滤波器与测量来源。
                </p>
              </div>
            </div>
            <label class="field-label"
              >当前设备的校正<select
                :value="
                  s.taste.active_corrections[s.deviceKey || s.device] || ''
                "
                :disabled="!desktop"
                @change="
                  selectCorrection(($event.target as HTMLSelectElement).value)
                "
              >
                <option value="">不应用测量校正</option>
                <option
                  v-for="profile in s.taste.headphone_profiles"
                  :key="profile.id"
                  :value="profile.id"
                >
                  {{ profile.name }} · {{ profile.target }}
                </option>
              </select></label
            >
            <p v-if="activeCorrection">
              测量来源（用户提供）：{{ activeCorrection.measurement_source }} ·
              {{ activeCorrection.filters.length }} 个参数滤波器
            </p>
            <details>
              <summary>导入参数校正</summary>
              <form class="connection-form" @submit.prevent="importCorrection">
                <label
                  >耳机名称<input
                    v-model="correctionName"
                    required
                    placeholder="与测量对应的型号" /></label
                ><label
                  >测量来源<input
                    v-model="measurementSource"
                    required
                    placeholder="测量者、数据集或出处链接" /></label
                ><label
                  >目标曲线<input
                    v-model="correctionTarget"
                    required
                    placeholder="与该配置对应的目标曲线" /></label
                ><label
                  >参数文件<input
                    type="file"
                    accept=".txt"
                    @change="readCorrection" /></label
                ><label
                  >参数内容<textarea
                    v-model="correctionText"
                    rows="5"
                    required
                    placeholder="Preamp: -5 dB&#10;Filter 1: ON PK Fc 1000 Hz Gain -2 dB Q 1"
                  /></label
                ><button class="button primary" :disabled="!desktop">
                  导入并应用
                </button>
              </form>
            </details>
            <p class="capability-note">
              配置只代表用户提供的数据；播放器不会把设备名称匹配或主观预设标为实测校正。
            </p>
          </section>
          <section class="info-panel">
            <Icon name="headphones" :size="25" />
            <div>
              <h3>每个设备，都能有自己的声音。</h3>
              <p>
                点击“记住这个声音”保存当前聆听链路的曲线。相同耳机的蓝牙、有线、小尾巴等配置分别记忆。
              </p>
              <p class="muted">
                根据系统设备 UID 和传输方式恢复链路；模拟耳机、2.4GHz
                接收器的具体型号由你确认。蓝牙编码由系统或接收器协商，界面不会把偏好当作实测编码。
              </p>
            </div>
          </section>
        </template>

        <template v-else-if="view === 'studio'">
          <div class="page-intro">
            <div>
              <p class="eyebrow">SOMETHING ONLY YOU COULD IMAGINE</p>
              <h1>下一首，<span class="serif">从你的灵感开始。</span></h1>
              <p>把此刻的灵感与听歌偏好，变成可以试听、保存的音乐。</p>
            </div>
            <span class="subtle-badge"
              >音乐生成服务 · {{ s.services.music ? "已配置" : "未配置" }}</span
            >
          </div>
          <section class="studio-panel">
            <div class="studio-orbit"><Icon name="orbit" :size="72" /></div>
            <form @submit.prevent="saveBrief">
              <label for="creation-intent"
                >如果此刻是一首歌，它会是什么样？</label
              ><textarea
                id="creation-intent"
                v-model="studioPrompt"
                rows="5"
                placeholder="一首没有人声的夜间电子乐，温暖的模拟合成器、缓慢的鼓点，像雨夜驶过一座陌生城市……"
                required
              />
              <div class="generation-options">
                <label
                  >时长<select v-model.number="generationDuration">
                    <option :value="30">30 秒</option>
                    <option :value="60">60 秒</option>
                    <option :value="120">120 秒</option>
                    <option :value="180">180 秒</option>
                  </select></label
                ><label
                  ><input v-model="instrumental" type="checkbox" />纯音乐</label
                ><label
                  ><input
                    v-model="usePreferences"
                    type="checkbox"
                  />参考实际听歌风格标签</label
                >
              </div>
              <p class="muted">
                点击生成会把描述及所选偏好标签发送到已配置服务，并可能按服务商规则计费。不会自动重试生成请求。
              </p>
              <div class="between">
                <span class="muted">灵感可先保存；生成作品会自动加入曲库。</span
                ><button
                  class="button primary"
                  :disabled="briefBusy || !studioPrompt.trim()"
                >
                  <Icon name="plus" />保存灵感</button
                ><button
                  class="button primary"
                  type="button"
                  :disabled="
                    !desktop ||
                    !s.services.music ||
                    !studioPrompt.trim() ||
                    s.taste.generations.some((g) =>
                      ['queued', 'running'].includes(g.state),
                    )
                  "
                  @click="generateTrack"
                >
                  <Icon name="spark" />生成并保存音乐
                </button>
              </div>
            </form>
          </section>
          <details class="eq-card">
            <summary>音乐生成服务 · ElevenLabs</summary>
            <form
              class="connection-form"
              @submit.prevent="saveAIService('music')"
            >
              <label
                >预置平台<select
                  v-model="musicPreset"
                  @change="applyPreset('music', musicPreset)"
                >
                  <option value="">选一个平台，自动填好地址与模型</option>
                  <option
                    v-for="preset in presets.filter(p => p.kind === 'music' || p.kind === 'both')"
                    :key="preset.id"
                    :value="preset.id"
                  >
                    {{ preset.label }} · {{ preset.model }}
                  </option>
                </select></label
              ><p
                v-if="musicPreset && presets.find((p) => p.id === musicPreset)"
                class="muted"
              >
                {{ presets.find((p) => p.id === musicPreset)?.note }} ·
                <a
                  :href="presets.find((p) => p.id === musicPreset)?.docs"
                  target="_blank"
                  rel="noreferrer"
                  >取 token</a
                >
              </p>
              <label
                >服务地址<input
                  v-model="musicEndpoint"
                  type="url"
                  required /></label
              ><label
                >音乐模型<select v-model="musicModel">
                  <option value="music_v1">music_v1</option>
                  <option value="music_v2">music_v2</option>
                  <option value="music_v2_5">music_v2_5</option>
                </select></label
              ><label
                >API 密钥<input
                  v-model="musicKey"
                  type="password"
                  autocomplete="off"
                  placeholder="仅保存在系统钥匙串"
              /></label>
              <p>
                账号需具有对应音乐 API
                权限。这里只保存配置，不会开始生成或自动产生请求。
              </p>
              <button class="button" :disabled="!desktop">保存音乐服务</button>
            </form>
          </details>
          <div class="section-heading">
            <div>
              <h2>我的 AI 作品</h2>
              <p>真实音频完成解码校验后，自动保存并加入音乐资料库。</p>
            </div>
          </div>
          <div v-if="!s.taste.generations.length" class="list-empty">
            还没有生成任务。
          </div>
          <article
            v-for="job in [...s.taste.generations].reverse()"
            :key="job.id"
            class="brief-card"
          >
            <Icon name="music" />
            <div>
              <strong>{{ job.prompt }}</strong
              ><small
                >{{ jobLabel(job.state) }} · {{ job.provider }} /
                {{ job.model }}</small
              >
              <p v-if="job.error" class="job-error">{{ job.error }}</p>
            </div>
            <button
              v-if="job.state === 'completed'"
              class="button"
              :disabled="!job.track_id"
              @click="playGeneration(job.track_id)"
            >
              <Icon name="play" />播放作品</button
            ><button
              v-if="job.state === 'completed' && desktop"
              class="button"
              @click="revealGeneration(job.id)"
            >
              显示文件</button
            ><button
              v-if="['running', 'queued'].includes(job.state)"
              class="button"
              @click="cancelGeneration(job.id)"
            >
              停止接收
            </button>
          </article>
          <div class="section-heading">
            <div>
              <h2>灵感档案</h2>
              <p>保存好想法，随时继续创作；已生成的音乐保存在上方作品列表。</p>
            </div>
          </div>
          <div v-if="!s.taste.briefs.length" class="list-empty">
            第一段旋律，先从一个念头开始。
          </div>
          <article
            v-for="brief in [...s.taste.briefs].reverse()"
            :key="brief.id"
            class="brief-card"
          >
            <Icon name="orbit" :size="23" />
            <div>
              <strong>{{ brief.prompt }}</strong
              ><small
                >{{ new Date(brief.created_at).toLocaleDateString("zh-CN") }} ·
                灵感草稿</small
              >
            </div>
            <button class="button" @click="exportBrief(brief.prompt)">
              导出简报 <Icon name="arrow" />
            </button>
          </article>
        </template>

        <template v-else-if="view === 'stage'">
          <div class="stage-head">
            <div>
              <p class="stage-kicker">正在播放</p>
              <h1 class="stage-title">{{ s.now?.title || '还没有在播放' }}</h1>
              <p v-if="s.now" class="stage-sub">
                {{ s.now.artist }}<template v-if="s.now.album"> · {{ s.now.album }}</template>
              </p>
            </div>
            <button class="text-button" @click="queueOpen = !queueOpen">
              播放队列 <Icon name="list" />
            </button>
          </div>
          <section v-if="s.now" class="stage-body">
            <StageInstrument
              :track="s.now"
              :gains="s.gains"
              :source-name="stageSourceName"
              :bypassed="bypassed"
              :bypassable="bypassable"
            />
            <aside class="stage-side">
              <Artwork
                :path="s.now.artwork_path"
                :seed="s.now.album || s.now.title"
                :style-name="s.now.media_info?.cover_style"
                large
              />
              <dl class="stage-facts">
                <div><dt>格式</dt><dd>{{ stageFacts.format }}</dd></div>
                <div><dt>时长</dt><dd>{{ stageFacts.duration }}</dd></div>
                <div><dt>来源</dt><dd>{{ stageFacts.source }}</dd></div>
                <div><dt>加入</dt><dd>{{ stageFacts.added }}</dd></div>
              </dl>
              <button class="text-button" @click="editingMedia = s.now">
                整理封面、歌词与乐评
              </button>
            </aside>
          </section>
          <div v-else class="empty-state">
            <Icon name="music" :size="42" />
            <h2>先放一首喜欢的音乐。</h2>
            <button class="button primary" @click="go('library')">
              去音乐资料库
            </button>
          </div>
          <section v-if="s.now" class="stage-lyrics-panel">
            <p class="stage-section-title">歌词</p>
            <div class="stage-lyrics">
              <template v-if="lyrics.length"
                ><button
                  v-for="(line, i) in lyrics"
                  :key="i"
                  :class="{ active: i === currentLyric }"
                  @click="s.seek(line.time)"
                >
                  {{ line.text }}
                </button></template
              >
              <pre v-else-if="s.now.lyrics" class="plain-lyrics">{{ s.now.lyrics }}</pre>
              <p v-else class="lyrics-empty">
                没有同步歌词。与音频同名的 .lrc 文件会被自动读取。
              </p>
            </div>
          </section>
          <div v-if="s.now" class="spectrum-section">
            <div class="between">
              <span>曲目频谱画像</span><small>{{ analysisNote }}</small>
            </div>
            <div class="spectrum-bars">
              <span
                v-for="(band, i) in analysis"
                :key="i"
                :style="{
                  height:
                    Math.max(2, Math.min(100, ((band + 90) / 90) * 100)) + '%',
                }"
              />
            </div>
          </div>
        </template>
        <BooksView
          v-else-if="view === 'books'"
          :books="s.books"
          :tracks="s.tracks"
          :jobs="s.speechJobs"
          :services="s.services"
          :now="s.now"
          @play="playBookChapter"
          @resume="resumeBook"
          @toast="s.toast"
          @refresh="s.refresh()"
          @open-playlist="openPlaylistById"
          @import-files="pickFiles"
        />
        <template v-else-if="view === 'summary'">
          <div class="page-intro">
            <div>
              <p class="eyebrow">YOUR WEEK IN SOUND</p>
              <h1>这一周，<span class="serif">耳朵记住了什么。</span></h1>
              <p>从周一到今天，本机记录下的聆听、收藏与书籍进度。</p>
            </div>
            <button class="button" :disabled="weeklyLoading" @click="loadWeekly">
              <Icon name="refresh" />{{ weeklyLoading ? "统计中…" : "刷新统计" }}
            </button>
          </div>
          <WeeklySummary
            :summary="weekly"
            :loading="weeklyLoading"
            @play="playWeeklyTrack"
            @refresh="loadWeekly"
          />
        </template>
      </main>
    </div>

    <aside v-if="queueOpen" class="queue-panel">
      <div class="section-heading">
        <div>
          <p class="eyebrow">UP NEXT</p>
          <h2>接下来，继续心动。</h2>
        </div>
        <button
          class="icon-btn"
          aria-label="关闭队列"
          @click="queueOpen = false"
        >
          <Icon name="close" />
        </button>
      </div>
      <p class="muted">{{ s.queue.length }} 首音乐</p>
      <button
        v-for="(t, i) in s.queue"
        :key="`${t.id}-${i}`"
        class="queue-track"
        :class="{ active: i === s.queueIndex }"
        @click="s.start(t)"
      >
        <Artwork :path="t.artwork_path" :seed="t.album" /><span
          ><strong>{{ t.title }}</strong
          ><small>{{ t.artist }}</small></span
        ><Icon :name="i === s.queueIndex ? 'wave' : 'play'" />
      </button>
      <p v-if="!s.queue.length" class="list-empty">
        播放一首音乐，队列就从这里开始。
      </p>
    </aside>

    <footer class="player">
      <button class="now-info" aria-label="打开沉浸播放" @click="go('stage')">
        <Artwork :path="s.now?.artwork_path" :seed="s.now?.album || s.now?.title" :style-name="s.now?.media_info?.cover_style" /><span
          ><strong>{{ s.now?.title || "让好音乐，开始。" }}</strong
          ><small>{{
            s.now ? s.now.artist + " · " + s.now.album : "你的私人聆听空间"
          }}</small></span
        ></button
      ><button
        class="icon-btn favorite-now"
        :class="{ loved: s.now && s.favorites.has(s.now.id) }"
        :disabled="!s.now"
        :aria-label="
          s.now && s.favorites.has(s.now.id)
            ? '取消收藏当前歌曲'
            : '收藏当前歌曲'
        "
        @click="s.now && s.favorite(s.now)"
      >
        <Icon name="heart" :size="19" />
      </button>
      <div class="player-center">
        <div class="transport">
          <button
            class="icon-btn"
            :disabled="s.queueIndex <= 0 && !s.now"
            aria-label="上一首"
            @click="s.previous()"
          >
            <Icon name="prev" :size="18" /></button
          ><button
            class="play-button"
            :disabled="(!s.now && !s.tracks.length) || s.loading"
            :aria-label="s.playing ? '暂停' : '播放'"
            @click="s.toggle()"
          >
            <span v-if="s.loading" class="spinner" /><Icon
              v-else
              :name="s.playing ? 'pause' : 'play'"
              :size="20"
            /></button
          ><button
            class="icon-btn"
            :disabled="s.queueIndex >= s.queue.length - 1"
            aria-label="下一首"
            @click="s.next()"
          >
            <Icon name="next" :size="18" />
          </button>
        </div>
        <div class="timeline">
          <span>{{ duration(s.playback.position) }}</span
          ><input
            type="range"
            min="0"
            :max="s.playback.duration || s.now?.duration || 0"
            :value="s.playback.position"
            step="0.1"
            :disabled="!s.now || s.loading"
            aria-label="播放进度"
            @change="s.seek(Number(($event.target as HTMLInputElement).value))"
          /><span>{{
            duration(s.playback.duration || s.now?.duration || 0)
          }}</span>
        </div>
      </div>
      <div class="player-right">
        <button
          v-if="s.now"
          id="swipe-launch"
          class="swipe-launch"
          aria-label="刷音乐"
          title="刷音乐（全窗口）"
          @click="openSwipe"
        >
          <Icon name="spark" :size="16" /><span>刷音乐</span>
        </button>
        <button
          class="icon-btn"
          :class="{ selected: queueOpen }"
          aria-label="播放队列"
          :aria-expanded="queueOpen"
          @click="queueOpen = !queueOpen"
        >
          <Icon name="list" :size="20" /></button
        ><button
          id="data-launch"
          class="icon-btn"
          aria-label="数据与接力：加密备份与手机接力"
          aria-haspopup="dialog"
          title="数据与接力（加密备份 / 手机接力）"
          @click="dataOpen = true"
        >
          <Icon name="shield" :size="19" /></button
        ><button class="icon-btn" aria-label="声音实验室" @click="go('sound')">
          <Icon name="sliders" :size="19" /></button
        ><label class="volume-control"
          ><Icon name="volume" /><input
            v-model.number="s.volume"
            type="range"
            min="0"
            max="1"
            step="0.01"
            aria-label="音量"
            @input="s.setVolume()" /></label
        ><span v-if="s.now" class="player-quality">{{
          s.now.codec.toUpperCase()
        }}</span>
      </div>
    </footer>

    <div v-if="s.notice" class="toast" role="status">
      <Icon name="check" />{{ s.notice }}
    </div>
    <div v-if="s.fault" class="error-toast" role="alert">
      <Icon name="info" /><span>{{ s.fault }}</span
      ><button class="icon-btn" aria-label="关闭错误提示" @click="s.fault = ''">
        <Icon name="close" />
      </button>
    </div>

    <div
      v-if="sourceOpen || saveOpen || commandOpen"
      class="modal-backdrop"
      @click.self="
        sourceOpen = false;
        saveOpen = false;
        commandOpen = false;
      "
    >
      <section
        class="modal"
        role="dialog"
        aria-modal="true"
        :aria-label="
          sourceOpen ? '添加音乐来源' : saveOpen ? '保存歌单' : '搜索与快捷操作'
        "
        @keydown.tab="trapFocus"
      >
        <div class="modal-heading">
          <h2>
            {{
              sourceOpen
                ? "把你的音乐带进来"
                : saveOpen
                  ? "留住这段频率"
                  : "想听的，就在这里。"
            }}
          </h2>
          <button
            class="icon-btn"
            aria-label="关闭对话框"
            @click="
              sourceOpen = false;
              saveOpen = false;
              commandOpen = false;
            "
          >
            <Icon name="close" />
          </button>
        </div>
        <form
          v-if="sourceOpen"
          class="connection-form"
          @submit.prevent="connectSource"
        >
          <template v-if="sourceStep === 'type'">
            <p class="muted">要加什么？先选一类，下一步只填这一类需要的字段。</p>
            <button
              v-for="option in sourceTypes"
              :key="option.kind"
              type="button"
              class="button"
              @click="chooseSourceType(option.kind)"
            >
              <Icon :name="option.icon" />{{ option.label }}
              <small class="muted">{{ option.hint }}</small>
            </button>
            <button type="button" class="text-button" @click="sourceOpen = false">
              取消
            </button>
          </template>
          <template v-else>
          <label
            >来源类型<select v-model="sourceKind">
              <option value="local">本地文件夹</option>
              <option value="smb">NAS / 已挂载网盘</option>
              <option value="webdav">WebDAV</option>
              <option value="plex">Plex</option>
              <option value="telegram">Telegram 个人媒体库</option>
              <option value="plugin">网络音乐插件（枪弹分离 JS）</option>
              <option value="rss">RSS / Atom 元数据匹配</option>
            </select></label
          >
          <label
            >来源名称<input
              v-model="sourceName"
              placeholder="可选，给它一个好认的名字"
          /></label>
          <template v-if="sourceKind !== 'plugin'">
            <label for="source-path">{{
              ["local", "smb"].includes(sourceKind)
                ? "音乐文件夹完整路径"
                : "服务器地址"
            }}</label>
            <input
              id="source-path"
              v-model="sourcePath"
              :placeholder="
                ['local', 'smb'].includes(sourceKind)
                  ? '/Volumes/我的音乐'
                  : 'https://你的服务器/音乐目录/'
              "
              required
              @blur="checkSourcePath"
            />
          </template>
          <p
            v-if="['local', 'smb'].includes(sourceKind) && sourceProbe"
            :class="sourceProbe.audio_count ? 'muted' : 'job-error'"
            role="status"
          >
            {{ sourceProbe.message
            }}<template v-if="sourceProbe.sample.length"
              >：{{ sourceProbe.sample.join("、") }}</template
            >
          </p>
          <div
            v-if="['local', 'smb'].includes(sourceKind)"
            class="source-pick-row"
          >
            <button class="button" type="button" :disabled="s.busy" @click="pickFolder">
              <Icon name="folder" />选择文件夹
            </button>
            <button class="button" type="button" :disabled="s.busy" @click="pickFiles">
              <Icon name="music" />选择音频文件
            </button>
          </div>
          <p v-if="['local', 'smb'].includes(sourceKind)" class="muted">
            也可以直接把文件夹或音频文件拖进窗口。文件会原地读取，不复制、不移动。
          </p>
          <div v-if="sourceKind === 'plugin'" class="plugin-pick">
            <div class="plugin-registry">
              <label
                >插件源地址<input
                  v-model="pluginRegistryURL"
                  :disabled="s.busy || registryBusy"
                  placeholder="…/myPlugins.json"
              /></label>
              <button
                class="button"
                :disabled="s.busy || registryBusy"
                @click="loadPluginRegistry"
              >
                {{ registryBusy ? "载入中…" : "载入插件源" }}
              </button>
              <p v-if="registryError" class="job-error" role="alert">{{ registryError }}</p>
              <ul v-if="pluginRegistry.length" class="registry-list">
                <li v-for="item in pluginRegistry" :key="item.url">
                  <button
                    class="text-button"
                    :disabled="registryBusy"
                    @click="pickRegistryPlugin(item)"
                  >
                    {{ item.name
                    }}<span v-if="item.version" class="muted"> · {{ item.version }}</span>
                  </button>
                </li>
              </ul>
            </div>
            <label
              >插件文件（.js，MusicFree 兼容）<input
                type="file"
                accept=".js,application/javascript,text/javascript"
                :disabled="s.busy"
                @change="readPluginFile"
            /></label>
            <p v-if="pluginFileName" class="muted">
              已选择：{{ pluginFileName
              }}<template v-if="pluginPlatform"> · {{ pluginPlatform }}</template>
            </p>
            <p v-if="pluginError" class="job-error" role="alert">
              {{ pluginError }}
            </p>
            <p class="muted">
              枪弹分离：插件是独立的 JS 文件，定义搜索与解析；Awake
              只负责运行播放器与代发请求。只导入你信任来源的插件，添加后点「搜索并入库」挑歌。
            </p>
          </div>
          <template v-if="!['local', 'smb', 'plugin'].includes(sourceKind)"
            ><label v-if="!['plex', 'telegram'].includes(sourceKind)"
              >账号<input
                v-model="sourceUsername"
                autocomplete="username"
                placeholder="匿名访问可留空" /></label
            ><label
              >{{ sourceKind === "plex" ? "Plex Token" : sourceKind === "telegram" ? "连接器访问令牌" : "密码"
              }}<input
                v-model="sourceSecret"
                type="password"
                autocomplete="off"
                :placeholder="
                  sourceKind === 'plex' ? '服务器访问令牌' : '仅存入系统钥匙串'
                " /></label
          ></template>
          <div v-if="sourceKind === 'plex' && desktop" class="plex-login">
            <div class="plex-account">
              <p class="muted">
                <Icon name="shield" />{{ plexAccountLabel(plex.account) }}
                <template v-if="plex.signedIn">· 登录状态已保存</template>
              </p>
              <button
                v-if="plex.signedIn"
                type="button"
                class="text-button"
                :disabled="plex.busy || plex.polling"
                @click="forgetPlexAccount"
              >
                退出登录
              </button>
            </div>
            <button
              type="button"
              class="text-button"
              :disabled="plex.busy || plex.polling"
              @click="startPlexLogin"
            >
              <Icon name="shield" />{{
                plex.polling ? "等待 Plex 授权…" : "用 Plex 账号登录"
              }}
            </button>
            <button
              v-if="plex.polling"
              type="button"
              class="text-button"
              @click="cancelPlexLogin"
            >
              取消登录
            </button>
            <p v-if="plex.status" class="muted">{{ plex.status }}</p>
            <p v-if="plex.error" class="job-error" role="alert">{{ plex.error }}</p>
            <template v-if="plex.servers.length">
              <label
                >Plex 服务器<select
                  v-model.number="plex.serverIndex"
                  @change="applyPlexServer"
                >
                  <option
                    v-for="(server, index) in plex.servers"
                    :key="server.url"
                    :value="index"
                  >
                    {{ server.name }} · {{ server.connection }}
                  </option>
                </select></label
              >
              <label v-if="plex.sections.length"
                >音乐库<select
                  v-model.number="plex.sectionIndex"
                  @change="applyPlexSection"
                >
                  <option
                    v-for="(section, index) in plex.sections"
                    :key="section.key"
                    :value="index"
                  >
                    {{ section.title }}
                  </option>
                </select></label
              >
              <div class="source-pick-row">
                <button
                  type="button"
                  class="button primary"
                  :disabled="s.busy || plex.probing"
                  @click="connectPlex"
                >
                  <Icon name="plus" />{{
                    s.busy
                      ? "正在扫描 Plex 曲库…"
                      : "连接这个 Plex 音乐库"
                  }}
                </button>
                <button
                  type="button"
                  class="text-button"
                  :disabled="plex.busy || plex.polling"
                  @click="retryPlexResources"
                >
                  <Icon name="refresh" />重新读取服务器
                </button>
              </div>
              <p class="muted">
                连不上时先换一条线路（本地 / 远程 / 中继）。连接后曲库会出现在「音乐来源」里。
              </p>
            </template>
          </div>
          <label
            v-if="['webdav', 'plex'].includes(sourceKind)"
            class="checkbox-label"
            ><input v-model="trustSelfSigned" type="checkbox" />允许自签名 HTTPS
            证书（仅此来源）</label
          >
          <p v-if="sourceKind === 'smb'" class="muted">
            先在 Finder
            或网盘客户端挂载，再选择目录。未挂载网盘可使用服务商提供的
            WebDAV；当前不解析网盘分享链接。
          </p>
          <p
            v-else-if="sourceKind === 'webdav' || sourceKind === 'plex'"
            class="muted"
          >
            凭据保存在系统钥匙串。音频使用 HTTP Range
            按需读取，服务器需要支持字节范围请求。
          </p>
          <TelegramSource v-if="sourceKind === 'telegram' && !telegramReady" :url="sourcePath" :secret="sourceSecret" :disabled="s.busy" @selected="url => sourcePath = url" />
          <p v-if="sourceKind === 'telegram' && telegramReady" class="muted">已选择个人媒体库。连接后读取所选来源最近的消息；登录会话保存在你自己的连接器设备，访问令牌保存在系统钥匙串。</p>
          <p v-if="sourceKind === 'rss'" class="muted">
            只读取 RSS / Atom
            标题并匹配自己的曲库，不读取其中的音频地址。请填写名称；有重名版本的条目不会自动匹配。
          </p>
          <p class="muted">
            请确认你有权使用这些文件。仅在授权范围内个人使用，不要制造或传播侵权内容，请支持正版。
          </p>
          <label v-if="desktop">导入个人连接配置（JSON / XML / TXT）<input type="file" accept=".json,.xml,.txt" :disabled="s.busy" @change="importSourceConfig" /></label>
          <p v-if="sourceConfigError" class="job-error" role="alert">{{ sourceConfigError }}</p>
          <button
            class="button primary"
            :disabled="
              s.busy ||
              (sourceKind === 'telegram' && !telegramReady) ||
              (sourceKind === 'plugin' && !pluginCode)
            "
          >
            {{ s.busy ? "正在连接曲库…" : sourceKind === 'plugin' ? "添加插件来源" : "连接曲库" }}
          </button>
          <button
            type="button"
            class="text-button"
            :disabled="s.busy"
            @click="sourceStep = 'type'"
          >
            换类型
          </button>
          </template>
        </form>
        <form v-else-if="saveOpen" @submit.prevent="saveList">
          <label for="playlist-name">歌单名字</label
          ><input
            id="playlist-name"
            v-model="playlistName"
            required
            autofocus
          /><label class="checkbox-label"
            ><input
              v-model="saveSmart"
              type="checkbox"
            />自动更新这份歌单</label
          >
          <p class="muted">
            {{
              saveSmart
                ? "保留选曲描述和来源，跟随新音乐与你的偏好更新。"
                : "保存目前的曲目顺序。"
            }}
          </p>
          <button class="button primary" :disabled="!playlistName.trim()">
            保存歌单
          </button>
        </form>
        <template v-else
          ><label class="command-search"
            ><Icon name="search" :size="20" /><input
              ref="commandInput"
              v-model="query"
              placeholder="搜索歌曲、艺人、专辑…"
              aria-label="命令搜索"
          /></label>
          <div class="command-results">
            <button
              v-for="t in filtered.slice(0, 8)"
              :key="t.id"
              @click="
                s.start(t, filtered);
                commandOpen = false;
              "
            >
              <Icon name="music" /><span
                >{{ t.title }}<small>{{ t.artist }}</small></span
              ><Icon name="play" />
            </button>
            <p v-if="query && !filtered.length" class="list-empty">
              没有找到“{{ query }}”。
            </p>
            <button
              @click="
                go('sound');
                commandOpen = false;
              "
            >
              <Icon name="sliders" /><span>调整声音</span
              ><kbd>声音实验室</kbd></button
            ><button
              @click="
                go('agent');
                commandOpen = false;
              "
            >
              <Icon name="spark" /><span>让搭子为我选曲</span
              ><Icon name="arrow" />
            </button></div
        ></template>
      </section>
    </div>

    <DataTransfer
      v-if="dataOpen"
      :refresh="s.refresh"
      @close="dataOpen = false"
      @toast="s.toast"
    />
    <PlaylistImport
      v-if="importOpen"
      :tracks="s.tracks"
      :save-playlist="saveImportedPlaylist"
      :scan-folder="rescanForImport"
      @close="importOpen = false"
      @created="onPlaylistImported"
    />
    <PluginSearch
      v-if="pluginSearchSource"
      :source="pluginSearchSource"
      @close="pluginSearchSource = null"
      @toast="s.toast"
      @imported="onPluginImported"
    />
    <SwipeMode
      v-if="swipeOpen && s.now"
      :track="s.now"
      :next-track="swipeNextTrack"
      :previous-track="swipePreviousTrack"
      :position="s.playback.position"
      :total="s.playback.duration || s.now.duration"
      :playing="s.playing"
      :loading="s.loading"
      :favorite="s.favorites.has(s.now.id)"
      :index="swipeIndex"
      :total-tracks="swipeQueue.length"
      @close="swipeOpen = false"
      @next="swipeNext"
      @previous="swipePrevious"
      @toggle="s.toggle()"
      @seek="s.seek($event)"
      @like="swipeLike"
      @toggle-favorite="toggleSwipeFavorite"
    />
  </div>
  <MediaInspector v-if="editingMedia" :key="editingMedia.id" :track="editingMedia" @close="editingMedia = null" @saved="s.refresh()" />
</template>
