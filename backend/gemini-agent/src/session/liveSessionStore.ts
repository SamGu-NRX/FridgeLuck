import { FieldValue, Firestore, Timestamp } from "@google-cloud/firestore";
import type { AppConfig, SessionStoreMode } from "../config.js";
import type { ConfidenceAssessResponse } from "../types/contracts.js";

/**
 * Retention policy for live sessions and camera frames.
 *
 * Raw camera frames are transient: they are held only in a bounded
 * in-process cache and expire two minutes after trusted server receipt.
 * Frame bytes are never persisted — session records (memory or Firestore)
 * carry only frame metadata. Sessions expire logically 24 hours after
 * their last activity; an `expireAt` field is written for Firestore so a
 * TTL policy can delete whole documents later. Firestore TTL deletion is
 * asynchronous and is NOT the access-control boundary: application reads
 * enforce expiry before returning any state.
 *
 * These durations are unmeasured: nothing outside this process measures,
 * renews, or alerts on them. See planning/live_session_frame_retention.md.
 */
export const FRAME_TTL_MS = 2 * 60 * 1000;

/** Maximum number of distinct sessions holding a transient frame, per store. */
export const FRAME_CACHE_MAX_SESSIONS = 500;

/** Logical session expiry: 24 hours after last activity. */
export const SESSION_TTL_MS = 24 * 60 * 60 * 1000;

export interface StoredRecipeIngredient {
  name: string;
  quantityText?: string;
  quantityGrams?: number;
}

export interface StoredRecipeContext {
  id?: string;
  title: string;
  timeMinutes?: number;
  servings?: number;
  instructions?: string;
  ingredients?: StoredRecipeIngredient[];
}

export interface StoredIngredientContext {
  name: string;
  confidence?: number;
  quantityGrams?: number;
}

export interface StoredCameraFrame {
  mimeType: string;
  dataBase64: string;
  /**
   * Trusted server receipt time (ISO). Assigned by the store from its own
   * clock when the frame is recorded; any client-provided value is ignored
   * and can never extend retention.
   */
  updatedAt: string;
}

/** Metadata-only record of the latest camera frame. Safe to persist. */
export interface StoredCameraFrameMetadata {
  mimeType: string;
  /** Trusted server receipt time (ISO), set from the store clock. */
  receivedAt: string;
  /** Length of the base64 payload, for diagnostics only. */
  sizeBytes?: number;
}

export interface InventoryMutationAuditEntry {
  operation: string;
  idempotencyKey: string;
  itemCount: number;
  committed: boolean;
  createdAt: string;
}

export interface LiveSessionState {
  sessionId: string;
  createdAt: string;
  updatedAt: string;
  /**
   * Logical expiry (ISO): 24 hours after the last activity. Refreshed on
   * every write. Also persisted to Firestore for later TTL deletion.
   */
  expireAt?: string;
  selectedRecipe?: StoredRecipeContext;
  confirmedIngredients: StoredIngredientContext[];
  latestConfidence?: ConfidenceAssessResponse;
  /**
   * Transient frame bytes, rehydrated from the bounded in-process cache
   * while the frame is still fresh. Never populated from persisted data
   * and never persisted.
   */
  latestCameraFrame?: StoredCameraFrame;
  latestCameraFrameMetadata?: StoredCameraFrameMetadata;
  mutationAudit: InventoryMutationAuditEntry[];
  lastUserMessage?: string;
}

/** Session state as it is stored (memory map or Firestore): no frame bytes. */
type PersistedSessionState = Omit<LiveSessionState, "latestCameraFrame">;

export interface LiveSessionContextPatch {
  selectedRecipe?: StoredRecipeContext;
  confirmedIngredients?: StoredIngredientContext[];
  latestConfidence?: ConfidenceAssessResponse;
}

export interface LiveSessionStore {
  readonly mode: SessionStoreMode;
  ensureSession(sessionId: string): Promise<LiveSessionState>;
  getSession(sessionId: string): Promise<LiveSessionState>;
  patchContext(
    sessionId: string,
    patch: LiveSessionContextPatch,
  ): Promise<LiveSessionState>;
  recordLatestFrame(
    sessionId: string,
    frame: StoredCameraFrame,
  ): Promise<LiveSessionState>;
  recordLatestConfidence(
    sessionId: string,
    assessment: ConfidenceAssessResponse,
  ): Promise<LiveSessionState>;
  appendMutationAudit(
    sessionId: string,
    entry: InventoryMutationAuditEntry,
  ): Promise<LiveSessionState>;
  recordUserMessage(sessionId: string, text: string): Promise<LiveSessionState>;
}

/** Minimal structural view of the Firestore surface the store uses. */
export interface LiveSessionFirestoreSnapshotLike {
  exists: boolean;
  data(): Record<string, unknown> | undefined;
}

export interface LiveSessionFirestoreDocRefLike {
  get(): Promise<LiveSessionFirestoreSnapshotLike>;
  set(
    data: Record<string, unknown>,
    options?: { merge?: boolean },
  ): Promise<void>;
}

export interface LiveSessionFirestoreLike {
  collection(name: string): {
    doc(id: string): LiveSessionFirestoreDocRefLike;
  };
}

export interface LiveSessionStoreOptions {
  /** Clock source (ms). Defaults to Date.now. Tests inject a controllable clock. */
  now?: () => number;
  /**
   * Transient frame retention in ms, counted from trusted server receipt.
   * Default: FRAME_TTL_MS (2 minutes). Client timestamps cannot extend it.
   */
  frameTtlMs?: number;
  /**
   * Bound on distinct sessions holding a transient frame, per store.
   * Default: FRAME_CACHE_MAX_SESSIONS (500). Least-recently-used sessions
   * are evicted first.
   */
  frameCacheMaxSessions?: number;
  /** Logical session expiry in ms of inactivity. Default: SESSION_TTL_MS (24h). */
  sessionTtlMs?: number;
  /**
   * Test seam: a Firestore-compatible handle. Production creates a real
   * Firestore client when omitted.
   */
  firestore?: LiveSessionFirestoreLike;
}

interface FrameCacheEntry {
  frame: StoredCameraFrame;
  /** Trusted server receipt (ms). */
  receiptMs: number;
  /** Last access (ms), for LRU eviction. */
  lastAccessMs: number;
}

/**
 * Bounded, in-process cache of raw camera frames. Entries expire two
 * minutes (by default) after trusted server receipt and the cache holds at
 * most `maxSessions` distinct sessions, evicting least-recently-used. This
 * is the only place raw frame bytes are retained.
 */
export class TransientFrameCache {
  private readonly entries = new Map<string, FrameCacheEntry>();
  private readonly maxSessions: number;
  private readonly ttlMs: number;

  constructor(maxSessions: number = FRAME_CACHE_MAX_SESSIONS, ttlMs: number = FRAME_TTL_MS) {
    this.maxSessions = maxSessions;
    this.ttlMs = ttlMs;
  }

  get size(): number {
    return this.entries.size;
  }

  set(sessionId: string, frame: StoredCameraFrame, receiptMs: number): void {
    // Re-insert to mark this session as most-recently-used.
    this.entries.delete(sessionId);
    this.entries.set(sessionId, { frame, receiptMs, lastAccessMs: receiptMs });
    this.evictOverLimit();
  }

  /** Returns the frame while nowMs is inside the TTL window, else undefined. */
  get(sessionId: string, nowMs: number): StoredCameraFrame | undefined {
    const entry = this.entries.get(sessionId);
    if (!entry) return undefined;
    if (this.isExpired(entry, nowMs)) {
      this.entries.delete(sessionId);
      return undefined;
    }
    // Refresh recency on read.
    this.entries.delete(sessionId);
    this.entries.set(sessionId, { ...entry, lastAccessMs: nowMs });
    return { ...entry.frame };
  }

  isExpired(entry: FrameCacheEntry, nowMs: number): boolean {
    // A frame's lifetime is TTL ms from trusted server receipt; it expires
    // at the boundary. Client-provided timestamps never enter this math.
    return nowMs - entry.receiptMs >= this.ttlMs;
  }

  sweepExpired(nowMs: number): void {
    for (const [id, entry] of this.entries) {
      if (this.isExpired(entry, nowMs)) this.entries.delete(id);
    }
  }

  private evictOverLimit(): void {
    // Map iteration order is insertion order; delete/re-insert on access
    // makes the first key the least-recently-used entry.
    while (this.entries.size > this.maxSessions) {
      const oldest = this.entries.keys().next().value;
      if (oldest === undefined) break;
      this.entries.delete(oldest);
    }
  }
}

function createBlankSession(
  sessionId: string,
  nowMs: number,
  sessionTtlMs: number,
): PersistedSessionState {
  const now = iso(nowMs);
  return {
    sessionId,
    createdAt: now,
    updatedAt: now,
    expireAt: iso(nowMs + sessionTtlMs),
    confirmedIngredients: [],
    mutationAudit: [],
  };
}

function iso(ms: number): string {
  return new Date(ms).toISOString();
}

function parseMs(value: string | undefined): number | undefined {
  if (!value) return undefined;
  const ms = Date.parse(value);
  return Number.isNaN(ms) ? undefined : ms;
}

/**
 * Logical expiry for a persisted session. Prefers the recorded `expireAt`;
 * falls back to `updatedAt` + TTL for legacy records that predate the
 * field. Unparsable timestamps fail closed (treated as expired) so nothing
 * stale can be resurrected.
 */
function isSessionExpired(
  state: PersistedSessionState,
  sessionTtlMs: number,
  nowMs: number,
): boolean {
  const explicit = parseMs(state.expireAt);
  if (explicit !== undefined) return explicit <= nowMs;
  const updatedAt = parseMs(state.updatedAt);
  if (updatedAt === undefined) return true;
  return updatedAt + sessionTtlMs <= nowMs;
}

function frameMetadata(
  frame: StoredCameraFrame,
  receivedAtIso: string,
): StoredCameraFrameMetadata {
  return {
    mimeType: frame.mimeType,
    receivedAt: receivedAtIso,
    ...(typeof frame.dataBase64 === "string"
      ? { sizeBytes: frame.dataBase64.length }
      : {}),
  };
}

function omitUndefinedFields(
  input: Record<string, unknown>,
): Record<string, unknown> {
  const output: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(input)) {
    if (value !== undefined) output[key] = value;
  }
  return output;
}

export function createLiveSessionStore(
  config: Pick<
    AppConfig,
    | "sessionStoreMode"
    | "projectId"
    | "firestoreCollection"
    | "firestoreEmulator"
  >,
  options: LiveSessionStoreOptions = {},
): LiveSessionStore {
  const mode =
    config.sessionStoreMode === "auto"
      ? config.projectId || config.firestoreEmulator
        ? "firestore"
        : "memory"
      : config.sessionStoreMode;

  if (mode === "firestore") {
    return new FirestoreLiveSessionStore(config.firestoreCollection, options);
  }

  return new MemoryLiveSessionStore(options);
}

class MemoryLiveSessionStore implements LiveSessionStore {
  readonly mode: SessionStoreMode = "memory";
  private readonly sessions = new Map<string, PersistedSessionState>();
  private readonly frames: TransientFrameCache;
  private readonly now: () => number;
  private readonly sessionTtlMs: number;

  constructor(options: LiveSessionStoreOptions = {}) {
    this.frames = new TransientFrameCache(
      options.frameCacheMaxSessions,
      options.frameTtlMs,
    );
    this.now = options.now ?? Date.now;
    this.sessionTtlMs = options.sessionTtlMs ?? SESSION_TTL_MS;
  }

  async ensureSession(sessionId: string): Promise<LiveSessionState> {
    const nowMs = this.now();
    const state = this.ensureLiveRecord(sessionId, nowMs);
    return this.view(sessionId, state, nowMs);
  }

  async getSession(sessionId: string): Promise<LiveSessionState> {
    const nowMs = this.now();
    this.sweepExpired(nowMs);
    const existing = this.sessions.get(sessionId);
    if (!existing || isSessionExpired(existing, this.sessionTtlMs, nowMs)) {
      // Missing or expired: return blank state without creating, renewing,
      // or restoring anything. Expired records are never resurrected.
      return createBlankSession(sessionId, nowMs, this.sessionTtlMs);
    }
    return this.view(sessionId, existing, nowMs);
  }

  async patchContext(
    sessionId: string,
    patch: LiveSessionContextPatch,
  ): Promise<LiveSessionState> {
    const nowMs = this.now();
    const existing = this.ensureLiveRecord(sessionId, nowMs);
    const next: PersistedSessionState = {
      ...existing,
      ...(patch.selectedRecipe !== undefined
        ? { selectedRecipe: patch.selectedRecipe }
        : {}),
      ...(patch.confirmedIngredients !== undefined
        ? { confirmedIngredients: patch.confirmedIngredients }
        : {}),
      ...(patch.latestConfidence !== undefined
        ? { latestConfidence: patch.latestConfidence }
        : {}),
      updatedAt: iso(nowMs),
      expireAt: iso(nowMs + this.sessionTtlMs),
    };
    this.sessions.set(sessionId, next);
    return this.view(sessionId, next, nowMs);
  }

  async recordLatestFrame(
    sessionId: string,
    frame: StoredCameraFrame,
  ): Promise<LiveSessionState> {
    const nowMs = this.now();
    const existing = this.ensureLiveRecord(sessionId, nowMs);
    // Bytes go to the bounded transient cache only. Receipt time comes from
    // the store clock ("trusted server receipt"); the frame's own — possibly
    // client-provided — updatedAt is ignored for retention.
    this.frames.set(
      sessionId,
      {
        mimeType: frame.mimeType,
        dataBase64: frame.dataBase64,
        updatedAt: iso(nowMs),
      },
      nowMs,
    );
    const next: PersistedSessionState = {
      ...existing,
      latestCameraFrameMetadata: frameMetadata(frame, iso(nowMs)),
      updatedAt: iso(nowMs),
      expireAt: iso(nowMs + this.sessionTtlMs),
    };
    this.sessions.set(sessionId, next);
    return this.view(sessionId, next, nowMs);
  }

  async recordLatestConfidence(
    sessionId: string,
    assessment: ConfidenceAssessResponse,
  ): Promise<LiveSessionState> {
    return this.patchContext(sessionId, { latestConfidence: assessment });
  }

  async appendMutationAudit(
    sessionId: string,
    entry: InventoryMutationAuditEntry,
  ): Promise<LiveSessionState> {
    const nowMs = this.now();
    const existing = this.ensureLiveRecord(sessionId, nowMs);
    const next: PersistedSessionState = {
      ...existing,
      mutationAudit: [...existing.mutationAudit, entry].slice(-30),
      updatedAt: iso(nowMs),
      expireAt: iso(nowMs + this.sessionTtlMs),
    };
    this.sessions.set(sessionId, next);
    return this.view(sessionId, next, nowMs);
  }

  async recordUserMessage(
    sessionId: string,
    text: string,
  ): Promise<LiveSessionState> {
    const nowMs = this.now();
    const existing = this.ensureLiveRecord(sessionId, nowMs);
    const next: PersistedSessionState = {
      ...existing,
      lastUserMessage: text,
      updatedAt: iso(nowMs),
      expireAt: iso(nowMs + this.sessionTtlMs),
    };
    this.sessions.set(sessionId, next);
    return this.view(sessionId, next, nowMs);
  }

  /**
   * Returns the live record for a session, creating a fresh blank session
   * when it is missing or expired. Expired records are never renewed or
   * restored — their state is discarded (fresh server-owned session).
   */
  private ensureLiveRecord(
    sessionId: string,
    nowMs: number,
  ): PersistedSessionState {
    this.sweepExpired(nowMs);
    const existing = this.sessions.get(sessionId);
    if (existing && !isSessionExpired(existing, this.sessionTtlMs, nowMs)) {
      return existing;
    }
    const created = createBlankSession(sessionId, nowMs, this.sessionTtlMs);
    this.sessions.set(sessionId, created);
    return created;
  }

  private sweepExpired(nowMs: number): void {
    for (const [id, state] of this.sessions) {
      if (isSessionExpired(state, this.sessionTtlMs, nowMs)) {
        this.sessions.delete(id);
      }
    }
    this.frames.sweepExpired(nowMs);
  }

  private view(
    sessionId: string,
    state: PersistedSessionState,
    nowMs: number,
  ): LiveSessionState {
    const frame = this.frames.get(sessionId, nowMs);
    return frame ? { ...state, latestCameraFrame: frame } : { ...state };
  }
}

class FirestoreLiveSessionStore implements LiveSessionStore {
  readonly mode: SessionStoreMode = "firestore";
  private readonly firestore: LiveSessionFirestoreLike;
  private readonly collectionName: string;
  private readonly frames: TransientFrameCache;
  private readonly now: () => number;
  private readonly sessionTtlMs: number;

  constructor(collectionName: string, options: LiveSessionStoreOptions = {}) {
    this.collectionName = collectionName;
    // The real client satisfies the operations this store uses; it is narrowed
    // behind the seam type so tests can inject a Firestore-compatible fake.
    this.firestore =
      options.firestore ??
      (new Firestore() as unknown as LiveSessionFirestoreLike);
    this.frames = new TransientFrameCache(
      options.frameCacheMaxSessions,
      options.frameTtlMs,
    );
    this.now = options.now ?? Date.now;
    this.sessionTtlMs = options.sessionTtlMs ?? SESSION_TTL_MS;
  }

  async ensureSession(sessionId: string): Promise<LiveSessionState> {
    const nowMs = this.now();
    const state = await this.ensureLiveRecord(sessionId, nowMs);
    return this.view(sessionId, state, nowMs);
  }

  async getSession(sessionId: string): Promise<LiveSessionState> {
    const nowMs = this.now();
    const snap = await this.doc(sessionId).get();
    const data = snap.exists ? snap.data() : undefined;
    if (data === undefined) {
      return createBlankSession(sessionId, nowMs, this.sessionTtlMs);
    }
    const persisted = this.fromDoc(sessionId, data, nowMs);
    if (isSessionExpired(persisted, this.sessionTtlMs, nowMs)) {
      // Expiry enforced before returning state. The record is left untouched
      // (no renewal, no restore) so Firestore TTL deletion can still collect it.
      return createBlankSession(sessionId, nowMs, this.sessionTtlMs);
    }
    return this.view(sessionId, persisted, nowMs);
  }

  async patchContext(
    sessionId: string,
    patch: LiveSessionContextPatch,
  ): Promise<LiveSessionState> {
    const nowMs = this.now();
    await this.ensureLiveRecord(sessionId, nowMs);
    await this.doc(sessionId).set(
      this.mergeWrite(nowMs, omitUndefinedFields({ ...patch })),
      { merge: true },
    );
    return this.getSession(sessionId);
  }

  async recordLatestFrame(
    sessionId: string,
    frame: StoredCameraFrame,
  ): Promise<LiveSessionState> {
    const nowMs = this.now();
    await this.ensureLiveRecord(sessionId, nowMs);
    // Bytes go to the bounded transient cache only; Firestore receives
    // metadata. Receipt time comes from the store clock ("trusted server
    // receipt"); the frame's own — possibly client-provided — updatedAt is
    // ignored for retention.
    this.frames.set(
      sessionId,
      {
        mimeType: frame.mimeType,
        dataBase64: frame.dataBase64,
        updatedAt: iso(nowMs),
      },
      nowMs,
    );
    await this.doc(sessionId).set(
      this.mergeWrite(nowMs, {
        latestCameraFrameMetadata: frameMetadata(frame, iso(nowMs)),
      }),
      { merge: true },
    );
    return this.getSession(sessionId);
  }

  async recordLatestConfidence(
    sessionId: string,
    assessment: ConfidenceAssessResponse,
  ): Promise<LiveSessionState> {
    return this.patchContext(sessionId, { latestConfidence: assessment });
  }

  async appendMutationAudit(
    sessionId: string,
    entry: InventoryMutationAuditEntry,
  ): Promise<LiveSessionState> {
    const nowMs = this.now();
    await this.ensureLiveRecord(sessionId, nowMs);
    const current = await this.getSession(sessionId);
    await this.doc(sessionId).set(
      this.mergeWrite(nowMs, {
        mutationAudit: [...current.mutationAudit, entry].slice(-30),
      }),
      { merge: true },
    );
    return this.getSession(sessionId);
  }

  async recordUserMessage(
    sessionId: string,
    text: string,
  ): Promise<LiveSessionState> {
    const nowMs = this.now();
    await this.ensureLiveRecord(sessionId, nowMs);
    await this.doc(sessionId).set(
      this.mergeWrite(nowMs, { lastUserMessage: text }),
      { merge: true },
    );
    return this.getSession(sessionId);
  }

  private doc(sessionId: string): LiveSessionFirestoreDocRefLike {
    return this.firestore.collection(this.collectionName).doc(sessionId);
  }

  /**
   * Returns the live record for a session, creating a fresh blank session
   * when it is missing or expired. Expired records are never renewed or
   * restored — the document is reset in place to a fresh server-owned
   * session. The reset is a full-document set, which also drops legacy
   * fields (including any persisted frame bytes) from the touched document.
   */
  private async ensureLiveRecord(
    sessionId: string,
    nowMs: number,
  ): Promise<PersistedSessionState> {
    const ref = this.doc(sessionId);
    const snap = await ref.get();
    const data = snap.exists ? snap.data() : undefined;
    if (data !== undefined) {
      const persisted = this.fromDoc(sessionId, data, nowMs);
      if (!isSessionExpired(persisted, this.sessionTtlMs, nowMs)) {
        return persisted;
      }
    }
    const created = createBlankSession(sessionId, nowMs, this.sessionTtlMs);
    await ref.set(this.toDoc(created, nowMs));
    return created;
  }

  private view(
    sessionId: string,
    state: PersistedSessionState,
    nowMs: number,
  ): LiveSessionState {
    const frame = this.frames.get(sessionId, nowMs);
    return frame ? { ...state, latestCameraFrame: frame } : { ...state };
  }

  /**
   * Payload for a merge write. Every write refreshes activity stamps and
   * deletes the legacy `latestCameraFrame` field with actual field-deletion
   * semantics (FieldValue.delete) — omitting the key from the merge would
   * leave legacy frame bytes in the document.
   */
  private mergeWrite(
    nowMs: number,
    payload: Record<string, unknown>,
  ): Record<string, unknown> {
    return {
      ...payload,
      updatedAt: Timestamp.fromMillis(nowMs),
      expireAt: Timestamp.fromMillis(nowMs + this.sessionTtlMs),
      latestCameraFrame: FieldValue.delete(),
    };
  }

  /** Full-document payload for create/reset: metadata only, never frame bytes. */
  private toDoc(state: PersistedSessionState, nowMs: number): Record<string, unknown> {
    return omitUndefinedFields({
      sessionId: state.sessionId,
      createdAt: Timestamp.fromMillis(parseMs(state.createdAt) ?? nowMs),
      updatedAt: Timestamp.fromMillis(parseMs(state.updatedAt) ?? nowMs),
      expireAt: Timestamp.fromMillis(nowMs + this.sessionTtlMs),
      selectedRecipe: state.selectedRecipe,
      confirmedIngredients: state.confirmedIngredients,
      latestConfidence: state.latestConfidence,
      latestCameraFrameMetadata: state.latestCameraFrameMetadata,
      mutationAudit: state.mutationAudit,
      lastUserMessage: state.lastUserMessage,
    });
  }

  private fromDoc(
    sessionId: string,
    data: Record<string, unknown>,
    nowMs: number,
  ): PersistedSessionState {
    const createdAt = coerceTimestamp(data.createdAt) ?? iso(nowMs);
    const updatedAt = coerceTimestamp(data.updatedAt) ?? createdAt;
    const expireAt = coerceTimestamp(data.expireAt);
    return {
      sessionId,
      createdAt,
      updatedAt,
      ...(expireAt !== undefined ? { expireAt } : {}),
      selectedRecipe: data.selectedRecipe as StoredRecipeContext | undefined,
      confirmedIngredients:
        (data.confirmedIngredients as StoredIngredientContext[] | undefined) ??
        [],
      latestConfidence: data.latestConfidence as
        | ConfidenceAssessResponse
        | undefined,
      // Legacy persisted `latestCameraFrame` (raw frame bytes) is deliberately
      // ignored: never read, never returned, never rehydrated.
      latestCameraFrameMetadata: data.latestCameraFrameMetadata as
        | StoredCameraFrameMetadata
        | undefined,
      mutationAudit:
        (data.mutationAudit as InventoryMutationAuditEntry[] | undefined) ?? [],
      lastUserMessage: data.lastUserMessage as string | undefined,
    };
  }
}

function coerceTimestamp(value: unknown): string | undefined {
  if (typeof value === "string") return value;
  if (value instanceof Timestamp) return value.toDate().toISOString();
  return undefined;
}
