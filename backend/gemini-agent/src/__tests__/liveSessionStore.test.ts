import { describe, it, expect } from "bun:test";
import { FieldValue, Timestamp } from "@google-cloud/firestore";
import type { GoogleGenAI } from "@google/genai";
import type { AppConfig, SessionStoreMode } from "../config.js";
import { InventoryLedger } from "../inventory/inventoryLedger.js";
import { ConfidenceService } from "../services/confidenceService.js";
import {
  createLiveSessionStore,
  TransientFrameCache,
  FRAME_TTL_MS,
  FRAME_CACHE_MAX_SESSIONS,
  SESSION_TTL_MS,
} from "../session/liveSessionStore.js";
import type {
  LiveSessionFirestoreDocRefLike,
  LiveSessionFirestoreLike,
  LiveSessionStore,
  LiveSessionStoreOptions,
  StoredCameraFrame,
} from "../session/liveSessionStore.js";
import {
  buildToolRegistry,
  dispatchToolCall,
} from "../agent/toolRegistry.js";
import type { ToolDeps } from "../agent/toolRegistry.js";

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const BASE_MS = Date.parse("2026-01-15T10:00:00.000Z");

/** Marker payload for freshly recorded frames — must never reach persistence. */
const FRAME_PAYLOAD = "ZmFrZS1qcGVnLXNlY3JldC1mcmFtZS1kYXRhLW1hcmtlcg==";
/** Marker payload for seeded legacy documents. */
const LEGACY_PAYLOAD = "TEVHQUNZLVBIT1RPLUJZVEVTLU1BUktFUi0wNzE1";

const CLIENT_FUTURE_ISO = "2077-01-01T00:00:00.000Z";

function iso(ms: number): string {
  return new Date(ms).toISOString();
}

function makeClock(startMs: number = BASE_MS) {
  let current = startMs;
  return {
    now: () => current,
    advance: (ms: number) => {
      current += ms;
    },
  };
}

const DELETE_SENTINEL = FieldValue.delete();

function isDeleteSentinel(value: unknown): boolean {
  if (value === DELETE_SENTINEL) return true;
  if (!(value instanceof FieldValue)) return false;
  const maybe = value as { isEqual?: (other: unknown) => boolean };
  return typeof maybe.isEqual === "function" && maybe.isEqual(DELETE_SENTINEL);
}

/**
 * Fake Firestore honoring the merge/delete semantics the store relies on:
 * merge:true updates overlay existing fields, FieldValue.delete() removes a
 * field entirely, and non-merge set replaces the whole document.
 */
class FakeFirestore implements LiveSessionFirestoreLike {
  readonly docs = new Map<string, Record<string, unknown>>();
  readonly writes: Array<{
    id: string;
    merge: boolean;
    data: Record<string, unknown>;
  }> = [];

  collection(_name: string): {
    doc(id: string): LiveSessionFirestoreDocRefLike;
  } {
    return { doc: (id: string) => this.ref(id) };
  }

  seed(id: string, data: Record<string, unknown>): void {
    this.docs.set(id, data);
  }

  doc(id: string): Record<string, unknown> {
    const data = this.docs.get(id);
    if (data === undefined) throw new Error(`FakeFirestore: missing doc '${id}'`);
    return data;
  }

  tryDoc(id: string): Record<string, unknown> | undefined {
    return this.docs.get(id);
  }

  private ref(id: string): LiveSessionFirestoreDocRefLike {
    const self = this;
    return {
      async get() {
        const data = self.docs.get(id);
        return { exists: data !== undefined, data: () => data ?? {} };
      },
      async set(data, options) {
        const merge = options?.merge === true;
        self.writes.push({ id, merge, data: { ...data } });
        const next: Record<string, unknown> = merge
          ? { ...(self.docs.get(id) ?? {}) }
          : {};
        for (const [key, value] of Object.entries(data)) {
          if (isDeleteSentinel(value)) delete next[key];
          else next[key] = value;
        }
        self.docs.set(id, next);
      },
    };
  }
}

type StoreMode = "memory" | "firestore";

interface Harness {
  store: LiveSessionStore;
  clock: ReturnType<typeof makeClock>;
  fake: FakeFirestore;
}

function makeHarness(
  mode: StoreMode,
  overrides: Partial<LiveSessionStoreOptions> = {},
): Harness {
  const clock = makeClock();
  const fake = new FakeFirestore();
  const options: LiveSessionStoreOptions = {
    now: clock.now,
    firestore: fake,
    ...overrides,
  };
  const store = createLiveSessionStore(
    {
      sessionStoreMode: mode as SessionStoreMode,
      projectId: mode === "firestore" ? "test-project" : undefined,
      firestoreCollection: "liveSessions",
      firestoreEmulator: undefined,
    },
    options,
  );
  return { store, clock, fake };
}

function seedLiveLegacyDoc(fake: FakeFirestore, id: string): void {
  fake.seed(id, {
    sessionId: id,
    createdAt: Timestamp.fromMillis(BASE_MS - 3_600_000),
    updatedAt: Timestamp.fromMillis(BASE_MS - 3_600_000),
    selectedRecipe: { title: "Old Soup", ingredients: [] },
    confirmedIngredients: [{ name: "onion" }],
    lastUserMessage: "old message",
    // Legacy raw frame bytes persisted by the previous store version.
    latestCameraFrame: {
      mimeType: "image/jpeg",
      dataBase64: LEGACY_PAYLOAD,
      updatedAt: iso(BASE_MS - 3_600_000),
    },
  });
}

function seedExpiredLegacyDoc(fake: FakeFirestore, id: string): void {
  fake.seed(id, {
    sessionId: id,
    // 25h old, no expireAt field: exercises the updatedAt+TTL fallback.
    createdAt: Timestamp.fromMillis(BASE_MS - 25 * 3_600_000),
    updatedAt: Timestamp.fromMillis(BASE_MS - 25 * 3_600_000),
    selectedRecipe: { title: "Ancient Soup", ingredients: [] },
    lastUserMessage: "ancient message",
    latestCameraFrame: {
      mimeType: "image/jpeg",
      dataBase64: LEGACY_PAYLOAD,
      updatedAt: iso(BASE_MS - 25 * 3_600_000),
    },
  });
}

// Shared suite: behavior that must hold for BOTH store implementations.
function forBothStores(
  name: string,
  run: (h: Harness) => Promise<void> | void,
  overrides: Partial<LiveSessionStoreOptions> = {},
): void {
  for (const mode of ["memory", "firestore"] as const) {
    it(`${name} [${mode}]`, async () => {
      const h = makeHarness(mode, overrides);
      await run(h);
    });
  }
}

// ---------------------------------------------------------------------------
// Transient frames: bytes stay in-process, metadata is persisted
// ---------------------------------------------------------------------------

describe("live session store — transient frame handling", () => {
  forBothStores("rehydrates a current transient frame with metadata", async (h) => {
    await h.store.ensureSession("s1");
    const state = await h.store.recordLatestFrame("s1", {
      mimeType: "image/jpeg",
      dataBase64: FRAME_PAYLOAD,
      updatedAt: CLIENT_FUTURE_ISO,
    });

    expect(state.latestCameraFrame?.dataBase64).toBe(FRAME_PAYLOAD);
    expect(state.latestCameraFrame?.mimeType).toBe("image/jpeg");
    expect(state.latestCameraFrameMetadata?.mimeType).toBe("image/jpeg");
    // Receipt time is the trusted server clock, not the client timestamp.
    expect(state.latestCameraFrameMetadata?.receivedAt).toBe(iso(BASE_MS));
  });

  forBothStores(
    "expires the transient frame two minutes after trusted server receipt; client timestamps cannot extend retention",
    async (h) => {
      await h.store.ensureSession("s1");
      // Client-controlled updatedAt far in the future must be irrelevant.
      await h.store.recordLatestFrame("s1", {
        mimeType: "image/jpeg",
        dataBase64: FRAME_PAYLOAD,
        updatedAt: CLIENT_FUTURE_ISO,
      });

      h.clock.advance(FRAME_TTL_MS - 1);
      let state = await h.store.getSession("s1");
      expect(state.latestCameraFrame?.dataBase64).toBe(FRAME_PAYLOAD);

      h.clock.advance(1); // exactly at the TTL boundary → expired
      state = await h.store.getSession("s1");
      expect(state.latestCameraFrame).toBeUndefined();
      // Metadata survives; only the bytes are transient.
      expect(state.latestCameraFrameMetadata?.mimeType).toBe("image/jpeg");
      expect(state.latestCameraFrameMetadata?.receivedAt).toBe(iso(BASE_MS));
    },
  );

  it("persists frame metadata only — no frame bytes reach Firestore [firestore]", async () => {
    const h = makeHarness("firestore");
    await h.store.ensureSession("s1");
    await h.store.recordLatestFrame("s1", {
      mimeType: "image/jpeg",
      dataBase64: FRAME_PAYLOAD,
      updatedAt: CLIENT_FUTURE_ISO,
    });

    const doc = h.fake.doc("s1");
    expect(doc.latestCameraFrame).toBeUndefined();
    expect(JSON.stringify(doc)).not.toContain(FRAME_PAYLOAD);
    expect(JSON.stringify(doc)).not.toContain("dataBase64");

    const metadata = doc.latestCameraFrameMetadata as Record<string, unknown>;
    expect(metadata.mimeType).toBe("image/jpeg");
    expect(metadata.receivedAt).toBe(iso(BASE_MS));
    expect(metadata.sizeBytes).toBe(FRAME_PAYLOAD.length);
  });
});

// ---------------------------------------------------------------------------
// Logical session expiry
// ---------------------------------------------------------------------------

describe("live session store — logical session expiry", () => {
  forBothStores(
    "expires sessions 24h after activity and never resurrects stale state",
    async (h) => {
      await h.store.ensureSession("s1");
      await h.store.patchContext("s1", {
        selectedRecipe: { title: "Soup", ingredients: [] },
      });
      await h.store.recordUserMessage("s1", "make soup");

      h.clock.advance(SESSION_TTL_MS - 1);
      let state = await h.store.getSession("s1");
      expect(state.lastUserMessage).toBe("make soup");
      expect(state.selectedRecipe?.title).toBe("Soup");

      h.clock.advance(1);
      state = await h.store.getSession("s1");
      expect(state.lastUserMessage).toBeUndefined();
      expect(state.selectedRecipe).toBeUndefined();
      expect(state.confirmedIngredients).toEqual([]);
      expect(state.mutationAudit).toEqual([]);

      // ensureSession must not renew or restore the expired record.
      state = await h.store.ensureSession("s1");
      expect(state.lastUserMessage).toBeUndefined();
      expect(state.selectedRecipe).toBeUndefined();

      // Activity after expiry starts a fresh session lifecycle.
      state = await h.store.recordUserMessage("s1", "fresh");
      expect(state.lastUserMessage).toBe("fresh");
      expect(state.createdAt).toBe(iso(BASE_MS + SESSION_TTL_MS));

      // A frame recorded after expiry belongs to the fresh session only.
      state = await h.store.recordLatestFrame("s1", {
        mimeType: "image/jpeg",
        dataBase64: FRAME_PAYLOAD,
        updatedAt: CLIENT_FUTURE_ISO,
      });
      expect(state.latestCameraFrame?.dataBase64).toBe(FRAME_PAYLOAD);
    },
    { sessionTtlMs: SESSION_TTL_MS },
  );

  forBothStores(
    "honors a custom logical session TTL",
    async (h) => {
      await h.store.recordUserMessage("s1", "hello");
      h.clock.advance(4_000);
      expect((await h.store.getSession("s1")).lastUserMessage).toBe("hello");
      h.clock.advance(1_000); // custom TTL of 5s reached
      expect((await h.store.getSession("s1")).lastUserMessage).toBeUndefined();
    },
    { sessionTtlMs: 5_000 },
  );

  forBothStores(
    "refreshes expireAt on every write",
    async (h) => {
      await h.store.ensureSession("s1");
      expect(
        (await h.store.getSession("s1")).expireAt,
      ).toBe(iso(BASE_MS + SESSION_TTL_MS));

      h.clock.advance(60_000);
      await h.store.recordUserMessage("s1", "later");
      expect(
        (await h.store.getSession("s1")).expireAt,
      ).toBe(iso(BASE_MS + 60_000 + SESSION_TTL_MS));
    },
    { sessionTtlMs: SESSION_TTL_MS },
  );

  it("writes expireAt as a Firestore Timestamp for TTL policies [firestore]", async () => {
    const h = makeHarness("firestore");
    await h.store.recordUserMessage("s1", "hello");

    const expireAt = h.fake.doc("s1").expireAt;
    expect(expireAt).toBeInstanceOf(Timestamp);
    expect((expireAt as Timestamp).toMillis()).toBe(BASE_MS + SESSION_TTL_MS);

    h.clock.advance(60_000);
    await h.store.recordUserMessage("s1", "later");
    expect(
      (h.fake.doc("s1").expireAt as Timestamp).toMillis(),
    ).toBe(BASE_MS + 60_000 + SESSION_TTL_MS);
  });
});

// ---------------------------------------------------------------------------
// Expiry enforcement + legacy data handling (Firestore mode)
// ---------------------------------------------------------------------------

describe("live session store — legacy persisted frames [firestore]", () => {
  it("ignores legacy frame bytes on reads of a live document", async () => {
    const h = makeHarness("firestore");
    seedLiveLegacyDoc(h.fake, "s1");

    const state = await h.store.getSession("s1");
    // Live, non-frame state is still readable...
    expect(state.selectedRecipe?.title).toBe("Old Soup");
    expect(state.lastUserMessage).toBe("old message");
    // ...but the persisted legacy frame is never returned.
    expect(state.latestCameraFrame).toBeUndefined();
    expect(JSON.stringify(state)).not.toContain(LEGACY_PAYLOAD);
  });

  it("leaves untouched documents (and their photos) alone; reads do not modify them", async () => {
    const h = makeHarness("firestore");
    seedLiveLegacyDoc(h.fake, "live-legacy");
    seedExpiredLegacyDoc(h.fake, "expired-legacy");
    const writesBefore = h.fake.writes.length;

    await h.store.getSession("live-legacy");
    await h.store.getSession("expired-legacy");

    // Reads enforce expiry without touching records: no writes at all, and the
    // legacy photo bytes remain in the untouched documents. Historical
    // remediation is out of scope for this change.
    expect(h.fake.writes.length).toBe(writesBefore);
    expect(h.fake.doc("live-legacy").latestCameraFrame).toBeDefined();
    expect(JSON.stringify(h.fake.doc("expired-legacy"))).toContain(LEGACY_PAYLOAD);
  });

  it("returns blank state for expired documents and resets them in place on ensureSession", async () => {
    const h = makeHarness("firestore");
    seedExpiredLegacyDoc(h.fake, "s1");

    // Read: expiry enforced, stale state never resurrected.
    const state = await h.store.getSession("s1");
    expect(state.lastUserMessage).toBeUndefined();
    expect(state.selectedRecipe).toBeUndefined();
    expect(state.latestCameraFrame).toBeUndefined();

    // ensureSession: cannot renew or restore — resets to a fresh session,
    // which drops the legacy frame field from the touched document.
    const ensured = await h.store.ensureSession("s1");
    expect(ensured.lastUserMessage).toBeUndefined();
    expect(ensured.selectedRecipe).toBeUndefined();
    expect(ensured.createdAt).toBe(iso(BASE_MS));

    const doc = h.fake.doc("s1");
    expect(doc.latestCameraFrame).toBeUndefined();
    expect(JSON.stringify(doc)).not.toContain(LEGACY_PAYLOAD);
    expect(doc.selectedRecipe).toBeUndefined();
    expect(doc.lastUserMessage).toBeUndefined();
  });

  it("deletes the legacy frame field with FieldValue.delete semantics on every merge write", async () => {
    const entry = {
      operation: "add",
      idempotencyKey: "k1",
      itemCount: 1,
      committed: true,
      createdAt: iso(BASE_MS),
    };

    const writePaths: Array<(store: LiveSessionStore) => Promise<unknown>> = [
      (store) => store.recordUserMessage("s1", "msg"),
      (store) =>
        store.patchContext("s1", {
          confirmedIngredients: [{ name: "garlic" }],
        }),
      (store) => store.appendMutationAudit("s1", entry),
      (store) =>
        store.recordLatestConfidence("s1", {
          mode: "estimate_only",
          overallScore: 0.4,
          deterministicReady: false,
          reasons: [],
          signals: [],
        }),
      (store) =>
        store.recordLatestFrame("s1", {
          mimeType: "image/png",
          dataBase64: FRAME_PAYLOAD,
          updatedAt: CLIENT_FUTURE_ISO,
        }),
    ];

    for (const write of writePaths) {
      const h = makeHarness("firestore");
      seedLiveLegacyDoc(h.fake, "s1");
      const writesBefore = h.fake.writes.length;

      await write(h.store);

      const doc = h.fake.doc("s1");
      expect(doc.latestCameraFrame).toBeUndefined();
      expect(JSON.stringify(doc)).not.toContain(LEGACY_PAYLOAD);
      // Actual field-deletion semantics: the merge write carried the
      // FieldValue.delete() sentinel rather than merely omitting the key.
      const lastWrite = h.fake.writes[h.fake.writes.length - 1]!;
      expect(lastWrite.merge).toBe(true);
      expect(isDeleteSentinel(lastWrite.data.latestCameraFrame)).toBe(true);
      expect(h.fake.writes.length).toBeGreaterThan(writesBefore);
    }
  });

  it("does not write anything for getSession on a missing session", async () => {
    const h = makeHarness("firestore");
    const state = await h.store.getSession("missing");
    expect(state.sessionId).toBe("missing");
    expect(state.confirmedIngredients).toEqual([]);
    expect(h.fake.tryDoc("missing")).toBeUndefined();
    expect(h.fake.writes.length).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// Frame cache bounds and eviction
// ---------------------------------------------------------------------------

describe("live session store — frame cache bounds", () => {
  forBothStores(
    "evicts least-recently-used sessions beyond the cache bound",
    async (h) => {
      const frame = (id: string): StoredCameraFrame => ({
        mimeType: "image/jpeg",
        dataBase64: `${FRAME_PAYLOAD}-${id}`,
        updatedAt: CLIENT_FUTURE_ISO,
      });

      await h.store.recordLatestFrame("s1", frame("s1"));
      await h.store.recordLatestFrame("s2", frame("s2"));
      await h.store.recordLatestFrame("s3", frame("s3"));

      expect(
        (await h.store.getSession("s1")).latestCameraFrame?.dataBase64,
      ).toBe(`${FRAME_PAYLOAD}-s1`);

      // Reading s1 refreshed its recency; the next frame evicts s2.
      await h.store.recordLatestFrame("s4", frame("s4"));
      expect((await h.store.getSession("s1")).latestCameraFrame).toBeDefined();
      expect((await h.store.getSession("s2")).latestCameraFrame).toBeUndefined();
      expect((await h.store.getSession("s3")).latestCameraFrame).toBeDefined();
      expect((await h.store.getSession("s4")).latestCameraFrame).toBeDefined();
    },
    { frameCacheMaxSessions: 3 },
  );

  it("bounds the default cache at 500 sessions, evicting the oldest first", async () => {
    for (const mode of ["memory", "firestore"] as const) {
      const h = makeHarness(mode);
      for (let i = 0; i <= FRAME_CACHE_MAX_SESSIONS; i++) {
        await h.store.recordLatestFrame(`s${i}`, {
          mimeType: "image/jpeg",
          dataBase64: `${FRAME_PAYLOAD}-${i}`,
          updatedAt: CLIENT_FUTURE_ISO,
        });
      }
      expect(
        (await h.store.getSession("s0")).latestCameraFrame,
      ).toBeUndefined();
      expect(
        (await h.store.getSession("s1")).latestCameraFrame?.dataBase64,
      ).toBe(`${FRAME_PAYLOAD}-1`);
      expect(
        (await h.store.getSession(`s${FRAME_CACHE_MAX_SESSIONS}`))
          .latestCameraFrame?.dataBase64,
      ).toBe(`${FRAME_PAYLOAD}-${FRAME_CACHE_MAX_SESSIONS}`);
    }
  });
});

// ---------------------------------------------------------------------------
// TransientFrameCache unit behavior
// ---------------------------------------------------------------------------

describe("TransientFrameCache", () => {
  it("expires entries at the TTL boundary from server receipt", () => {
    const cache = new TransientFrameCache(10, 1_000);
    cache.set("a", { mimeType: "image/jpeg", dataBase64: "x", updatedAt: "" }, 0);
    expect(cache.get("a", 999)).toBeDefined();
    expect(cache.get("a", 1_000)).toBeUndefined();
    expect(cache.size).toBe(0);
  });

  it("sweeps expired entries and evicts LRU beyond capacity", () => {
    const cache = new TransientFrameCache(2, 1_000);
    const frame = { mimeType: "image/jpeg", dataBase64: "x", updatedAt: "" };
    cache.set("a", frame, 0);
    cache.set("b", frame, 100);
    cache.get("a", 200); // refresh recency of a
    cache.set("c", frame, 200); // evicts b (LRU)
    expect(cache.get("a", 300)).toBeDefined();
    expect(cache.get("b", 300)).toBeUndefined();
    expect(cache.get("c", 300)).toBeDefined();

    cache.sweepExpired(1_200); // a and c both expired (receipt 0 and 200)
    expect(cache.size).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// Factory mode resolution (unchanged behavior)
// ---------------------------------------------------------------------------

describe("createLiveSessionStore", () => {
  it("resolves auto mode to memory without a project and firestore with one", () => {
    const memoryStore = createLiveSessionStore({
      sessionStoreMode: "auto",
      projectId: undefined,
      firestoreCollection: "liveSessions",
      firestoreEmulator: undefined,
    });
    expect(memoryStore.mode).toBe("memory");

    const firestoreStore = createLiveSessionStore(
      {
        sessionStoreMode: "auto",
        projectId: "test-project",
        firestoreCollection: "liveSessions",
        firestoreEmulator: undefined,
      },
      { firestore: new FakeFirestore() },
    );
    expect(firestoreStore.mode).toBe("firestore");
  });
});

// ---------------------------------------------------------------------------
// Integration: the real scene-assessment caller reads a current transient frame
// ---------------------------------------------------------------------------

describe("live session store — toolRegistry integration", () => {
  function makeToolDeps(store: LiveSessionStore): {
    deps: ToolDeps;
    captured: { contents: unknown[] };
  } {
    const captured = { contents: [] as unknown[] };
    const config = {
      port: 8080,
      useVertexAi: false,
      apiKey: "test-key",
      recipeModel: "gemini-2.5-flash",
      rankingModel: "gemini-2.5-flash",
      liveModel: "gemini-2.5-flash-native-audio-preview-12-2025",
      restockThresholdDays: 3,
      idempotencyTtlSeconds: 3600,
      restockBelowGrams: 50,
      sessionStoreMode: "memory",
      firestoreCollection: "liveSessions",
      groundingEnabled: true,
    } as unknown as AppConfig;
    const ai = {
      models: {
        generateContent: async (req: { contents?: unknown }) => {
          captured.contents.push(req.contents);
          const joined = JSON.stringify(req.contents);
          if (joined.includes("selected_recipe_title")) {
            return {
              text: JSON.stringify({
                currentStep: "Saute the onions",
                guidance: "Keep stirring for 1 minute.",
                observedIngredients: ["onion"],
                kitchenRisks: [],
                modelConfidence: 0.9,
              }),
            };
          }
          return { text: "{}" };
        },
      },
    } as unknown as GoogleGenAI;
    return {
      deps: {
        ai,
        config,
        ledger: new InventoryLedger(config),
        confidenceService: new ConfidenceService(),
        sessionStore: store,
      },
      captured,
    };
  }

  forBothStores("scene assessment reads the frame inside the transient window", async (h) => {
    const registry = buildToolRegistry();
    const { deps, captured } = makeToolDeps(h.store);

    await h.store.ensureSession("s1");
    await h.store.patchContext("s1", {
      selectedRecipe: { title: "Soup", ingredients: [{ name: "onion" }] },
    });
    await h.store.recordLatestFrame("s1", {
      mimeType: "image/jpeg",
      dataBase64: FRAME_PAYLOAD,
      updatedAt: CLIENT_FUTURE_ISO,
    });

    const recipeContext = await dispatchToolCall(
      "get_recipe_context",
      {},
      registry,
      deps,
      "s1",
    );
    expect((recipeContext.result as { hasRecentCameraFrame: boolean }).hasRecentCameraFrame).toBe(true);

    const assessment = await dispatchToolCall(
      "assess_live_scene",
      { userQuestion: "what now?" },
      registry,
      deps,
      "s1",
    );
    expect(assessment.error).toBeUndefined();
    expect((assessment.result as { currentStep: string }).currentStep).toBe(
      "Saute the onions",
    );
    // The scene-assessment call received the transient frame bytes.
    expect(JSON.stringify(captured.contents)).toContain(FRAME_PAYLOAD);

    // After the TTL the bytes are gone from the model path too.
    h.clock.advance(FRAME_TTL_MS);
    captured.contents.length = 0;

    const expiredContext = await dispatchToolCall(
      "get_recipe_context",
      {},
      registry,
      deps,
      "s1",
    );
    expect(
      (expiredContext.result as { hasRecentCameraFrame: boolean }).hasRecentCameraFrame,
    ).toBe(false);

    await dispatchToolCall("assess_live_scene", { userQuestion: "again" }, registry, deps, "s1");
    expect(JSON.stringify(captured.contents)).not.toContain(FRAME_PAYLOAD);
  });
});
