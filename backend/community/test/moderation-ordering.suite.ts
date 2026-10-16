/**
 * Regression tests for moderation decision ordering, found by the
 * emulator-backed journey run (2026-10-16): two decisions on one target that
 * share a clock tick made "the most recent review wins" (casesHideTarget)
 * depend on the store's iteration order. On memory, insertion order happened
 * to favor the later review; on Firestore, equality-query results come back
 * ordered by document id — arbitrary — so hide-then-dismiss restored the card
 * in 2 of 5 runs and left it hidden in the other 3.
 *
 * The fix is writer-side: the decision route stamps decidedAt strictly past
 * every earlier decision recorded for the target (+1ms per bump), so the
 * later review always carries the later timestamp on every store.
 *
 * The suite is store-parameterized, mirroring greptile-fixes.suite.ts: the
 * unit tier runs it on the in-memory store (test/moderation-ordering.test.ts),
 * the integration tier runs it unchanged on the production Firestore adapter
 * under the emulator
 * (test/integration/moderation-ordering.firestore.test.ts).
 */

import { describe, expect, test } from "bun:test";
import { buildApp, type App } from "../src/app.js";
import type { DocumentStore } from "../src/core/store/documentStore.js";
import { CASES_COLLECTION } from "../src/core/storeRepos.js";
import { addMember, cook, createTable, fakeClock, signUp, stubApple, T0, withOperator } from "./greptile-fixes.suite.js";

// The shared suite keeps its request helpers private; define the two needed here.
const authed = (token: string, init: RequestInit = {}): RequestInit => ({
  ...init,
  headers: { ...(init.headers as Record<string, string> | undefined), authorization: `Bearer ${token}` },
});
const jsonInit = (method: string, body: unknown): RequestInit => ({ method, headers: { "content-type": "application/json" }, body: JSON.stringify(body) });

export type ModerationOrderingStoreFactory = (kind: "plain") => Promise<DocumentStore>;

export function runModerationOrdering(label: string, makeStore: ModerationOrderingStoreFactory, opts: { subPrefix?: string } = {}): void {
  const prefix = opts.subPrefix ?? "";
  describe(`moderation decision ordering (${label})`, () => {
    test("same-tick decisions stay ordered: hide then dismiss restores the card on any store", async () => {
      // A frozen clock puts every decision on the same millisecond — exactly
      // the tie the old reader-side store-order fallback used to break on.
      const clock = fakeClock(T0);
      const store = await makeStore("plain");
      const app = await buildApp({ apple: stubApple, store, clock: clock.clock });
      const owner = await signUp(app, `${prefix}sub-mo-owner`, { adult: true });
      const tableId = await createTable(app, owner.accessToken);
      const member = await addMember(app, owner.accessToken, tableId, `${prefix}sub-mo-member`);
      const op = await withOperator(app, `${prefix}sub-mo-op`, clock.clock);

      const share = await app.handle(
        new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(member.accessToken, jsonInit("POST", { operationId: crypto.randomUUID(), cook: cook() })) }),
      );
      expect(share.status).toBe(201);
      const { cardId } = (await share.json()) as { cardId: string };
      const feedOf = async (token: string): Promise<string[]> => {
        const response = await app.handle(new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(token) }));
        expect(response.status).toBe(200);
        return ((await response.json()) as { cards: { cardId: string }[] }).cards.map((c) => c.cardId);
      };
      const report = async (): Promise<void> => {
        const response = await app.handle(
          new Request("https://api.test/v1/reports", { ...authed(owner.accessToken, jsonInit("POST", { targetType: "tableCard", targetId: cardId, reason: "spam" })) }),
        );
        expect(response.status).toBe(202);
      };

      // Report → hide: the card leaves every member's feed and the hide
      // decision keeps it hidden after the case resolves (§5.3, §6.5).
      await report();
      const hideCaseId = await op.caseIdFor(cardId);
      expect(
        (await op.opApp.handle(new Request(`https://api.test/v1/moderation/cases/${hideCaseId}/decision`, { ...authed(op.token, jsonInit("POST", { action: "hide" })) }))).status,
      ).toBe(200);
      expect(await feedOf(owner.accessToken)).not.toContain(cardId);

      // Re-report → dismiss at the SAME clock tick. The later review must
      // win, deterministically — its stamp is bumped past the earlier one.
      await report();
      const dismissCaseId = await op.caseIdFor(cardId);
      expect(dismissCaseId).not.toBe(hideCaseId); // the re-report opened a fresh case
      expect(
        (await op.opApp.handle(new Request(`https://api.test/v1/moderation/cases/${dismissCaseId}/decision`, { ...authed(op.token, jsonInit("POST", { action: "dismiss" })) }))).status,
      ).toBe(200);

      // The ordering invariant itself: the two decisions carry strictly
      // increasing stamps, exactly one millisecond apart (the writer bump).
      // Pre-fix both stamps equaled T0 and the outcome rode store order.
      const docs = await store.collection(CASES_COLLECTION).where("targetId", cardId).get();
      const stamps = docs
        .map((d) => (d.data as { decision?: { decidedAt?: unknown } } | null)?.decision?.decidedAt)
        .filter((s): s is string => typeof s === "string")
        .sort();
      expect(stamps).toHaveLength(2);
      const [earlierStamp, laterStamp] = stamps;
      if (earlierStamp === undefined || laterStamp === undefined) {
        throw new Error(`expected two decision stamps, got ${stamps.length}`);
      }
      expect(earlierStamp).not.toBe(laterStamp);
      expect(laterStamp).toBe(new Date(Date.parse(earlierStamp) + 1).toISOString());

      // Only dismiss restores: the card is back for every member.
      expect(await feedOf(owner.accessToken)).toContain(cardId);
      expect(await feedOf(member.accessToken)).toContain(cardId);
    });
  });
}

/** Unused import guard — App flows through withOperator's signature. */
export type { App };
