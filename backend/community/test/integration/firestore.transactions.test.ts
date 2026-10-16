/**
 * Firestore adapter probes for the StoreTransaction seam (documentStore.ts):
 * reads inside a runTransaction see the transaction's own writes; a fn that
 * throws commits nothing; parallel read-modify-writes on one doc do not lose
 * updates (the property consumeRate's daily counters rely on). These exercise
 * the SDK Transaction itself, so they run under the emulator only — the same
 * guard as the Firestore contract tier.
 *
 * Negative controls: without the tx-bound doc refs (plain doc refs), the
 * rollback probe leaves the write committed and the parallel probe loses an
 * update.
 */
import { describe, expect, test } from "bun:test";
import { openFirestoreStore } from "../../src/core/store/firestore.js";

const withEmulator = process.env.FIRESTORE_EMULATOR_HOST !== undefined ? describe : describe.skip;

withEmulator("FirestoreStore.runTransaction honours the StoreTransaction seam", () => {
  // Unique per run: a long-lived emulator persists data, and the probes assume
  // empty collections.
  const projectId = `fridgeluck-contract-tx-${Date.now().toString(36)}`;

  test("a fn that writes then throws commits nothing (rollback)", async () => {
    const store = await openFirestoreStore(projectId);
    await expect(
      store.runTransaction(async (tx) => {
        await tx.collection("txProbe").doc("rollback").set({ v: 1 });
        throw new Error("deliberate rollback");
      }),
    ).rejects.toThrow("deliberate rollback");
    const after = await store.collection("txProbe").doc("rollback").get();
    expect(after.data).toBeNull();
  });

  test("reads inside the transaction see its own writes", async () => {
    const store = await openFirestoreStore(projectId);
    const seen = await store.runTransaction(async (tx) => {
      await tx.collection("txProbe").doc("ryw").set({ v: 7 });
      return (await tx.collection("txProbe").doc("ryw").get()).data;
    });
    expect(seen).toEqual({ v: 7 });
  });

  test("two parallel counter increments do not lose an update", async () => {
    const store = await openFirestoreStore(projectId);
    await store.collection("txProbe").doc("counter").set({ count: 0 });
    await Promise.all(
      Array.from({ length: 2 }, () =>
        store.runTransaction(async (tx) => {
          const ref = tx.collection("txProbe").doc("counter");
          const snap = await ref.get();
          const count = typeof snap.data?.["count"] === "number" ? (snap.data["count"] as number) : 0;
          await ref.update({ count: count + 1 });
        }),
      ),
    );
    const final = await store.collection("txProbe").doc("counter").get();
    expect(final.data?.["count"]).toBe(2);
  });
});
