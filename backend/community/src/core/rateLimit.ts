/**
 * Daily per-account rate limits (contract 429 rate_limited). Counts ride the
 * DocumentStore so memory and Firestore behave the same; the counter key is
 * `kind:account:UTC-day`, so limits reset at midnight UTC (the contract's
 * 10 reports per day).
 */

import { errRateLimited } from "./errors.js";
import type { DocumentStore } from "./store/documentStore.js";
import type { Clock } from "./time.js";

export async function consumeRate(
  store: DocumentStore,
  kind: string,
  accountId: string,
  limit: number,
  clock: Clock,
): Promise<void> {
  const day = clock.now().toISOString().slice(0, 10);
  const id = `${kind}:${accountId}:${day}`;
  await store.runTransaction(async (tx) => {
    const ref = tx.collection("rateLimits").doc(id);
    const snap = await ref.get();
    const count = typeof snap.data?.["count"] === "number" ? (snap.data["count"] as number) : 0;
    if (count >= limit) {
      throw errRateLimited(`daily limit of ${limit} for ${kind} reached; resets at midnight UTC`);
    }
    if (snap.data === null) {
      await ref.create({ count: 1, kind, accountId, day });
    } else {
      await ref.update({ count: count + 1 });
    }
  });
}
