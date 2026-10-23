import { describe, expect, it } from "bun:test";
import { Firestore, Timestamp } from "@google-cloud/firestore";
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

  it("reuses an id after its tombstone expires", async () => {
    if (!firestoreAvailable) return;

    const collection = `liveSessions_${Date.now()}`;
    const config = {
      sessionStoreMode: "firestore",
      projectId: "demo-fridgeluck",
      firestoreCollection: collection,
      firestoreEmulator: process.env.FIRESTORE_EMULATOR_HOST,
    } as never;
    const store = createLiveSessionStore(config);
    const firestore = new Firestore({ projectId: "demo-fridgeluck" });
    const ref = firestore.collection(collection).doc("reusable");
    await ref.set({
      deletedAt: Timestamp.fromDate(new Date(Date.now() - 2_000)),
      tombstoneExpiresAt: Timestamp.fromDate(new Date(Date.now() - 1_000)),
    });

    const session = await store.ensureSession("reusable");
    expect(session.createdAt).not.toBe("");
    expect((await store.getSession("reusable")).createdAt).not.toBe("");
  });
});
