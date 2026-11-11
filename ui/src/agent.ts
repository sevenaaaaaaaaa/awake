import { call } from "./bridge";
import type { Recommendation } from "./types";

/** A cloud provider receives a bounded playable catalog, never unrestricted playback control. */
export interface CurateRequest {
  intent: string;
  candidates: {
    id: string;
    title: string;
    artist: string;
    album: string;
    genre: string;
  }[];
  preferences: { favoriteArtists: string[]; favoriteGenres: string[] };
}
export interface CurateResponse {
  title: string;
  selections: { trackId: string; reason: string }[];
}
export interface GenerationRequest {
  prompt: string;
  instrumental: boolean;
  durationSeconds: number;
  /** Set only after an explicit user generation action. */
  userRequested: true;
}
export type GenerationResult =
  | { status: "queued" | "running"; jobId: string }
  | {
      status: "completed";
      jobId: string;
      audioUrl: string;
      title: string;
      provider: string;
    }
  | { status: "failed"; jobId: string; error: string };
export interface MusicAIProvider {
  id: string;
  capabilities: { curate: boolean; generateAudio: boolean };
  curate(request: CurateRequest, signal: AbortSignal): Promise<CurateResponse>;
  generate(
    request: GenerationRequest,
    signal: AbortSignal,
  ): Promise<GenerationResult>;
  getGeneration(jobId: string, signal: AbortSignal): Promise<GenerationResult>;
}

/** Reject hallucinated IDs and duplicates before an AI proposal becomes a playable playlist. */
export function resolveProposal(
  response: CurateResponse,
  candidates: Recommendation[],
): Recommendation[] {
  const byId = new Map(candidates.map((r) => [r.track.id, r]));
  const used = new Set<string>();
  return response.selections
    .flatMap((item) => {
      const match = byId.get(item.trackId);
      if (!match || used.has(item.trackId)) return [];
      used.add(item.trackId);
      return [{ ...match, reason: item.reason.slice(0, 180) }];
    })
    .slice(0, 30);
}

// Current product uses this local adapter; no credentials, cloud requests, or generation jobs.
export function curateLocally(intent: string, sourceIds: string[]) {
  return call<Recommendation[]>("recommend", { prompt: intent, sourceIds });
}
