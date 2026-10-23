import { FieldValue, Firestore, Timestamp } from "@google-cloud/firestore";
import type { AppConfig, SessionStoreMode } from "../config.js";
import type { ConfidenceAssessResponse } from "../types/contracts.js";

/**
 * Live session store — SPEC §9 (adopting PR #26's design and constants).
 *
 * Privacy contract: NOTHING about a cook outlives the cook.
 * - Raw camera frames NEVER reach this store. Only frame metadata persists
 *   (StoredCameraFrameMetadata); the bytes live in the gateway's in-process
 *   frame cache and die with it.
 * - No transcript is kept: there is no lastUserMessage and no mutation-audit
 *   tail — the server-memory tools that wrote them are gone.
 * - Every session carries `expireAt` = last activity + SESSION_TTL_MS,
 *   refreshed on every write. Reads enforce expiry (an expired record reads
 *   as blank), ensureSession cannot renew or restore an expired record, and
 *   the gateway deletes the session on close. The Firestore TTL policy on
 *   `expireAt` is owner-run and is NOT the access-control boundary — expiry
 *   enforcement in reads is.
 * - Legacy session docs that still hold `latestCameraFrame` bytes: the field
 *   is ignored on read and deleted on the next merge write.
 */

/** Session TTL: 24 h after last activity (SPEC §9.5, PR #26's constant). */
export const SESSION_TTL_MS = 24 * 60 * 60 * 1000;
/** Close tombstones remain for 7 days, covering late cross-instance writes. */
export const SESSION_TOMBSTONE_TTL_MS = 7 * 24 * 60 * 60 * 1000;

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

/**
 * Frame METADATA only — the frame's bytes never persist (SPEC §9.1).
 * `receivedAt` is the trusted server receipt time; client timestamps cannot
 * extend retention.
 */
export interface StoredCameraFrameMetadata {
  mimeType: string;
  receivedAt: string;
  sizeBytes: number;
}

export interface LiveSessionState {
  sessionId: string;
  createdAt: string;
  updatedAt: string;
  /** Absolute expiry: last activity + SESSION_TTL_MS, refreshed on every write. */
  expireAt: string;
  selectedRecipe?: StoredRecipeContext;
  confirmedIngredients: StoredIngredientContext[];
  latestConfidence?: ConfidenceAssessResponse;
  cameraFrameMetadata?: StoredCameraFrameMetadata;
}

export interface LiveSessionContextPatch {
  selectedRecipe?: StoredRecipeContext;
  confirmedIngredients?: StoredIngredientContext[];
  latestConfidence?: ConfidenceAssessResponse;
}

export interface LiveSessionStore {
  readonly mode: SessionStoreMode;
  ensureSession(sessionId: string): Promise<LiveSessionState>;
  /**
   * Read WITHOUT creating. An expired or missing session reads as blank
   * (SPEC §9.5); an expired record is deleted, never renewed or restored.
   */
  getSession(sessionId: string): Promise<LiveSessionState>;
  patchContext(
    sessionId: string,
    patch: LiveSessionContextPatch,
  ): Promise<LiveSessionState>;
  recordFrameMetadata(
    sessionId: string,
    metadata: StoredCameraFrameMetadata,
  ): Promise<LiveSessionState>;
  recordLatestConfidence(
    sessionId: string,
    assessment: ConfidenceAssessResponse,
  ): Promise<LiveSessionState>;
  /** Session end: the gateway deletes the session on close (SPEC §9.5). */
  deleteSession(sessionId: string): Promise<void>;
  /** Delete every session whose expireAt has passed; returns the count. */
  sweepExpired(nowMs?: number): Promise<number>;
}

function nowIso(): string {
  return new Date().toISOString();
}

function newExpiryIso(): string {
  return new Date(Date.now() + SESSION_TTL_MS).toISOString();
}

function createBlankSession(sessionId: string): LiveSessionState {
  const now = nowIso();
  return {
    sessionId,
    createdAt: now,
    updatedAt: now,
    expireAt: newExpiryIso(),
    confirmedIngredients: [],
  };
}

function isExpired(state: LiveSessionState, nowMs = Date.now()): boolean {
  return Date.parse(state.expireAt) <= nowMs;
}

/** A blank reading for an expired or absent session — never persisted. */
function blankReading(sessionId: string): LiveSessionState {
  return { sessionId, createdAt: "", updatedAt: "", expireAt: new Date(0).toISOString(), confirmedIngredients: [] };
}

export function createLiveSessionStore(
  config: Pick<
    AppConfig,
    | "sessionStoreMode"
    | "projectId"
    | "firestoreCollection"
    | "firestoreEmulator"
  >,
): LiveSessionStore {
  const mode =
    config.sessionStoreMode === "auto"
      ? config.projectId || config.firestoreEmulator
        ? "firestore"
        : "memory"
      : config.sessionStoreMode;

  if (mode === "firestore") {
    return new FirestoreLiveSessionStore(config.firestoreCollection);
  }

  return new MemoryLiveSessionStore();
}

class MemoryLiveSessionStore implements LiveSessionStore {
  readonly mode: SessionStoreMode = "memory";
  private readonly sessions = new Map<string, LiveSessionState>();
  private readonly closedSessions = new Set<string>();

  async ensureSession(sessionId: string): Promise<LiveSessionState> {
    if (this.closedSessions.has(sessionId)) return blankReading(sessionId);
    const existing = this.sessions.get(sessionId);
    if (existing && !isExpired(existing)) return { ...existing };
    // An expired record cannot be renewed or restored (SPEC §9.5): it is
    // deleted and the session starts blank.
    if (existing) this.sessions.delete(sessionId);
    const created = createBlankSession(sessionId);
    this.sessions.set(sessionId, created);
    return { ...created };
  }

  async getSession(sessionId: string): Promise<LiveSessionState> {
    const existing = this.sessions.get(sessionId);
    if (!existing) return blankReading(sessionId);
    if (isExpired(existing)) {
      this.sessions.delete(sessionId);
      return blankReading(sessionId);
    }
    return { ...existing };
  }

  async patchContext(
    sessionId: string,
    patch: LiveSessionContextPatch,
  ): Promise<LiveSessionState> {
    const existing = await this.ensureSession(sessionId);
    if (!existing.createdAt) return existing;
    const next: LiveSessionState = {
      ...existing,
      ...patch,
      confirmedIngredients:
        patch.confirmedIngredients ?? existing.confirmedIngredients,
      updatedAt: nowIso(),
      expireAt: newExpiryIso(),
    };
    this.sessions.set(sessionId, next);
    return { ...next };
  }

  async recordFrameMetadata(
    sessionId: string,
    metadata: StoredCameraFrameMetadata,
  ): Promise<LiveSessionState> {
    const existing = this.sessions.get(sessionId);
    if (!existing || isExpired(existing)) return blankReading(sessionId);
    const next: LiveSessionState = {
      ...existing,
      cameraFrameMetadata: metadata,
      updatedAt: nowIso(),
      expireAt: newExpiryIso(),
    };
    this.sessions.set(sessionId, next);
    return { ...next };
  }

  async recordLatestConfidence(
    sessionId: string,
    assessment: ConfidenceAssessResponse,
  ): Promise<LiveSessionState> {
    return this.patchContext(sessionId, { latestConfidence: assessment });
  }

  async deleteSession(sessionId: string): Promise<void> {
    this.sessions.delete(sessionId);
    this.closedSessions.add(sessionId);
  }

  async sweepExpired(nowMs = Date.now()): Promise<number> {
    let deleted = 0;
    for (const [id, state] of this.sessions) {
      if (isExpired(state, nowMs)) {
        this.sessions.delete(id);
        deleted++;
      }
    }
    return deleted;
  }
}

export class SessionOperationLock {
  private readonly chains = new Map<string, Promise<void>>();

  async run<T>(sessionId: string, operation: () => Promise<T>): Promise<T> {
    const previous = this.chains.get(sessionId) ?? Promise.resolve();
    let release!: () => void;
    const next = new Promise<void>((resolve) => { release = resolve; });
    const queued = previous.then(() => next);
    this.chains.set(sessionId, queued);
    await previous;
    try {
      return await operation();
    } finally {
      release();
      void queued.then(() => {
        if (this.chains.get(sessionId) === queued) this.chains.delete(sessionId);
      });
    }
  }
}

class FirestoreLiveSessionStore implements LiveSessionStore {
  readonly mode: SessionStoreMode = "firestore";
  private readonly firestore = new Firestore();
  private readonly collectionName: string;
  private readonly closedSessions = new Set<string>();
  private readonly operationLock = new SessionOperationLock();

  constructor(collectionName: string) {
    this.collectionName = collectionName;
  }

  async ensureSession(sessionId: string): Promise<LiveSessionState> {
    return this.operationLock.run(sessionId, () => this.ensureSessionUnlocked(sessionId));
  }

  private async ensureSessionUnlocked(sessionId: string): Promise<LiveSessionState> {
    if (this.closedSessions.has(sessionId)) return blankReading(sessionId);
    const ref = this.doc(sessionId);
    return this.firestore.runTransaction(async (transaction) => {
      const snap = await transaction.get(ref);
      if (snap.exists) {
        const data = snap.data() ?? {};
        if (this.hasLiveTombstone(data)) return blankReading(sessionId);
        if (data.deletedAt) {
          const created = createBlankSession(sessionId);
          transaction.set(ref, this.createEnvelope(created));
          return created;
        }
        const state = this.fromDoc(sessionId, data);
        if (!isExpired(state)) return state;
        transaction.set(ref, this.tombstoneEnvelope());
        return blankReading(sessionId);
      }
      const created = createBlankSession(sessionId);
      if (this.closedSessions.has(sessionId)) return blankReading(sessionId);
      transaction.create(ref, this.createEnvelope(created));
      return created;
    });
  }

  async getSession(sessionId: string): Promise<LiveSessionState> {
    const ref = this.doc(sessionId);
    return this.firestore.runTransaction(async (transaction) => {
      const snap = await transaction.get(ref);
      if (!snap.exists) return blankReading(sessionId);
      const data = snap.data() ?? {};
      if (this.hasLiveTombstone(data)) return blankReading(sessionId);
      const state = this.fromDoc(sessionId, data);
      if (isExpired(state)) {
        transaction.set(ref, this.tombstoneEnvelope());
        return blankReading(sessionId);
      }
      return state;
    });
  }

  async patchContext(
    sessionId: string,
    patch: LiveSessionContextPatch,
  ): Promise<LiveSessionState> {
    return this.operationLock.run(sessionId, () => this.writeLiveSession(sessionId, patch));
  }

  async recordFrameMetadata(
    sessionId: string,
    metadata: StoredCameraFrameMetadata,
  ): Promise<LiveSessionState> {
    return this.operationLock.run(sessionId, () =>
      this.writeLiveSession(sessionId, { cameraFrameMetadata: metadata }),
    );
  }

  async recordLatestConfidence(
    sessionId: string,
    assessment: ConfidenceAssessResponse,
  ): Promise<LiveSessionState> {
    return this.patchContext(sessionId, { latestConfidence: assessment });
  }

  async deleteSession(sessionId: string): Promise<void> {
    await this.operationLock.run(sessionId, async () => {
      this.closedSessions.add(sessionId);
      await this.doc(sessionId).set(this.tombstoneEnvelope());
    });
  }

  private async writeLiveSession(sessionId: string, fields: object): Promise<LiveSessionState> {
    const ref = this.doc(sessionId);
    return this.firestore.runTransaction(async (transaction) => {
      const snap = await transaction.get(ref);
      if (!snap.exists || this.hasLiveTombstone(snap.data() ?? {})) return blankReading(sessionId);
      const state = this.fromDoc(sessionId, snap.data() ?? {});
      if (isExpired(state)) {
        transaction.set(ref, this.tombstoneEnvelope());
        return blankReading(sessionId);
      }
      transaction.set(ref, this.writeEnvelope({ ...fields, createdAt: state.createdAt }), { merge: true });
      return {
        ...state,
        ...fields,
        updatedAt: new Date().toISOString(),
        expireAt: new Date(Date.now() + SESSION_TTL_MS).toISOString(),
      };
    });
  }

  async sweepExpired(nowMs = Date.now()): Promise<number> {
    const cutoff = new Date(nowMs);
    const stale = await this.firestore
      .collection(this.collectionName)
      .where("expireAt", "<=", cutoff)
      .get();
    let deleted = 0;
    for (const doc of stale.docs) {
      await doc.ref.delete();
      deleted++;
    }
    return deleted;
  }

  private tombstoneEnvelope() {
    return {
      deletedAt: FieldValue.serverTimestamp(),
      tombstoneExpiresAt: new Date(Date.now() + SESSION_TOMBSTONE_TTL_MS),
    };
  }

  private hasLiveTombstone(data: Record<string, unknown>): boolean {
    const expiresAt = coerceTimestamp(data.tombstoneExpiresAt);
    return Boolean(data.deletedAt) && (!expiresAt || Date.parse(expiresAt) > Date.now());
  }

  private createEnvelope(state: LiveSessionState) {
    return {
      ...state,
      expireAt: new Date(Date.now() + SESSION_TTL_MS),
      updatedAt: FieldValue.serverTimestamp(),
    };
  }

  /**
   * Every write carries the refreshed expireAt AND deletes any legacy
   * `latestCameraFrame` bytes the doc may still hold (SPEC §9.1, §9.4).
   */
  private writeEnvelope(fields: object) {
    return {
      ...fields,
      expireAt: new Date(Date.now() + SESSION_TTL_MS),
      updatedAt: FieldValue.serverTimestamp(),
      latestCameraFrame: FieldValue.delete(),
    };
  }

  private doc(sessionId: string) {
    return this.firestore.collection(this.collectionName).doc(sessionId);
  }

  private fromDoc(
    sessionId: string,
    data: Record<string, unknown>,
  ): LiveSessionState {
    const createdAt =
      coerceTimestamp(data.createdAt) ?? new Date().toISOString();
    const updatedAt = coerceTimestamp(data.updatedAt) ?? createdAt;
    const expireAt = coerceTimestamp(data.expireAt) ?? new Date(0).toISOString();

    return {
      sessionId,
      createdAt,
      updatedAt,
      expireAt,
      selectedRecipe: data.selectedRecipe as StoredRecipeContext | undefined,
      confirmedIngredients:
        (data.confirmedIngredients as StoredIngredientContext[] | undefined) ??
        [],
      latestConfidence: data.latestConfidence as
        | ConfidenceAssessResponse
        | undefined,
      cameraFrameMetadata: data.cameraFrameMetadata as
        | StoredCameraFrameMetadata
        | undefined,
      // Legacy `latestCameraFrame` bytes in old docs are IGNORED on read
      // (SPEC §9.4) and deleted by the next merge write.
    };
  }
}

function coerceTimestamp(value: unknown): string | undefined {
  if (typeof value === "string") return value;
  if (value instanceof Timestamp) return value.toDate().toISOString();
  if (value instanceof Date) return value.toISOString();
  return undefined;
}
