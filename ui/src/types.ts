export interface ListeningChain {
  id: string;
  device_uid: string;
  transport: string;
  name: string;
  headphone: string;
  connection: string;
  frontend: string;
  acoustic_mode: string;
  fit: string;
  codec_preference: string;
  reference_model: string;
  reference_evidence: string;
}
export interface ListeningContext {
  identity: { uid: string; transport: string };
  chain: ListeningChain | null;
  sound_key: string;
}
export interface Track {
  id: string;
  title: string;
  artist: string;
  album_artist: string;
  album: string;
  genre: string;
  year: number | null;
  track_number: number | null;
  disc_number: number | null;
  duration: number;
  sample_rate: number;
  bit_depth: number;
  channels: number;
  codec: string;
  source_id: string;
  locator: string;
  file_size: number;
  artwork_path: string | null;
  play_count: number;
  favorite: boolean;
  is_remote: boolean;
}
export interface Album {
  id: string;
  title: string;
  artist: string;
  year: number | null;
  artwork_path: string | null;
  tracks: Track[];
}
export interface Source {
  enabled?: boolean;
  last_scan?: number | null;
  id: string;
  kind: string;
  name: string;
  url: string;
  track_count: number;
}
export interface Playlist {
  id: string;
  name: string;
  prompt: string;
  source_ids: string[];
  track_ids: string[];
  smart: boolean;
}
export interface ListenEvent {
  track_id: string;
  seconds: number;
  completed: boolean;
  skipped: boolean;
  at: number;
}
export interface Brief {
  id: string;
  prompt: string;
  created_at: number;
}
export interface HeadphoneProfile {
  id: string;
  name: string;
  measurement_source: string;
  target: string;
  preamp: number;
  filters: { kind: string; frequency: number; gain_db: number; q: number }[];
}
export interface Service {
  endpoint: string;
  model: string;
}
export interface Services {
  curator: Service | null;
  music: Service | null;
}
export interface Generation {
  id: string;
  prompt: string;
  state: string;
  model: string;
  provider: string;
  created_at: number;
  track_id: string | null;
  file_path: string | null;
  error: string | null;
}
export interface Taste {
  listening_chains: ListeningChain[];
  active_chains: Record<string, string>;
  feeds: {
    id: string;
    name: string;
    url: string;
    playlist_id: string;
    matched: number;
    total: number;
    refreshed_at: number | null;
    error: string | null;
  }[];
  generations: Generation[];
  headphone_profiles: HeadphoneProfile[];
  active_corrections: Record<string, string>;
  events: ListenEvent[];
  favorites: string[];
  playlists: Playlist[];
  sound_profiles: Record<string, number[]>;
  briefs: Brief[];
}
export interface Recommendation {
  track: Track;
  reason: string;
  score: number;
}
export interface Playback {
  queue_ids?: string[];
  eq_preamp?: number;
  processed?: boolean;
  source_bits?: number;
  codec?: string;
  tags?: {
    title: string;
    artist: string;
    album: string;
    album_artist: string;
    genre: string;
  };
  queue_index?: number;
  buffered_frames?: number;
  buffer_capacity_frames?: number;
  underruns?: number;
  startup_ms?: number;
  streaming?: boolean;
  state: string;
  current: string | null;
  position: number;
  duration: number;
  device: string;
  output_rate: number;
  source_rate: number;
  error: string | null;
}
export const frequencies = [
  20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630,
  800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500,
  16000, 20000,
];
export const emptyTaste = (): Taste => ({
  listening_chains: [],
  active_chains: {},
  events: [],
  favorites: [],
  playlists: [],
  sound_profiles: {},
  briefs: [],
  headphone_profiles: [],
  active_corrections: {},
  generations: [],
  feeds: [],
});
export const duration = (s: number) =>
  `${Math.floor((s || 0) / 60)}:${Math.floor((s || 0) % 60)
    .toString()
    .padStart(2, "0")}`;
export const format = (t: Track) =>
  `${t.codec.toUpperCase()} · ${t.bit_depth || "—"} bit · ${t.sample_rate ? (t.sample_rate / 1000).toFixed(1) : "—"} kHz`;
