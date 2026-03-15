import { FieldValue, Firestore, Timestamp } from "@google-cloud/firestore";
import type { AppConfig, SessionStoreMode } from "../config.js";
import type { ConfidenceAssessResponse } from "../types/contracts.js";

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
  updatedAt: string;
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
  selectedRecipe?: StoredRecipeContext;
  confirmedIngredients: StoredIngredientContext[];
  latestConfidence?: ConfidenceAssessResponse;
  latestCameraFrame?: StoredCameraFrame;
  mutationAudit: InventoryMutationAuditEntry[];
  lastUserMessage?: string;
}

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

function createBlankSession(sessionId: string): LiveSessionState {
  const now = new Date().toISOString();
  return {
    sessionId,
    createdAt: now,
    updatedAt: now,
    confirmedIngredients: [],
    mutationAudit: [],
  };
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

  async ensureSession(sessionId: string): Promise<LiveSessionState> {
    const existing = this.sessions.get(sessionId);
    if (existing) return { ...existing };
    const created = createBlankSession(sessionId);
    this.sessions.set(sessionId, created);
    return { ...created };
  }

  async getSession(sessionId: string): Promise<LiveSessionState> {
    return this.ensureSession(sessionId);
  }

  async patchContext(
    sessionId: string,
    patch: LiveSessionContextPatch,
  ): Promise<LiveSessionState> {
    const existing = await this.ensureSession(sessionId);
    const next: LiveSessionState = {
      ...existing,
      ...patch,
      confirmedIngredients:
        patch.confirmedIngredients ?? existing.confirmedIngredients,
      updatedAt: new Date().toISOString(),
    };
    this.sessions.set(sessionId, next);
    return { ...next };
  }

  async recordLatestFrame(
    sessionId: string,
    frame: StoredCameraFrame,
  ): Promise<LiveSessionState> {
    const existing = await this.ensureSession(sessionId);
    const next = {
      ...existing,
      latestCameraFrame: frame,
      updatedAt: new Date().toISOString(),
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

  async appendMutationAudit(
    sessionId: string,
    entry: InventoryMutationAuditEntry,
  ): Promise<LiveSessionState> {
    const existing = await this.ensureSession(sessionId);
    const next = {
      ...existing,
      mutationAudit: [...existing.mutationAudit, entry].slice(-30),
      updatedAt: new Date().toISOString(),
    };
    this.sessions.set(sessionId, next);
    return { ...next };
  }

  async recordUserMessage(
    sessionId: string,
    text: string,
  ): Promise<LiveSessionState> {
    const existing = await this.ensureSession(sessionId);
    const next = {
      ...existing,
      lastUserMessage: text,
      updatedAt: new Date().toISOString(),
    };
    this.sessions.set(sessionId, next);
    return { ...next };
  }
}

class FirestoreLiveSessionStore implements LiveSessionStore {
  readonly mode: SessionStoreMode = "firestore";
  private readonly firestore = new Firestore();
  private readonly collectionName: string;

  constructor(collectionName: string) {
    this.collectionName = collectionName;
  }

  async ensureSession(sessionId: string): Promise<LiveSessionState> {
    const ref = this.doc(sessionId);
    const snap = await ref.get();
    if (snap.exists) {
      return this.fromDoc(sessionId, snap.data() ?? {});
    }

    const created = createBlankSession(sessionId);
    await ref.set({
      ...created,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    return created;
  }

  async getSession(sessionId: string): Promise<LiveSessionState> {
    return this.ensureSession(sessionId);
  }

  async patchContext(
    sessionId: string,
    patch: LiveSessionContextPatch,
  ): Promise<LiveSessionState> {
    const ref = this.doc(sessionId);
    await this.ensureSession(sessionId);
    await ref.set(
      {
        ...patch,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    return this.getSession(sessionId);
  }

  async recordLatestFrame(
    sessionId: string,
    frame: StoredCameraFrame,
  ): Promise<LiveSessionState> {
    const ref = this.doc(sessionId);
    await this.ensureSession(sessionId);
    await ref.set(
      {
        latestCameraFrame: frame,
        updatedAt: FieldValue.serverTimestamp(),
      },
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
    const current = await this.ensureSession(sessionId);
    await this.doc(sessionId).set(
      {
        mutationAudit: [...current.mutationAudit, entry].slice(-30),
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    return this.getSession(sessionId);
  }

  async recordUserMessage(
    sessionId: string,
    text: string,
  ): Promise<LiveSessionState> {
    await this.ensureSession(sessionId);
    await this.doc(sessionId).set(
      {
        lastUserMessage: text,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    return this.getSession(sessionId);
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

    return {
      sessionId,
      createdAt,
      updatedAt,
      selectedRecipe: data.selectedRecipe as StoredRecipeContext | undefined,
      confirmedIngredients:
        (data.confirmedIngredients as StoredIngredientContext[] | undefined) ??
        [],
      latestConfidence: data.latestConfidence as
        | ConfidenceAssessResponse
        | undefined,
      latestCameraFrame: data.latestCameraFrame as
        | StoredCameraFrame
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
