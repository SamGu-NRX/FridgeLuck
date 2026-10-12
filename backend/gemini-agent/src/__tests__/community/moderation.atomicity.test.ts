/**
 * Moderation atomicity (PR #104 review blocker 5): a moderation decision and
 * its publication visibility transition are ONE Firestore transaction. The
 * decision, its audit entry, and the moderation-state change that visibility
 * derives from commit together or not at all — no reader, concurrent or
 * after a crash, can observe a decision whose visibility did not move with
 * it (a rejected publication still visible, an approved one still hidden).
 *
 * Proven over the real FirestoreModerationQueue against the emulator:
 *   (1) an approve is live to readers in the same tick, with a concurrent
 *       read loop observing no lag window for the whole decision;
 *   (2) a fault injected inside the transaction after the visibility write
 *       is queued rolls back BOTH writes — decision absent, visibility
 *       unchanged — and the item still resolves normally afterwards;
 *   (3) two concurrent decisions on one item: exactly one lands, the loser
 *       surfaces conflict, nothing corrupts;
 *   (4) a reject mirrors approve — the publication hides atomically;
 *   (5) blocker 1's approval refusal still aborts the whole transaction
 *       (409, item open, visibility untouched) — the fail-closed default
 *       holds on the composed tree.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { makeHarness, type CommunityTestHarness } from "./harness.js";
import { FirestoreModerationQueue, parseModerationItemDoc } from "../../community/explore/moderationQueue.js";
import {
  createPublication,
  listPublishedByCampus,
  parsePublicationDoc,
} from "../../community/explore/publications.js";
import type { ModerationQueueItem, PublicationRef, ScreeningStage, ScreeningVerdict } from "../../community/shared/contracts.js";
import { newAccountId } from "../../community/shared/ids.js";

let harness: CommunityTestHarness;
const moderator = newAccountId();

beforeAll(async () => {
  harness = await makeHarness();
});

afterAll(async () => {
  await harness.close();
});

function passStage(name: string, tags: readonly string[] = []): ScreeningStage {
  return {
    name,
    async run(): Promise<ScreeningVerdict> {
      return { outcome: "pass", stage: name, tags };
    },
  };
}

function failStage(name: string, reasons: readonly string[]): ScreeningStage {
  return {
    name,
    async run(): Promise<ScreeningVerdict> {
      return { outcome: "fail", stage: name, reasons };
    },
  };
}

function makeQueue(fault?: () => void): FirestoreModerationQueue {
  return new FirestoreModerationQueue({
    items: harness.store.moderationItems,
    publications: harness.store.publications,
    clock: harness.clock,
    ...(fault !== undefined ? { throwInsideResolveForTests: fault } : {}),
  });
}

/**
 * A publication the mandatory gate passed (so approval can later publish
 * it), pushed into moderation by a user report — the report hides it
 * pending review, which is the queued state a decision moves it out of.
 */
async function reportedPublication(queue: FirestoreModerationQueue, campus: string): Promise<{ itemId: ModerationQueueItem["itemId"]; target: PublicationRef }> {
  const created = await createPublication(
    { publications: harness.store.publications, clock: harness.clock },
    {
      authorId: newAccountId(),
      sourceRecipeId: `recipes/atomic-${campus}`,
      sourceRecipeRevision: "rev-000001",
      title: "Atomic tomato rice",
      summary: null,
      note: null,
      ingredientLines: ["200 g rice", "2 tomatoes", "1 tbsp olive oil"],
      steps: ["Cook the rice.", "Fry the tomatoes in the oil, fold through the rice."],
      tags: [],
      campus,
      screeningStages: [passStage("food-safety-lint"), passStage("compound-allergens", ["tree-nuts"])],
    },
  );
  if (created.outcome !== "published") {
    throw new Error("fixture publication was expected to pass screening");
  }
  const target: PublicationRef = { publicationId: created.record.publicationId, revisionId: created.record.revisionId };
  const itemId = await queue.submit(target, newAccountId(), "user-report", "needs a human look");
  return { itemId, target };
}

async function docStatus(kind: "publication" | "item", id: string): Promise<string | undefined> {
  const snap =
    kind === "publication"
      ? await harness.store.publications.doc(id).get()
      : await harness.store.moderationItems.doc(id).get();
  const data = snap.data() as Record<string, unknown> | undefined;
  return data?.["status"] as string | undefined;
}

/**
 * A read loop that runs beside a decision and records only PERSISTENT
 * inconsistencies: two plain reads can straddle the commit (one value seen
 * pre-commit, the other post-commit), so an inconsistent pair is re-read —
 * a real lag window persists, a straddle does not.
 */
async function watchForLagWindow(publicationId: string, itemId: string, stopped: () => boolean, violations: string[]): Promise<void> {
  while (!stopped()) {
    const pubStatus = await docStatus("publication", publicationId);
    const itemStatus = await docStatus("item", itemId);
    if (itemStatus === "resolved" && pubStatus === "queued") {
      if ((await docStatus("publication", publicationId)) === "queued") {
        violations.push("decision landed while the publication was still hidden from readers");
      }
    }
    if (itemStatus === "open" && pubStatus !== undefined && pubStatus !== "queued") {
      if ((await docStatus("item", itemId)) === "open") {
        violations.push("publication moved while the decision had not landed");
      }
    }
    await new Promise((r) => setTimeout(r, 0));
  }
}

describe("moderation atomicity: decision and visibility move as one (blocker 5)", () => {
  test("an approve is live to readers in the same tick, with no lag window a concurrent reader can observe", async () => {
    const queue = makeQueue();
    const { itemId, target } = await reportedPublication(queue, "atomic-approve");
    const violations: string[] = [];
    let stopped = false;
    const watcher = watchForLagWindow(target.publicationId, itemId, () => stopped, violations);

    const resolved = await queue.resolve(itemId, "approved", moderator, "screening records check out");
    stopped = true;
    await watcher;

    expect(violations).toEqual([]);
    expect(resolved.status).toBe("resolved");
    expect(resolved.decision).toBe("approved");
    // Same tick: the very first read after resolve() returns already sees
    // the publication live — and the reader surface it feeds agrees.
    const pub = parsePublicationDoc(await harness.store.publications.doc(target.publicationId).get());
    expect(pub?.status).toBe("published");
    const feed = await listPublishedByCampus({ publications: harness.store.publications, clock: harness.clock }, "atomic-approve");
    expect(feed.map((r) => r.publicationId)).toContain(target.publicationId);
  });

  test("a failure inside the transaction rolls back decision and visibility together — no partial state", async () => {
    for (const decision of ["approved", "rejected"] as const) {
      const queue = makeQueue(() => {
        throw new Error(`injected failure after the visibility write (${decision})`);
      });
      const { itemId, target } = await reportedPublication(queue, `atomic-rollback-${decision}`);

      await expect(queue.resolve(itemId, decision, moderator, "deciding")).rejects.toThrow(
        "injected failure after the visibility write",
      );

      // NO partial state persists: the decision is absent AND visibility
      // is unchanged — the core no-lag-window guarantee after a crash.
      const item = parseModerationItemDoc(await harness.store.moderationItems.doc(itemId).get());
      expect(item?.status).toBe("open");
      expect(item?.decision).toBeNull();
      expect(item?.resolvedAt).toBeNull();
      const pub = parsePublicationDoc(await harness.store.publications.doc(target.publicationId).get());
      expect(pub?.status).toBe("queued");

      // Recovery: the same item still resolves, atomically.
      const resolved = await makeQueue().resolve(itemId, decision, moderator, "retry after rollback");
      expect(resolved.decision).toBe(decision);
      const pubAfter = parsePublicationDoc(await harness.store.publications.doc(target.publicationId).get());
      expect(pubAfter?.status).toBe(decision === "approved" ? "published" : "rejected");
    }
  });

  test("two concurrent decisions on one item: exactly one lands, the loser surfaces conflict, nothing corrupts", async () => {
    const queue = makeQueue();
    const { itemId, target } = await reportedPublication(queue, "atomic-race");

    const settled = await Promise.allSettled([
      queue.resolve(itemId, "approved", newAccountId(), "fine by me"),
      queue.resolve(itemId, "rejected", newAccountId(), "not appropriate"),
    ]);
    const winners = settled.filter((s): s is PromiseFulfilledResult<ModerationQueueItem> => s.status === "fulfilled");
    const losers = settled.filter((s): s is PromiseRejectedResult => s.status === "rejected");
    expect(winners).toHaveLength(1);
    expect(losers).toHaveLength(1);
    expect(losers[0]?.reason).toMatchObject({ code: "conflict", status: 409 });

    const winnerDecision = winners[0]?.value.decision;
    expect(winnerDecision === "approved" || winnerDecision === "rejected").toBe(true);

    // The surviving state is exactly the winner's, consistently across both
    // documents — the loser's queued writes rolled back whole.
    const item = parseModerationItemDoc(await harness.store.moderationItems.doc(itemId).get());
    expect(item?.status).toBe("resolved");
    expect(item?.decision).toBe(winnerDecision);
    const decisionEntries = item?.audit.filter((entry) => entry.action.startsWith("decision:")) ?? [];
    expect(decisionEntries).toHaveLength(1);
    const pub = parsePublicationDoc(await harness.store.publications.doc(target.publicationId).get());
    expect(pub?.status).toBe(winnerDecision === "approved" ? "published" : "rejected");
  });

  test("a reject hides the publication atomically — the same lag-window guarantee as approve", async () => {
    const queue = makeQueue();
    const { itemId, target } = await reportedPublication(queue, "atomic-reject");
    const violations: string[] = [];
    let stopped = false;
    const watcher = watchForLagWindow(target.publicationId, itemId, () => stopped, violations);

    const resolved = await queue.resolve(itemId, "rejected", moderator, "promotional");
    stopped = true;
    await watcher;

    expect(violations).toEqual([]);
    expect(resolved.decision).toBe("rejected");
    const pub = parsePublicationDoc(await harness.store.publications.doc(target.publicationId).get());
    expect(pub?.status).toBe("rejected");
    // Hidden from the reader surface in the same tick.
    const feed = await listPublishedByCampus({ publications: harness.store.publications, clock: harness.clock }, "atomic-reject");
    expect(feed.map((r) => r.publicationId)).not.toContain(target.publicationId);
  });

  test("blocker 1 composes: the approval refusal aborts the whole transaction — item open, visibility untouched", async () => {
    const queue = makeQueue();
    // Screening FAILED the mandatory lint: the record's own evaluation
    // proves it, so approval must refuse (fail closed) — and nothing else
    // may land with the refusal.
    const created = await createPublication(
      { publications: harness.store.publications, clock: harness.clock },
      {
        authorId: newAccountId(),
        sourceRecipeId: "recipes/atomic-refused",
        sourceRecipeRevision: "rev-000001",
        title: "Refused tomato rice",
        summary: null,
        note: null,
        ingredientLines: ["200 g rice"],
        steps: ["Cook the rice."],
        tags: [],
        campus: "atomic-refused",
        screeningStages: [failStage("food-safety-lint", ["required doneness statement missing"]), passStage("compound-allergens", [])],
      },
    );
    if (created.outcome !== "queued") {
      throw new Error("fixture publication was expected to fail screening into the queue");
    }
    const target: PublicationRef = { publicationId: created.record.publicationId, revisionId: created.record.revisionId };
    const itemId = await queue.submit(target, newAccountId(), "author-appeal", "please reconsider");

    await expect(queue.resolve(itemId, "approved", moderator, "override")).rejects.toMatchObject({
      code: "conflict",
      status: 409,
    });

    // The refusal aborted the transaction whole: no decision, no visibility
    // change, nothing partial.
    const item = parseModerationItemDoc(await harness.store.moderationItems.doc(itemId).get());
    expect(item?.status).toBe("open");
    expect(item?.decision).toBeNull();
    const pub = parsePublicationDoc(await harness.store.publications.doc(target.publicationId).get());
    expect(pub?.status).toBe("queued");
  });

  test("the registered decision handler is notified exactly once, after the commit", async () => {
    const queue = makeQueue();
    const { itemId, target } = await reportedPublication(queue, "atomic-handler");
    const calls: Array<{ publicationId: string; decision: string; itemStatusAtCall: string | null | undefined }> = [];
    queue.registerDecisionHandler(async (receivedTarget, decision) => {
      const item = parseModerationItemDoc(await harness.store.moderationItems.doc(itemId).get());
      calls.push({
        publicationId: receivedTarget.publicationId,
        decision,
        itemStatusAtCall: item?.status,
      });
    });

    await queue.resolve(itemId, "approved", moderator, "ok");

    expect(calls).toHaveLength(1);
    expect(calls[0]?.publicationId).toBe(target.publicationId);
    expect(calls[0]?.decision).toBe("approved");
    // Post-commit: the decision is already durable when the handler runs.
    expect(calls[0]?.itemStatusAtCall).toBe("resolved");
  });
});
