import { describe, expect, it } from "bun:test";
import { FieldValue } from "@google-cloud/firestore";
import type { SessionStoreMode } from "../config.js";
import {
  createLiveSessionStore,
  FRAME_TTL_MS,
  SESSION_TTL_MS,
  type LiveSessionFirestoreDocRefLike,
  type LiveSessionFirestoreLike,
  type LiveSessionStoreOptions,
} from "../session/liveSessionStore.js";

// ─── Harness ─────────────────────────────────────────────────────────────────

const BASE_MS = Date.parse("2026-01-15T10:00:00.000Z");
/** Marker frame bytes — must never reach any persisted surface. */
const FRAME_PAYLOAD = "U1BFQy0zLTQtUkVURU5USU9OLU1BUktFUi0wMTEx";

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
 * Minimal Firestore fake honoring the merge/delete semantics the store
 * relies on (same contract as liveSessionStore.test.ts's fake).
 */
class FakeFirestore implements LiveSessionFirestoreLike {
  readonly docs = new Map<string, Record<string, unknown>>();

  collection(_name: string): { doc(id: string): LiveSessionFirestoreDocRefLike } {
    const self = this;
    return {
      doc: (id: string) => ({
        async get() {
          const data = self.docs.get(id);
          return { exists: data !== undefined, data: () => data ?? {} };
        },
        async set(data, options) {
          const merge = options?.merge === true;
          const next: Record<string, unknown> = merge
            ? { ...(self.docs.get(id) ?? {}) }
            : {};
          for (const [key, value] of Object.entries(data)) {
            if (isDeleteSentinel(value)) delete next[key];
            else next[key] = value;
          }
          self.docs.set(id, next);
        },
      }),
    };
  }
}

type StoreMode = "memory" | "firestore";

interface Harness {
  store: ReturnType<typeof createLiveSessionStore>;
  clock: ReturnType<typeof makeClock>;
  fake: FakeFirestore;
}

function makeHarness(mode: StoreMode): Harness {
  const clock = makeClock();
  const fake = new FakeFirestore();
  const options: LiveSessionStoreOptions = { now: clock.now, firestore: fake };
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

function forBothStores(name: string, run: (h: Harness) => Promise<void> | void): void {
  for (const mode of ["memory", "firestore"] as const) {
    it(`${name} [${mode}]`, async () => {
      await run(makeHarness(mode));
    });
  }
}

// ─── SPEC 3.4 retention contract on the trunk ────────────────────────────────
//
// SPEC section 3.4, last bullet (binding):
//   "LeChef's backend keeps no camera frames and no transcript beyond the
//   live session unless the user explicitly saves a note. The current
//   Firestore persistence of frames and text
//   (backend/gemini-agent/src/session/liveSessionStore.ts:242-290) is removed
//   or put behind a TTL by the backend trunk task."
//
// These tests verify the contract on the trunk after the folds, against the
// public store API, in both store modes.

describe("SPEC 3.4 retention (backend trunk)", () => {
  it("no camera frame bytes reach the only durable surface [firestore]", async () => {
    const h = makeHarness("firestore");
    await h.store.ensureSession("s1");
    await h.store.recordLatestFrame("s1", {
      mimeType: "image/jpeg",
      dataBase64: FRAME_PAYLOAD,
      updatedAt: new Date(BASE_MS).toISOString(),
    });

    // Scan every persisted document for the raw bytes.
    for (const [, doc] of h.fake.docs) {
      expect(JSON.stringify(doc)).not.toContain(FRAME_PAYLOAD);
      expect(doc.latestCameraFrame).toBeUndefined();
      // Metadata is allowed and expected to persist.
      expect((doc.latestCameraFrameMetadata as { mimeType?: string })?.mimeType).toBe(
        "image/jpeg"
      );
    }
  });

  forBothStores("camera frame bytes expire at the transient-cache TTL boundary", async (h) => {
    await h.store.ensureSession("s1");
    await h.store.recordLatestFrame("s1", {
      mimeType: "image/jpeg",
      dataBase64: FRAME_PAYLOAD,
      updatedAt: new Date(BASE_MS).toISOString(),
    });

    h.clock.advance(FRAME_TTL_MS - 1);
    let state = await h.store.getSession("s1");
    expect(state.latestCameraFrame?.dataBase64).toBe(FRAME_PAYLOAD);

    h.clock.advance(1);
    state = await h.store.getSession("s1");
    expect(state.latestCameraFrame).toBeUndefined();
    expect(state.latestCameraFrame?.dataBase64).toBeUndefined();
  });

  forBothStores(
    "the transcript does not survive the 24h session expiry, while the session is still live it does",
    async (h) => {
      await h.store.ensureSession("s1");
      await h.store.recordUserMessage("s1", "make tomato soup");

      // Inside the live session the last user message is available.
      const live = await h.store.getSession("s1");
      expect(live.lastUserMessage).toBe("make tomato soup");

      // One millisecond past the 24h inactivity TTL the transcript is gone.
      h.clock.advance(SESSION_TTL_MS + 1);
      const expired = await h.store.getSession("s1");
      expect(expired.lastUserMessage).toBeUndefined();
    },
  );

  forBothStores(
    "frames and transcript vanish together after expiry; the next ensureSession starts blank",
    async (h) => {
      await h.store.ensureSession("s1");
      await h.store.recordLatestFrame("s1", {
        mimeType: "image/jpeg",
        dataBase64: FRAME_PAYLOAD,
        updatedAt: new Date(BASE_MS).toISOString(),
      });
      await h.store.recordUserMessage("s1", "remember this dish");

      h.clock.advance(SESSION_TTL_MS + 1);
      const state = await h.store.getSession("s1");
      expect(state.latestCameraFrame).toBeUndefined();
      expect(state.lastUserMessage).toBeUndefined();

      const fresh = await h.store.ensureSession("s1");
      expect(fresh.lastUserMessage).toBeUndefined();
      expect(fresh.latestCameraFrame).toBeUndefined();
    },
  );

  it("legacy persisted frame bytes are purged from Firestore documents on merge writes [firestore]", async () => {
    const h = makeHarness("firestore");
    // Seed the pre-trunk shape: raw bytes persisted at the old location.
    h.fake.docs.set("legacy-1", {
      sessionId: "legacy-1",
      lastUserMessage: "old",
      latestCameraFrame: {
        mimeType: "image/jpeg",
        dataBase64: FRAME_PAYLOAD,
        updatedAt: new Date(BASE_MS).toISOString(),
      },
    });

    // Any store write to the session purges the legacy field.
    await h.store.recordUserMessage("legacy-1", "fresh message");
    const doc = h.fake.docs.get("legacy-1")!;
    expect(JSON.stringify(doc)).not.toContain(FRAME_PAYLOAD);
    expect(doc.latestCameraFrame).toBeUndefined();
    expect(doc.lastUserMessage).toBe("fresh message");
  });
});
