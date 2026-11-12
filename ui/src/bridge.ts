import { invoke, isTauri, convertFileSrc } from "@tauri-apps/api/core";
import {
  emptyTaste,
  frequencies,
  type Track,
  type Album,
  type Taste,
  type Source,
  type Playback,
  type Playlist,
  type ListenEvent,
  type ImportedPlaylist,
  type ImportedTrack,
  type ImportMatch,
} from "./types";
export const desktop = isTauri();
export const artUrl = (path: string | null) =>
  path ? (desktop ? convertFileSrc(path) : path) : undefined;

// Browser mode accepts real local files. It has no fabricated songs, playback, or listening history.
let tracks: Track[] = [];
let sources: Source[] = [];
const files = new Map<string, Blob>();
let taste: Taste = emptyTaste();
try {
  taste = {
    ...emptyTaste(),
    ...JSON.parse(localStorage.getItem("awake-taste-v1") || "{}"),
  };
} catch {
  /* recover to empty state */
}
function persist() {
  localStorage.setItem("awake-taste-v1", JSON.stringify(taste));
}
const audio = new Audio();
let objectUrl: string | undefined;
let context: AudioContext | undefined;
let filters: BiquadFilterNode[] = [];
let preamp: GainNode | undefined;
let volume: GainNode | undefined;
let current: Track | undefined;
let error: string | null = null;
audio.addEventListener("error", () => {
  error = "浏览器无法解码这个格式，请使用桌面版或导入 WAV / MP3。";
});
function graph() {
  if (context) return;
  context = new AudioContext();
  let node: AudioNode = context.createMediaElementSource(audio);
  preamp = context.createGain();
  node.connect(preamp);
  node = preamp;
  filters = frequencies.map((f) => {
    const filter = context!.createBiquadFilter();
    filter.type = "peaking";
    filter.frequency.value = Math.min(f, context!.sampleRate * 0.49);
    filter.Q.value = 4.31847;
    node.connect(filter);
    node = filter;
    return filter;
  });
  volume = context.createGain();
  volume.gain.value = 0.7;
  node.connect(volume);
  volume.connect(context.destination);
}
function albums(): Album[] {
  const groups = new Map<string, Track[]>();
  for (const t of tracks) {
    const key = `${t.album_artist || t.artist}|${t.album}`;
    groups.set(key, [...(groups.get(key) || []), t]);
  }
  return [...groups.entries()].map(([id, ts]) => ({
    id,
    title: ts[0].album,
    artist: ts[0].artist,
    year: null,
    artwork_path: null,
    tracks: ts,
  }));
}
function ranked(prompt = "", sourceIds: string[] = []) {
  return tracks
    .filter((t) => !sourceIds.length || sourceIds.includes(t.source_id))
    .map((t) => {
      const full = `${t.title} ${t.artist} ${t.album} ${t.genre}`.toLowerCase();
      const matched = prompt
        .toLowerCase()
        .split(/[\s，,、]+/)
        .filter(Boolean)
        .some((s) => full.includes(s));
      const events = taste.events.filter((e) => e.track_id === t.id);
      const skips = events.filter((e) => e.skipped && e.seconds < 30).length;
      const favorite = taste.favorites.includes(t.id);
      const likedArtist = tracks.some(
        (x) => x.artist === t.artist && taste.favorites.includes(x.id),
      );
      const score =
        (matched ? 5 : 0) +
        (favorite ? 3 : 0) +
        (likedArtist ? 1 : 0) -
        skips * 4 -
        events.filter((e) => e.completed).length * 0.35;
      return {
        track: t,
        score,
        reason: matched
          ? "匹配你的描述"
          : favorite
            ? "你收藏过这首歌"
            : likedArtist
              ? "接近你喜欢的艺人"
              : "先从你的曲库认识你",
      };
    })
    .sort((a, b) => b.score - a.score || a.track.id.localeCompare(b.track.id))
    .slice(0, 30);
}

// Native and browser adapters share the same application contract.
export async function call<T = unknown>(
  command: string,
  args: Record<string, any> = {},
): Promise<T> {
  if (desktop) return invoke<T>(command, args);
  let result: unknown;
  switch (command) {
    case "get_services":
      result = { curator: null, music: null };
      break;
    case "load_library":
      result = { tracks, albums: albums(), sources };
      break;
    case "get_taste":
      result = {
        ...taste,
        playlists: taste.playlists.map((p) =>
          p.smart
            ? {
                ...p,
                track_ids: ranked(p.prompt, p.source_ids).map(
                  (r) => r.track.id,
                ),
              }
            : p,
        ),
      };
      break;
    case "frontend_ready":
    case "set_traffic_lights":
      break;
    case "output_device":
      result = {
        name: "浏览器默认输出",
        sample_rate: context?.sampleRate || 0,
        channels: 2,
      };
      break;
    case "scan_library":
      throw new Error("浏览器中请使用“导入音频”；文件夹扫描请在桌面版使用。");
    case "playlist_import_fetch":
    case "playlist_import_file":
    case "playlist_import_match":
      throw new Error(
        "歌单导入需要桌面版后端支持，浏览器预览里暂不可用。",
      );
    case "play_track": {
      const t = tracks.find(
        (t) =>
          t.locator === args.req.locator && t.source_id === args.req.source_id,
      );
      if (!t || !files.has(t.id)) throw new Error("请重新导入本地音频文件。");
      graph();
      await context!.resume();
      audio.pause();
      if (objectUrl) URL.revokeObjectURL(objectUrl);
      objectUrl = URL.createObjectURL(files.get(t.id)!);
      audio.src = objectUrl;
      current = t;
      error = null;
      if (args.req.gains)
        await call("set_eq_curve", {
          req: { gains: args.req.gains, preamp: 0 },
        });
      await audio.play();
      result = t.locator;
      break;
    }
    case "stop_playback":
      audio.pause();
      audio.currentTime = 0;
      break;
    case "pause_playback":
      if (args.paused) audio.pause();
      else await audio.play();
      break;
    case "seek_playback":
      audio.currentTime = Math.min(args.seconds, audio.duration || 0);
      break;
    case "set_volume":
      graph();
      volume!.gain.setTargetAtTime(args.volume, context!.currentTime, 0.015);
      break;
    case "playback_status":
      result = {
        state: error
          ? "error"
          : audio.ended
            ? "ended"
            : !current
              ? "idle"
              : audio.paused
                ? "paused"
                : "playing",
        current: current?.locator || null,
        position: audio.currentTime,
        duration: Number.isFinite(audio.duration) ? audio.duration : 0,
        device: "浏览器默认输出",
        output_rate: context?.sampleRate || 0,
        source_rate: 0,
        error,
      } satisfies Playback;
      break;
    case "set_eq_curve": {
      graph();
      const gains = args.req.gains as number[];
      const count = 512;
      const fs = new Float32Array(count);
      for (let i = 0; i < count; i++)
        fs[i] = 20 * Math.pow(1000, i / (count - 1));
      const sum = new Float32Array(count);
      filters.forEach((filter, i) => {
        filter.gain.value = gains[i];
        const mag = new Float32Array(count),
          phase = new Float32Array(count);
        filter.getFrequencyResponse(fs, mag, phase);
        for (let j = 0; j < count; j++)
          if (Number.isFinite(mag[j]) && mag[j] > 0)
            sum[j] += 20 * Math.log10(mag[j]);
      });
      const headroom = gains.every((g) => g === 0)
        ? 0
        : -(Math.max(0, ...sum) + 1);
      preamp!.gain.setTargetAtTime(
        Math.pow(10, headroom / 20),
        context!.currentTime,
        0.015,
      );
      result = { gains, preamp: headroom };
      break;
    }
    case "recommend":
      result = ranked(args.prompt, args.sourceIds);
      break;
    case "record_listen":
      taste.events.push({ ...(args.event as ListenEvent), at: Date.now() });
      taste.events = taste.events.slice(-5000);
      persist();
      break;
    case "toggle_favorite": {
      const id = args.trackId;
      const exists = taste.favorites.includes(id);
      taste.favorites = exists
        ? taste.favorites.filter((x) => x !== id)
        : [...taste.favorites, id];
      persist();
      result = !exists;
      break;
    }
    case "save_playlist": {
      const p = { ...(args.playlist as Playlist) };
      p.id ||= crypto.randomUUID();
      taste.playlists = taste.playlists.filter((x) => x.id !== p.id);
      taste.playlists.push(p);
      persist();
      result = p;
      break;
    }
    case "delete_playlist":
      taste.playlists = taste.playlists.filter((p) => p.id !== args.id);
      persist();
      break;
    case "save_sound_profile":
      taste.sound_profiles[args.device] = [...args.gains];
      persist();
      break;
    case "save_creation_brief": {
      const brief = {
        id: crypto.randomUUID(),
        prompt: args.prompt,
        created_at: Date.now(),
      };
      taste.briefs.push(brief);
      persist();
      result = brief;
      break;
    }
    default:
      throw new Error(`浏览器模式暂不支持 ${command}`);
  }
  return result as T;
}

// 歌单导入：命令契约由 Rust 端实现，字段为 snake_case。
// Tauri v2 会把 JS 的 camelCase 参数映射到 Rust 的 snake_case；
// 这里同时带上 snake_case 键，兼容未开启默认映射的后端命令。
export async function playlistImportFetch(
  source: string,
  input: string,
): Promise<ImportedPlaylist> {
  return call<ImportedPlaylist>("playlist_import_fetch", { source, input });
}

export async function playlistImportFile(
  fileName: string,
  content: string,
): Promise<ImportedPlaylist> {
  return call<ImportedPlaylist>("playlist_import_file", {
    fileName,
    file_name: fileName,
    content,
  });
}

export async function playlistImportMatch(
  tracks: ImportedTrack[],
): Promise<ImportMatch[]> {
  return call<ImportMatch[]>("playlist_import_match", { tracks });
}

export async function importAudio(input: FileList) {
  const id = "browser-local";
  for (const file of Array.from(input)) {
    const trackId = `${file.name}-${file.size}-${file.lastModified}`;
    if (files.has(trackId)) continue;
    const url = URL.createObjectURL(file);
    const probe = new Audio();
    probe.preload = "metadata";
    probe.src = url;
    const seconds = await new Promise<number>((resolve) => {
      const timeout = window.setTimeout(() => resolve(0), 4000);
      const done = (value: number) => {
        clearTimeout(timeout);
        resolve(value);
      };
      probe.onloadedmetadata = () =>
        done(Number.isFinite(probe.duration) ? probe.duration : 0);
      probe.onerror = () => done(0);
    });
    probe.removeAttribute("src");
    probe.load();
    URL.revokeObjectURL(url);
    files.set(trackId, file);
    const title = file.name.replace(/\.[^.]+$/, "");
    tracks.push({
      id: trackId,
      title,
      artist: "本地导入",
      album_artist: "本地导入",
      album: "我的音乐",
      genre: "",
      year: null,
      track_number: null,
      disc_number: null,
      duration: seconds,
      sample_rate: 0,
      bit_depth: 0,
      channels: 2,
      codec: file.name.split(".").pop() || "",
      source_id: id,
      locator: trackId,
      file_size: file.size,
      artwork_path: null,
      play_count: 0,
      favorite: false,
      is_remote: false,
    });
  }
  sources = [
    {
      id,
      kind: "local",
      name: "本地导入",
      url: "本次浏览器会话",
      track_count: tracks.length,
    },
  ];
}
