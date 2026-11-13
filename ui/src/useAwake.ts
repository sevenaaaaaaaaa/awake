import { curateLocally } from "./agent";
import { computed, onMounted, onUnmounted, ref } from "vue";
import { call, desktop, importAudio } from "./bridge";
import {
  emptyTaste,
  frequencies,
  type Track,
  type Album,
  type Source,
  type Taste,
  type Playback,
  type Recommendation,
  type Playlist,
  type Services,
  type ListeningContext,
  type Book,
  type WeeklySummary,
  type SpeechJob,
  type SpeechPlan,
  type PlaylistEntry,
  type ScanResult,
} from "./types";

export function useAwake() {
  const tracks = ref<Track[]>([]),
    albums = ref<Album[]>([]),
    sources = ref<Source[]>([]);
  const sourceStatuses = ref<
    Record<
      string,
      {
        refreshing: boolean;
        attempted_at: number;
        succeeded_at: number | null;
        error: string | null;
      }
    >
  >({});
  let libraryRevision: number | null = null;
  const services = ref<Services>({ curator: null, music: null }),
    curationMode = ref("local"),
    curating = ref(false);
  const taste = ref<Taste>(emptyTaste()),
    recommendations = ref<Recommendation[]>([]);
  const books = ref<Book[]>([]),
    weekly = ref<WeeklySummary | null>(null),
    speechJobs = ref<SpeechJob[]>([]);
  const playback = ref<Playback>({
    state: "idle",
    current: null,
    position: 0,
    duration: 0,
    device: "",
    output_rate: 0,
    source_rate: 0,
    error: null,
  });
  const now = ref<Track | null>(null),
    queue = ref<Track[]>([]),
    queueIndex = ref(-1);
  const gains = ref<number[]>(Array(31).fill(0)),
    preamp = ref(0),
    volume = ref(0.7);
  const deviceKey = ref(""),
    listeningContext = ref<ListeningContext | null>(null);
  const device = ref("系统默认输出"),
    deviceRate = ref(0),
    busy = ref(false),
    notice = ref(""),
    fault = ref("");
  const prompt = ref(""),
    sourceFilter = ref<string[]>([]);
  const playing = computed(() => playback.value.state === "playing");
  const loading = computed(() =>
    ["loading", "buffering"].includes(playback.value.state),
  );
  const favorites = computed(() => new Set(taste.value.favorites));
  const learned = computed(
    () =>
      taste.value.events.filter((e) => {
        const track = tracks.value.find((t) => t.id === e.track_id);
        return (
          track &&
          e.seconds >=
            (track.duration > 0
              ? Math.max(0.1, Math.min(track.duration * 0.5, 120))
              : 30)
        );
      }).length,
  );
  let timer: number | undefined,
    noticeTimer: number | undefined,
    pollInFlight = false,
    transition = false;
  let backendQueueBase = 0;
  let browserListened = 0,
    lastTick = 0,
    lastPosition = 0,
    lastDeviceCheck = 0;
  function toast(message: string) {
    notice.value = message;
    clearTimeout(noticeTimer);
    noticeTimer = window.setTimeout(() => (notice.value = ""), 4000);
  }
  async function run<T>(fn: () => Promise<T>): Promise<T | undefined> {
    try {
      fault.value = "";
      return await fn();
    } catch (e) {
      fault.value = String(e).replace(/^Error: /, "");
    }
  }
  async function updateRecommendations() {
    if (curationMode.value === "cloud") return;
    recommendations.value = await curateLocally(
      prompt.value,
      sourceFilter.value,
    );
  }
  async function generateRecommendations(useCloud = false) {
    if (curating.value) return;
    curating.value = true;
    await run(async () => {
      if (useCloud && desktop) {
        const result = await call<{
          mode: string;
          recommendations: Recommendation[];
          warning: string | null;
        }>("curate_music", {
          prompt: prompt.value,
          sourceIds: sourceFilter.value,
        });
        curationMode.value = result.mode;
        recommendations.value = result.recommendations;
        if (result.warning) toast(result.warning);
      } else {
        curationMode.value = "local";
        await updateRecommendations();
      }
    });
    curating.value = false;
  }
  async function refreshTaste() {
    taste.value = await call<Taste>("get_taste");
    await updateRecommendations();
  }
  async function refresh() {
    const lib = await call<{
      tracks: Track[];
      albums: Album[];
      sources: Source[];
    }>("load_library");
    tracks.value = lib.tracks;
    albums.value = lib.albums;
    sources.value = lib.sources;
    if (now.value) now.value = lib.tracks.find(t => t.id === now.value?.id) ?? now.value;
    await refreshTaste();
    await refreshBooks();
    if (desktop)
      libraryRevision = await call<number | null>("library_revision");
  }
  async function refreshBooks(includeAll = false) {
    if (!desktop) {
      books.value = [];
      return;
    }
    try {
      books.value = await call<Book[]>("audiobook_shelf", { includeAll });
    } catch {
      books.value = [];
    }
  }
  async function refreshWeekly(since: number, until: number) {
    if (!desktop) {
      weekly.value = null;
      return;
    }
    weekly.value = await call<WeeklySummary>("weekly_summary", { since, until });
  }
  let lastBookSave = 0;
  async function saveBookProgress(force = false) {
    if (!desktop || !now.value) return;
    const track = now.value;
    const book = books.value.find((b) =>
      b.chapters.some((chapter) => chapter.id === track.id),
    );
    if (!book) return;
    const tick = performance.now();
    if (!force && tick - lastBookSave < 15_000) return;
    lastBookSave = tick;
    const index = book.chapters.findIndex((chapter) => chapter.id === track.id);
    if (index < 0) return;
    const before = book.chapters
      .slice(0, index)
      .reduce((sum, chapter) => sum + chapter.duration, 0);
    const listened = before + playback.value.position;
    const finished =
      book.finished ||
      listened >= book.total_seconds * 0.999 ||
      (index === book.chapters.length - 1 &&
        playback.value.duration > 0 &&
        playback.value.position >= playback.value.duration * 0.98);
    book.current_track = track.id;
    book.position = playback.value.position;
    book.listened_seconds = Math.min(listened, book.total_seconds);
    book.finished = finished;
    book.updated_at = Date.now();
    await call("audiobook_progress", {
      bookId: book.id,
      trackId: track.id,
      position: playback.value.position,
      finished,
    }).catch(() => {});
  }
  async function planSpeech(req: {
    title: string;
    author: string;
    mode: "book" | "drama";
    text: string;
    voice: string;
    useCloud: boolean;
  }) {
    return run(() =>
      call<SpeechPlan>("speech_plan", {
        req: {
          title: req.title,
          author: req.author,
          mode: req.mode,
          text: req.text,
          voice: req.voice,
          use_cloud: req.useCloud,
        },
      }),
    );
  }
  async function renderSpeech(planId: string, voice: string) {
    return run(async () => {
      const job = await call<SpeechJob>("speech_render", {
        planId,
        voice,
      });
      speechJobs.value = [job, ...speechJobs.value];
      return job;
    });
  }
  async function refreshSpeechJobs() {
    if (!desktop) return;
    try {
      const next = await call<SpeechJob[]>("speech_status");
      for (const job of next) {
        const previous = speechJobs.value.find((item) => item.id === job.id);
        if (job.state === "done" && previous && previous.state !== "done") {
          toast("《" + job.title + "》已合成，已加入歌单");
          await refresh();
        }
      }
      speechJobs.value = next;
    } catch {
      /* 轮询失败不影响播放 */
    }
  }
  async function finishBrowser(completed = false, skipped = false) {
    if (desktop || !now.value || browserListened <= 0) return;
    const seconds = browserListened;
    browserListened = 0;
    await call("record_listen", {
      event: {
        track_id: now.value.id,
        seconds,
        completed,
        skipped,
        at: Date.now(),
      },
    });
  }
  async function start(t: Track, list?: Track[]) {
    if (transition) return;
    transition = true;
    await run(async () => {
      await finishBrowser(false, true);
      if (list) queue.value = [...list];
      if (!queue.value.some((x) => x.id === t.id)) queue.value = [t];
      queueIndex.value = queue.value.findIndex((x) => x.id === t.id);
      backendQueueBase = queueIndex.value;
      await call("play_track", {
        req: {
          source_id: t.source_id,
          locator: t.locator,
          gains: [...gains.value],
          queue: desktop
            ? queue.value
                .slice(queueIndex.value + 1)
                .map((t) => ({ source_id: t.source_id, locator: t.locator }))
            : [],
        },
      });
      now.value = t;
      lastTick = performance.now();
      lastPosition = 0;
      browserListened = 0;
      playback.value = {
        ...playback.value,
        state: "loading",
        current: t.locator,
        position: 0,
        duration: t.duration,
        error: null,
      };
    });
    transition = false;
  }
  async function toggle() {
    await run(async () => {
      if (loading.value) return;
      if (!now.value) {
        const list = recommendations.value.map((r) => r.track);
        if (list[0]) await start(list[0], list);
        return;
      }
      if (["ended", "error", "stopped"].includes(playback.value.state)) {
        await start(now.value);
        return;
      }
      await call("pause_playback", { paused: playing.value });
      await poll();
    });
  }
  async function next(manual = true) {
    await finishBrowser(!manual, manual);
    const t = queue.value[queueIndex.value + 1];
    if (t) await start(t);
    else if (manual) toast("已经是队列最后一首");
  }
  async function previous() {
    if (playback.value.position > 3) {
      await seek(0);
      return;
    }
    const t = queue.value[queueIndex.value - 1];
    if (t) await start(t);
  }
  async function seek(seconds: number) {
    await run(() => call("seek_playback", { seconds }));
    lastPosition = seconds;
  }
  async function favorite(t: Track) {
    await run(async () => {
      await call("toggle_favorite", { trackId: t.id });
      await refreshTaste();
    });
  }
  async function applyEq(next = gains.value) {
    await run(async () => {
      const curve = await call<{ gains: number[]; preamp: number }>(
        "set_eq_curve",
        { req: { gains: [...next], preamp: 0 } },
      );
      gains.value = curve.gains;
      preamp.value = curve.preamp;
    });
  }
  async function preset(kind: "flat" | "warm" | "vocal" | "soft") {
    const g = frequencies.map((f) =>
      kind === "warm"
        ? f <= 125
          ? 2
          : f >= 8000
            ? -1
            : 0
        : kind === "vocal"
          ? f >= 1000 && f <= 4000
            ? 2
            : 0
          : kind === "soft"
            ? f >= 4000
              ? -2
              : 0
            : 0,
    );
    await applyEq(g);
    toast(kind === "flat" ? "已恢复原声直通" : "已应用听感预设");
  }
  async function rememberSound() {
    await run(async () => {
      await call("save_sound_profile", {
        device: deviceKey.value || device.value,
        gains: [...gains.value],
      });
      await refreshTaste();
      toast("已记住这个设备的声音，下次自动恢复");
    });
  }
  async function checkDevice(force = false) {
    try {
      const info = await call<{ name: string; sample_rate: number }>(
        "output_device",
      );
      const previous = listeningContext.value;
      const context = desktop
        ? await call<ListeningContext>("listening_context")
        : null;
      const key = context?.sound_key || info.name;
      const outputChanged =
        device.value !== info.name ||
        previous?.identity.uid !== context?.identity.uid ||
        previous?.identity.transport !== context?.identity.transport;
      const changed = outputChanged || deviceKey.value !== key || force;
      listeningContext.value = context;
      deviceKey.value = key;
      device.value = info.name;
      deviceRate.value = info.sample_rate;
      if (changed) {
        const saved =
          taste.value.sound_profiles[key] ||
          (!context?.chain ? taste.value.sound_profiles[info.name] : undefined);
        await applyEq(saved || Array(31).fill(0));
        if (desktop) {
          const corrected = await call<{ preamp: number }>(
            "restore_correction",
            { device: key },
          );
          preamp.value = corrected.preamp;
        }
        if (saved) toast(`已恢复 ${info.name} 的听感`);
        if (outputChanged && now.value && playing.value && desktop) {
          const position = playback.value.position;
          await call("play_track", {
            req: {
              source_id: now.value.source_id,
              locator: now.value.locator,
              gains: [...gains.value],
              continuation: true,
              queue: queue.value
                .slice(queueIndex.value + 1)
                .map((t) => ({ source_id: t.source_id, locator: t.locator })),
            },
          });
          backendQueueBase = queueIndex.value;
          pendingDeviceSeek = position;
        }
      }
    } catch (e) {
      fault.value = String(e);
    }
  }
  let pendingDeviceSeek: number | undefined;
  async function poll() {
    if (pollInFlight) return;
    pollInFlight = true;
    try {
      const state = await call<Playback>("playback_status");
      if (desktop && state.queue_ids?.length && !now.value) {
        const byId = new Map(tracks.value.map((t) => [t.id, t]));
        queue.value = state.queue_ids.flatMap((id) => byId.get(id) || []);
        backendQueueBase = 0;
      }
      const index = backendQueueBase + (state.queue_index || 0);
      if (desktop && queue.value[index]?.id === state.current) {
        now.value = queue.value[index];
        queueIndex.value = index;
      }
      if (state.current && state.current !== now.value?.id && desktop) {
        const current = tracks.value.find((t) => t.id === state.current);
        if (current) {
          now.value = current;
          queueIndex.value = queue.value.findIndex((t) => t.id === current.id);
          await refreshTaste();
        }
      }
      if (!now.value && state.current) {
        const recovered = tracks.value.find((t) => t.id === state.current);
        if (recovered) {
          now.value = recovered;
          queue.value = [recovered];
          queueIndex.value = 0;
        }
      }
      const tick = performance.now();
      if (
        !desktop &&
        state.state === "playing" &&
        state.current === now.value?.locator
      ) {
        const delta = state.position - lastPosition;
        if (delta > 0 && delta < 2 && tick - lastTick < 2000)
          browserListened += delta;
      }
      lastPosition = state.position;
      lastTick = tick;
      const ended = state.state === "ended" && playback.value.state !== "ended";
      playback.value = state;
      if (desktop && state.eq_preamp !== undefined)
        preamp.value = state.eq_preamp;
      if (desktop && now.value) {
        if (state.duration > 0) now.value.duration = state.duration;
        if (state.source_rate > 0) now.value.sample_rate = state.source_rate;
        if (state.source_bits) now.value.bit_depth = state.source_bits;
        if (state.tags) {
          for (const key of [
            "title",
            "artist",
            "album",
            "album_artist",
            "genre",
          ] as const) {
            if (state.tags[key]) now.value[key] = state.tags[key];
          }
        }
      }
      if (state.error) fault.value = state.error;
      if (pendingDeviceSeek !== undefined && state.state === "playing") {
        const pos = pendingDeviceSeek;
        pendingDeviceSeek = undefined;
        await seek(pos);
      }
      if (ended) {
        if (!desktop) await next(false);
        if (desktop) void saveBookProgress(true);
        await refreshTaste();
      }
      if (tick - lastDeviceCheck > 5000 && !transition && !loading.value) {
        lastDeviceCheck = tick;
        await checkDevice();
        if (desktop) {
          sourceStatuses.value = await call("source_refresh_status");
          void saveBookProgress();
          await refreshSpeechJobs();
          const revision = await call<number | null>("library_revision");
          if (revision !== libraryRevision) await refresh();
          await refreshTaste();
          if (
            taste.value.generations.some(
              (g) =>
                g.state === "completed" &&
                g.track_id &&
                !tracks.value.some((t) => t.id === g.track_id),
            )
          )
            await refresh();
        }
      }
    } catch (e) {
      fault.value = String(e);
    } finally {
      pollInFlight = false;
    }
  }
  async function scan(path: string, name?: string, kind?: string) {
    if (!path.trim()) {
      fault.value = "请输入音乐文件夹的完整路径";
      return;
    }
    busy.value = true;
    let result: ScanResult | undefined;
    await run(async () => {
      result = await call<ScanResult>("scan_library", {
        req: { path: path.trim(), name, kind },
      });
      await refresh();
      const skipped = result.skipped?.length ?? 0;
      toast(
        "已扫描 " +
          result.tracks.length +
          " 首音乐" +
          (skipped ? "，跳过 " + skipped + " 个文件" : ""),
      );
    });
    busy.value = false;
    return result;
  }
  async function importPaths(paths: string[]) {
    if (!paths.length) return;
    busy.value = true;
    let result: ScanResult | undefined;
    await run(async () => {
      result = await call<ScanResult>("import_local_files", {
        paths,
        append: true,
      });
      await refresh();
      const skipped = result.skipped?.length ?? 0;
      toast(
        "已导入 " +
          result.tracks.length +
          " 首本地音乐" +
          (skipped ? "，跳过 " + skipped + " 个文件" : ""),
      );
    });
    busy.value = false;
    return result;
  }
  async function setSourceAuto(source: Source, enabled: boolean) {
    await run(async () => {
      await call("set_source_auto_refresh", { id: source.id, enabled });
      source.enabled = enabled;
      toast(enabled ? "已开启每 15 分钟自动更新" : "已关闭自动更新");
    });
  }
  async function refreshSource(source: Source) {
    if (["webdav", "plex", "telegram"].includes(source.kind)) {
      busy.value = true;
      await run(async () => {
        const count = await call<number>("refresh_remote_source", {
          id: source.id,
        });
        await refresh();
        toast("来源曲库已更新：" + count + " 首");
      });
      busy.value = false;
    } else await scan(source.url, source.name, source.kind);
  }
  async function importFiles(files: FileList) {
    busy.value = true;
    await run(async () => {
      await importAudio(files);
      await refresh();
      toast(`已导入 ${tracks.value.length} 首本地音乐`);
    });
    busy.value = false;
  }
  async function savePlaylist(
    name: string,
    smart: boolean,
    items: Track[],
    customPrompt = prompt.value,
    entries?: PlaylistEntry[],
  ) {
    return run(async () => {
      const saved = await call<Playlist>("save_playlist", {
        playlist: {
          id: "",
          name,
          prompt: customPrompt,
          source_ids: [...sourceFilter.value],
          track_ids: items.map((t) => t.id),
          smart,
          entries:
            entries ??
            items.map((t) => ({
              track_id: t.id,
              title: t.title,
              artist: t.artist,
              album: t.album,
            })),
        },
      });
      await refreshTaste();
      toast(smart ? "动态歌单已保存，曲库与偏好变化时自动更新" : "歌单已保存");
      return saved;
    });
  }
  async function removePlaylist(id: string) {
    await run(async () => {
      await call("delete_playlist", { id });
      await refreshTaste();
      toast("已删除歌单");
    });
  }
  async function setVolume() {
    await run(() => call("set_volume", { volume: volume.value }));
  }
  onMounted(async () => {
    await run(refresh);
    if (desktop)
      await run(async () => {
        services.value = await call<Services>("get_services");
      });
    await checkDevice();
    await call("frontend_ready", {
      version: "0.8.0",
      tracks: tracks.value.length,
    }).catch(() => {});
    timer = window.setInterval(() => void poll(), 350);
  });
  onUnmounted(() => {
    clearInterval(timer);
    clearTimeout(noticeTimer);
    void finishBrowser();
  });
  return {
    services,
    curationMode,
    curating,
    generateRecommendations,
    tracks,
    albums,
    sources,
    taste,
    recommendations,
    playback,
    now,
    queue,
    queueIndex,
    gains,
    preamp,
    volume,
    device,
    deviceKey,
    listeningContext,
    checkDevice,
    deviceRate,
    busy,
    notice,
    fault,
    prompt,
    sourceFilter,
    playing,
    loading,
    favorites,
    learned,
    toast,
    run,
    books,
    weekly,
    speechJobs,
    refreshBooks,
    refreshWeekly,
    saveBookProgress,
    planSpeech,
    renderSpeech,
    refreshSpeechJobs,
    importPaths,
    refresh,
    refreshTaste,
    updateRecommendations,
    start,
    toggle,
    next,
    previous,
    seek,
    favorite,
    applyEq,
    preset,
    rememberSound,
    scan,
    refreshSource,
    sourceStatuses,
    setSourceAuto,
    importFiles,
    savePlaylist,
    removePlaylist,
    setVolume,
  };
}
