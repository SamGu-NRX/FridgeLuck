import { describe, expect, it } from "bun:test";
import { createLiveSessionStore } from "../session/liveSessionStore.js";

const firestoreAvailable = Boolean(process.env.FIRESTORE_EMULATOR_HOST);

describe("Firestore live session tombstones", () => {
  it("prevents another store instance from recreating a deleted session", async () => {
    if (!firestoreAvailable) return;

    const config = {
      sessionStoreMode: "firestore",
      projectId: "demo-fridgeluck",
      firestoreCollection: `liveSessions_${Date.now()}`,
      firestoreEmulator: process.env.FIRESTORE_EMULATOR_HOST,
    } as never;
    const instanceA = createLiveSessionStore(config);
    const instanceB = createLiveSessionStore(config);

    await instanceA.ensureSession("two-instances");
    await instanceA.deleteSession("two-instances");

    // This is the late ensure from a different Cloud Run instance.
    const late = await instanceB.ensureSession("two-instances");
    expect(late.createdAt).toBe("");
    expect((await instanceA.getSession("two-instances")).createdAt).toBe("");
  });
});
