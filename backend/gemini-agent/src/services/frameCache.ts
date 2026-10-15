/**
 * TransientFrameCache — the gateway's bounded in-process frame holder
 * (SPEC §9.2, adopting PR #26's `TransientFrameCache` constants).
 *
 * Raw camera frames live ONLY here: per backend instance, TTL-bounded from
 * the trusted server receipt time (client timestamps cannot extend
 * retention), LRU-bounded across sessions, and gone when the process dies.
 * The store never sees frame bytes — only their metadata.
 */

export const FRAME_TTL_MS = 2 * 60 * 1000;
export const FRAME_CACHE_MAX_SESSIONS = 500;

export interface CachedCameraFrame {
  readonly mimeType: string;
  readonly dataBase64: string;
  /** Trusted server receipt time (epoch ms) — never client-supplied. */
  readonly receivedAtMs: number;
}

export class InMemoryFrameHolder {
  private readonly frames = new Map<string, CachedCameraFrame>();

  /**
   * Record the current frame for a session. `receivedAtMs` is the server's
   * own receipt clock — a client timestamp can never extend retention.
   */
  record(sessionId: string, frame: CachedCameraFrame): void {
    // Drop expired entries first so the LRU bound applies to live frames.
    this.sweepExpired(frame.receivedAtMs);
    // Refresh insertion position (Map iteration order = LRU order).
    this.frames.delete(sessionId);
    while (this.frames.size >= FRAME_CACHE_MAX_SESSIONS) {
      const oldest = this.frames.keys().next().value;
      if (oldest === undefined) break;
      this.frames.delete(oldest);
    }
    this.frames.set(sessionId, frame);
  }

  /** The session's current frame, or null when absent or past its TTL. */
  get(sessionId: string, nowMs = Date.now()): CachedCameraFrame | null {
    const frame = this.frames.get(sessionId);
    if (!frame) return null;
    if (nowMs - frame.receivedAtMs >= FRAME_TTL_MS) {
      this.frames.delete(sessionId);
      return null;
    }
    // A read is a use: refresh LRU position.
    this.frames.delete(sessionId);
    this.frames.set(sessionId, frame);
    return frame;
  }

  /** Whether a recent frame exists — the model learns a frame EXISTS, never sees one through the store (SPEC §9.4). */
  hasRecentFrame(sessionId: string, nowMs = Date.now()): boolean {
    return this.get(sessionId, nowMs) !== null;
  }

  /** Session ended: drop its frame immediately. */
  evict(sessionId: string): void {
    this.frames.delete(sessionId);
  }

  get size(): number {
    return this.frames.size;
  }

  private sweepExpired(nowMs: number): void {
    for (const [id, frame] of this.frames) {
      if (nowMs - frame.receivedAtMs >= FRAME_TTL_MS) this.frames.delete(id);
    }
  }
}
