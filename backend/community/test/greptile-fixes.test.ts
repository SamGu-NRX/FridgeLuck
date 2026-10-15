/**
 * Regression tests for the Greptile review of PR #166 (head 015fc30,
 * 2026-10-15): one test per inline thread, each failing on the reviewed head
 * and passing after the fix. Covers blocks as per-person rows, moderation
 * decisions that keep their effect on table cards and challenge entries,
 * returning members, transactional read-check-write paths (invite claim,
 * entry replacement, operationId replay), the published-revision lookup, and
 * viewer-visible entry counts. Race tests issue the overlapping requests
 * concurrently with Promise.all against the in-memory store.
 */

import { describe, test, expect } from "bun:test";
import { buildApp, type App } from "../src/app.js";
import { MemoryStore } from "../src/core/store/memory.js";
import type { DocumentStore, StoreCollection, StoreDocRef, StoreQuery } from "../src/core/store/documentStore.js";
import type { AppleIdentityTokenClaims } from "../src/core/appleVerify.js";
import { createChallengeDocument, ENTRIES_COLLECTION } from "../src/modules/challenges/views.js";
import type { Clock } from "../src/core/time.js";

const stubApple = {
  verify: async (identityToken: string, nonce: string, _nowMs: number): Promise<AppleIdentityTokenClaims> => {
    if (!identityToken.startsWith("stub-jwt-")) {
      throw new Error("rejected by Apple");
    }
    return { appleSub: identityToken.slice(9), nonce, email: "nobody@privaterelay.appleid.com" };
  },
};

/** A controllable clock; challenge seeds and session lifetimes ride it. */
function fakeClock(startMs: number): { clock: Clock; now: () => number; advanceHours: (h: number) => void } {
  let ms = startMs;
  return {
    clock: { now: () => new Date(ms) },
    now: () => ms,
    advanceHours: (h: number) => {
      ms += h * 60 * 60 * 1000;
    },
  };
}

/**
 * Forces every plain read to hop a macrotask so overlapping requests genuinely
 * interleave: both requests finish their reads before either one writes.
 * Transactional reads (inside runTransaction) bypass the wrapper, which is the
 * point — after the fix the claim/replay checks are serialized by the
 * transaction and the races close deterministically.
 */
function jitteredStore(base: MemoryStore): DocumentStore {
  const delay = <T,>(p: Promise<T>): Promise<T> => new Promise<T>((resolve, reject) => void setTimeout(() => p.then(resolve, reject), 0));
  const wrapDoc = (doc: StoreDocRef): StoreDocRef => ({
    id: doc.id,
    get: () => delay(doc.get()),
    create: (data) => doc.create(data),
    set: (data) => doc.set(data),
    update: (data) => doc.update(data),
  });
  const wrapQuery = (q: StoreQuery): StoreQuery => ({
    where: (f, v) => wrapQuery(q.where(f, v)),
    limit: (n) => q.limit(n),
    get: () => delay(q.get()),
  });
  const wrapColl = (coll: StoreCollection): StoreCollection => ({
    id: coll.id,
    doc: (id) => wrapDoc(coll.doc(id)),
    where: (f, v) => wrapQuery(coll.where(f, v)),
  });
  return { collection: (id) => wrapColl(base.collection(id)), runTransaction: (fn) => base.runTransaction(fn) };
}

const T0 = Date.UTC(2026, 9, 15, 12, 0, 0);

async function signUp(app: App, sub: string, opts: { adult?: boolean } = {}): Promise<{ accessToken: string; accountId: string }> {
  const response = await app.handle(
    new Request("https://api.test/v1/auth/apple", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        identityToken: `stub-jwt-${sub}`,
        nonce: crypto.randomUUID(),
        ...(opts.adult ? { attest18Plus: { birthYear: 1990 } } : {}),
      }),
    }),
  );
  expect(response.status).toBe(200);
  const data = (await response.json()) as { accessToken: string; account: { accountId: string } };
  return { accessToken: data.accessToken, accountId: data.account.accountId };
}

const authed = (token: string, init: RequestInit = {}): RequestInit => ({
  ...init,
  headers: { ...(init.headers as Record<string, string> | undefined), authorization: `Bearer ${token}` },
});

const jsonInit = (method: string, body: unknown): RequestInit => ({ method, headers: { "content-type": "application/json" }, body: JSON.stringify(body) });

const cook = (over: Record<string, unknown> = {}) => ({
  recipeRef: { source: "user", id: "ur_1", revision: 1 },
  dishName: "Lemon pasta",
  servings: 2,
  swaps: [{ fromName: "milk", toName: "oat milk" }],
  rating: 5,
  note: null,
  day: "2026-10-15",
  content: null,
  ...over,
});

async function createTable(app: App, token: string, name = "Sunday crew"): Promise<string> {
  const response = await app.handle(new Request("https://api.test/v1/tables", { ...authed(token, jsonInit("POST", { name })) }));
  expect(response.status).toBe(201);
  return ((await response.json()) as { tableId: string }).tableId;
}

/** Full owner-approved join: owner mints, joiner presents, owner approves. */
async function addMember(app: App, ownerToken: string, tableId: string, joinerSub: string): Promise<{ accessToken: string; accountId: string }> {
  const mint = await app.handle(new Request(`https://api.test/v1/tables/${tableId}/invites`, { method: "POST", ...authed(ownerToken) }));
  expect(mint.status).toBe(201);
  const { inviteId, joinCode } = (await mint.json()) as { inviteId: string; joinCode: string };
  const joiner = await signUp(app, joinerSub, { adult: true });
  const join = await app.handle(new Request(`https://api.test/v1/invites/${joinCode}/join`, { method: "POST", ...authed(joiner.accessToken) }));
  expect(join.status).toBe(202);
  const approve = await app.handle(new Request(`https://api.test/v1/tables/${tableId}/invites/${inviteId}/approve`, { method: "POST", ...authed(ownerToken) }));
  expect(approve.status).toBe(200);
  return joiner;
}

const cleanRecipe = {
  title: "Lemon pasta for two",
  description: "A bright weeknight dinner.",
  servings: 2,
  timeMinutes: 15,
  ingredientLines: [
    { name: "milk", quantity: 200, unit: "ml" },
    { name: "flour", quantity: 250, unit: "g" },
  ],
  steps: [{ text: "Boil the pasta, then cook everything together for ten minutes.", timerMinutes: 10 }],
  equipment: ["pan"],
  dietaryTags: ["vegetarian"],
};

async function publish(app: App, token: string, recipeRef: Record<string, unknown>): Promise<string> {
  const response = await app.handle(
    new Request("https://api.test/v1/publications", {
      ...authed(token, jsonInit("POST", { operationId: crypto.randomUUID(), recipeRef, content: cleanRecipe, declaration: { ownRights: true, noPersonalData: true } })),
    }),
  );
  expect(response.status).toBe(201);
  return ((await response.json()) as { publicationId: string }).publicationId;
}

const iso = (ms: number): string => new Date(ms).toISOString();

/** Operator over the same store: queue reads and decisions ride opApp. */
async function withOperator(app: App, sub: string): Promise<{ token: string; opApp: App; caseIdFor: (targetId: string) => Promise<string> }> {
  const operator = await signUp(app, sub);
  const opApp = await buildApp({
    apple: stubApple,
    store: (app as unknown as { store: import("../src/core/store/documentStore.js").DocumentStore })["store"],
    config: { operatorAccountIds: [operator.accountId] },
  });
  return {
    token: operator.accessToken,
    opApp,
    caseIdFor: async (targetId: string) => {
      const queue = await opApp.handle(new Request("https://api.test/v1/moderation/queue", { headers: { authorization: `Bearer ${operator.accessToken}` } }));
      expect(queue.status).toBe(200);
      const cases = ((await queue.json()) as { cases: { caseId: string; targetId: string; state: string }[] }).cases;
      const found = cases.find((c) => c.targetId === targetId && c.state === "queued");
      expect(found).toBeDefined();
      return (found as { caseId: string }).caseId;
    },
  };
}

const decide = (opApp: App, token: string, caseId: string, action: string): Promise<Response> =>
  opApp.handle(new Request(`https://api.test/v1/moderation/cases/${caseId}/decision`, { ...authed(token, jsonInit("POST", { action })) }));

describe("Greptile PR #166 findings", () => {
  test("blocks are per-person: the blocked party cannot list or erase the blocker's block (tables:548)", async () => {
    const app = await buildApp({ apple: stubApple });
    const a = await signUp(app, "sub-gp-blk-a", { adult: true });
    const b = await signUp(app, "sub-gp-blk-b", { adult: true });
    const tableId = await createTable(app, a.accessToken);
    await addMember(app, a.accessToken, tableId, "sub-gp-blk-b");
    await app.handle(new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(b.accessToken, jsonInit("POST", { operationId: crypto.randomUUID(), cook: cook() })) }));
    await app.handle(
      new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(a.accessToken, jsonInit("POST", { operationId: crypto.randomUUID(), cook: cook({ dishName: "A dish" }) })) }),
    );
    const block = await app.handle(new Request(`https://api.test/v1/blocks/${b.accountId}`, { method: "PUT", ...authed(a.accessToken) }));
    expect(block.status).toBe(204);

    // B must not see A's private block in their own list.
    const bList = (await (await app.handle(new Request("https://api.test/v1/blocks", { ...authed(b.accessToken) }))).json()) as { blocks: { accountId: string }[] };
    expect(bList.blocks).toHaveLength(0); // 015fc30: leaks A's block to B

    // B pointing an unblock at A erases only B's own (nonexistent) row, never A's.
    const erase = await app.handle(new Request(`https://api.test/v1/blocks/${a.accountId}`, { method: "DELETE", ...authed(b.accessToken) }));
    expect(erase.status).toBe(204);
    const aList = (await (await app.handle(new Request("https://api.test/v1/blocks", { ...authed(a.accessToken) }))).json()) as { blocks: { accountId: string }[] };
    expect(aList.blocks).toHaveLength(1); // 015fc30: B's delete erases A's block
    expect(aList.blocks[0]?.accountId).toBe(b.accountId);

    // The pair's feeds stay filtered: either person's block hides both sides.
    const aFeed = (await (await app.handle(new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(a.accessToken) }))).json()) as { cards: { isMine: boolean }[] };
    expect(aFeed.cards).toHaveLength(1);
    const bFeed = (await (await app.handle(new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(b.accessToken) }))).json()) as { cards: { isMine: boolean }[] };
    expect(bFeed.cards).toHaveLength(1);
  });

  test("a hide decision keeps a reported table card hidden; dismiss restores it (tables:155-158)", async () => {
    const app = await buildApp({ apple: stubApple });
    const owner = await signUp(app, "sub-gp-card-owner", { adult: true });
    const tableId = await createTable(app, owner.accessToken);
    const member = await addMember(app, owner.accessToken, tableId, "sub-gp-card-member");
    const op = await withOperator(app, "sub-gp-op1");

    const share = await app.handle(
      new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(member.accessToken, jsonInit("POST", { operationId: crypto.randomUUID(), cook: cook() })) }),
    );
    expect(share.status).toBe(201);
    const cardId = ((await share.json()) as { cardId: string }).cardId;

    const report = await app.handle(
      new Request("https://api.test/v1/reports", { ...authed(owner.accessToken, jsonInit("POST", { targetType: "tableCard", targetId: cardId, reason: "spam" })) }),
    );
    expect(report.status).toBe(202);

    const caseId = await op.caseIdFor(cardId);
    const hidden = await decide(op.opApp, op.token, caseId, "hide");
    expect(hidden.status).toBe(200);

    // 015fc30: resolving the case restores the card — the feed checks only queued cases.
    const afterHide = (await (await app.handle(new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(owner.accessToken) }))).json()) as { cards: { cardId: string }[] };
    expect(afterHide.cards.find((c) => c.cardId === cardId)).toBeUndefined();

    // dismiss has no hiding effect: a fresh report decided dismiss brings the card back.
    await app.handle(new Request("https://api.test/v1/reports", { ...authed(owner.accessToken, jsonInit("POST", { targetType: "tableCard", targetId: cardId, reason: "spam" })) }));
    const caseId2 = await op.caseIdFor(cardId);
    const dismissed = await decide(op.opApp, op.token, caseId2, "dismiss");
    expect(dismissed.status).toBe(200);
    const afterDismiss = (await (await app.handle(new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(owner.accessToken) }))).json()) as { cards: { cardId: string }[] };
    expect(afterDismiss.cards.find((c) => c.cardId === cardId)).toBeDefined();
  });

  test("a remove decision keeps a reported challenge entry hidden (tables:155-158, challenges view)", async () => {
    const store = new MemoryStore();
    const { clock } = fakeClock(T0);
    const app = await buildApp({ apple: stubApple, store, clock });
    const challenge = await createChallengeDocument(store, {
      type: "battle",
      name: "Decision test",
      brief: "b",
      opensAt: iso(clock.now().getTime() - 3600_000),
      entryClosesAt: iso(clock.now().getTime() + 48 * 3600_000),
      votingClosesAt: iso(clock.now().getTime() + 96 * 3600_000),
      resolvedItems: null,
      packId: null,
    });
    const author = await signUp(app, "sub-gp-entry-a", { adult: true });
    const viewer = await signUp(app, "sub-gp-entry-v", { adult: true });
    const op = await withOperator(app, "sub-gp-op2");
    const publicationId = await publish(app, author.accessToken, { source: "user", id: "ur_1", revision: 1 });
    void publicationId;
    const entry = await app.handle(
      new Request(`https://api.test/v1/challenges/${challenge.challengeId}/entries`, {
        ...authed(author.accessToken, jsonInit("POST", { operationId: crypto.randomUUID(), recipeRef: { source: "user", id: "ur_1", revision: 1 } })),
      }),
    );
    expect(entry.status).toBe(201);
    const { entryId } = (await entry.json()) as { entryId: string };

    const report = await app.handle(
      new Request("https://api.test/v1/reports", { ...authed(viewer.accessToken, jsonInit("POST", { targetType: "challengeEntry", targetId: entryId, reason: "spam" })) }),
    );
    expect(report.status).toBe(202);
    const caseId = await op.caseIdFor(entryId);
    expect((await decide(op.opApp, op.token, caseId, "remove")).status).toBe(200);

    // 015fc30: the resolved case stops hiding the entry.
    const seen = (await (await app.handle(new Request(`https://api.test/v1/challenges/${challenge.challengeId}`, { ...authed(viewer.accessToken) }))).json()) as {
      challenge: { entryCount: number };
      entries: unknown[];
    };
    expect(seen.entries).toHaveLength(0);
    expect(seen.challenge.entryCount).toBe(0);
  });

  test("a returning member can use their slot again and be removed (tables:280-282)", async () => {
    const app = await buildApp({ apple: stubApple });
    const owner = await signUp(app, "sub-gp-ret-owner", { adult: true });
    const tableId = await createTable(app, owner.accessToken);
    const member = await addMember(app, owner.accessToken, tableId, "sub-gp-ret-member");

    // Leave, then return through a fresh invite.
    const leave = await app.handle(new Request(`https://api.test/v1/tables/${tableId}/leave`, { method: "POST", ...authed(member.accessToken) }));
    expect(leave.status).toBe(204);
    const again = await addMember(app, owner.accessToken, tableId, "sub-gp-ret-member");
    void again;

    // 015fc30: membership checks keep finding the old departed row.
    const memberView = await app.handle(new Request(`https://api.test/v1/tables/${tableId}`, { ...authed(member.accessToken) }));
    expect(memberView.status).toBe(200);

    const memberShare = await app.handle(
      new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(member.accessToken, jsonInit("POST", { operationId: crypto.randomUUID(), cook: cook() })) }),
    );
    expect(memberShare.status).toBe(201); // the returning member occupies a working slot

    const remove = await app.handle(new Request(`https://api.test/v1/tables/${tableId}/members/${member.accountId}`, { method: "DELETE", ...authed(owner.accessToken) }));
    expect(remove.status).toBe(204); // 015fc30: owner cannot remove the returning member
    const ownerView = (await (await app.handle(new Request(`https://api.test/v1/tables/${tableId}`, { ...authed(owner.accessToken) }))).json()) as {
      members: { accountId: string }[];
    };
    expect(ownerView.members).toHaveLength(1); // the departed row does not linger as active
  });

  test("two people presenting the same unused code: exactly one claim wins (tables:346-350)", async () => {
    const app = await buildApp({ apple: stubApple, store: jitteredStore(new MemoryStore()) });
    const owner = await signUp(app, "sub-gp-race-owner", { adult: true });
    const tableId = await createTable(app, owner.accessToken);
    const mint = await app.handle(new Request(`https://api.test/v1/tables/${tableId}/invites`, { method: "POST", ...authed(owner.accessToken) }));
    const { inviteId, joinCode } = (await mint.json()) as { inviteId: string; joinCode: string };
    const first = await signUp(app, "sub-gp-race-a", { adult: true });
    const second = await signUp(app, "sub-gp-race-b", { adult: true });

    const [r1, r2] = await Promise.all([
      app.handle(new Request(`https://api.test/v1/invites/${joinCode}/join`, { method: "POST", ...authed(first.accessToken) })),
      app.handle(new Request(`https://api.test/v1/invites/${joinCode}/join`, { method: "POST", ...authed(second.accessToken) })),
    ]);
    const statuses = [r1.status, r2.status].sort();
    expect(statuses).toEqual([202, 409]); // 015fc30: [202, 202] — both overwrite the request

    // The owner approves the one real requester; nobody else is on the invite.
    const approve = await app.handle(new Request(`https://api.test/v1/tables/${tableId}/invites/${inviteId}/approve`, { method: "POST", ...authed(owner.accessToken) }));
    expect(approve.status).toBe(200);
    const winner = r1.status === 202 ? first : second;
    const loser = r1.status === 202 ? second : first;
    const winnerView = await app.handle(new Request(`https://api.test/v1/tables/${tableId}`, { ...authed(winner.accessToken) }));
    expect(winnerView.status).toBe(200);
    const loserView = await app.handle(new Request(`https://api.test/v1/tables/${tableId}`, { ...authed(loser.accessToken) }));
    expect(loserView.status).toBe(404);
  });

  test("overlapping retries with one operationId create one card and agree on the response (tables:475-481)", async () => {
    const app = await buildApp({ apple: stubApple, store: jitteredStore(new MemoryStore()) });
    const owner = await signUp(app, "sub-gp-op-owner", { adult: true });
    const tableId = await createTable(app, owner.accessToken);
    const operationId = crypto.randomUUID();
    const init = jsonInit("POST", { operationId, cook: cook() });

    const [r1, r2] = await Promise.all([
      app.handle(new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(owner.accessToken, init) })),
      app.handle(new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(owner.accessToken, init) })),
    ]);
    expect(r1.status).toBe(201);
    expect(r2.status).toBe(201);
    const id1 = ((await r1.json()) as { cardId: string }).cardId;
    const id2 = ((await r2.json()) as { cardId: string }).cardId;
    expect(id2).toBe(id1); // 015fc30: two different cards, both claiming 201

    const feed = (await (await app.handle(new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(owner.accessToken) }))).json()) as { cards: unknown[] };
    expect(feed.cards).toHaveLength(1); // 015fc30: the feed shows the duplicate
  });

  test("overlapping submissions from one account leave exactly one active entry (challenges:258-261)", async () => {
    const base = new MemoryStore();
    const { clock } = fakeClock(T0);
    const app = await buildApp({ apple: stubApple, store: jitteredStore(base), clock });
    const challenge = await createChallengeDocument(base, {
      type: "battle",
      name: "Race test",
      brief: "b",
      opensAt: iso(clock.now().getTime() - 3600_000),
      entryClosesAt: iso(clock.now().getTime() + 48 * 3600_000),
      votingClosesAt: iso(clock.now().getTime() + 96 * 3600_000),
      resolvedItems: null,
      packId: null,
    });
    const author = await signUp(app, "sub-gp-ent-race", { adult: true });
    await publish(app, author.accessToken, { source: "user", id: "ur_1", revision: 1 });

    const enter = (note: string): Promise<Response> =>
      app.handle(
        new Request(`https://api.test/v1/challenges/${challenge.challengeId}/entries`, {
          ...authed(author.accessToken, jsonInit("POST", { operationId: crypto.randomUUID(), recipeRef: { source: "user", id: "ur_1", revision: 1 }, note })),
        }),
      );
    const [r1, r2] = await Promise.all([enter("first plating"), enter("second plating")]);
    expect(r1.status).toBe(201);
    expect(r2.status).toBe(201);

    const detail = (await (await app.handle(new Request(`https://api.test/v1/challenges/${challenge.challengeId}`, { ...authed(author.accessToken) }))).json()) as {
      challenge: { entryCount: number };
      entries: { entryId: string }[];
    };
    expect(detail.entries).toHaveLength(1); // 015fc30: two active entries
    expect(detail.challenge.entryCount).toBe(1);

    const stored = await base.collection(ENTRIES_COLLECTION).where("challengeId", challenge.challengeId).get();
    const active = stored.filter((d) => d.data !== null && d.data["removed"] !== true);
    expect(active).toHaveLength(1);
  });

  test("linking the newest published revision of a recipe enters instead of refusing (challenges:224-234)", async () => {
    const store = new MemoryStore();
    const { clock } = fakeClock(T0);
    const app = await buildApp({ apple: stubApple, store, clock });
    const challenge = await createChallengeDocument(store, {
      type: "battle",
      name: "Revision test",
      brief: "b",
      opensAt: iso(clock.now().getTime() - 3600_000),
      entryClosesAt: iso(clock.now().getTime() + 48 * 3600_000),
      votingClosesAt: iso(clock.now().getTime() + 96 * 3600_000),
      resolvedItems: null,
      packId: null,
    });
    const author = await signUp(app, "sub-gp-rev", { adult: true });
    await publish(app, author.accessToken, { source: "user", id: "ur_1", revision: 1 });
    await publish(app, author.accessToken, { source: "user", id: "ur_1", revision: 2 });

    // 015fc30: the lookup selects revision 1 and refuses with recipe_revised_offline.
    const enter = await app.handle(
      new Request(`https://api.test/v1/challenges/${challenge.challengeId}/entries`, {
        ...authed(author.accessToken, jsonInit("POST", { operationId: crypto.randomUUID(), recipeRef: { source: "user", id: "ur_1", revision: 2 } })),
      }),
    );
    expect(enter.status).toBe(201);

    // An unpublished newer revision still refuses as revised; a foreign id is quarantined.
    const newer = await app.handle(
      new Request(`https://api.test/v1/challenges/${challenge.challengeId}/entries`, {
        ...authed(author.accessToken, jsonInit("POST", { operationId: crypto.randomUUID(), recipeRef: { source: "user", id: "ur_1", revision: 3 } })),
      }),
    );
    expect(newer.status).toBe(409);
    expect(((await newer.json()) as { error: { reason?: string } }).error.reason).toBe("recipe_revised_offline");
    const foreign = await app.handle(
      new Request(`https://api.test/v1/challenges/${challenge.challengeId}/entries`, {
        ...authed(author.accessToken, jsonInit("POST", { operationId: crypto.randomUUID(), recipeRef: { source: "user", id: "ur_other", revision: 1 } })),
      }),
    );
    expect(foreign.status).toBe(403);
    expect(((await foreign.json()) as { error: { reason?: string } }).error.reason).toBe("quarantined_rights");
  });

  test("entryCount counts only entries the viewer can see, on list and detail (challenges:188)", async () => {
    const store = new MemoryStore();
    const { clock } = fakeClock(T0);
    const app = await buildApp({ apple: stubApple, store, clock });
    const challenge = await createChallengeDocument(store, {
      type: "battle",
      name: "Count test",
      brief: "b",
      opensAt: iso(clock.now().getTime() - 3600_000),
      entryClosesAt: iso(clock.now().getTime() + 48 * 3600_000),
      votingClosesAt: iso(clock.now().getTime() + 96 * 3600_000),
      resolvedItems: null,
      packId: null,
    });
    const viewer = await signUp(app, "sub-gp-count-v", { adult: true });
    const op = await withOperator(app, "sub-gp-op3");
    const authorA = await signUp(app, "sub-gp-count-a", { adult: true });
    const authorB = await signUp(app, "sub-gp-count-b", { adult: true });
    const authorC = await signUp(app, "sub-gp-count-c", { adult: true });

    await publish(app, authorA.accessToken, { source: "user", id: "ur_a", revision: 1 });
    await publish(app, authorB.accessToken, { source: "user", id: "ur_b", revision: 1 });
    const pubC = await publish(app, authorC.accessToken, { source: "user", id: "ur_c", revision: 1 });
    const enter = (token: string, recipeId: string): Promise<Response> =>
      app.handle(
        new Request(`https://api.test/v1/challenges/${challenge.challengeId}/entries`, {
          ...authed(token, jsonInit("POST", { operationId: crypto.randomUUID(), recipeRef: { source: "user", id: recipeId, revision: 1 } })),
        }),
      );
    expect((await enter(authorA.accessToken, "ur_a")).status).toBe(201);
    const entryB = (await (await enter(authorB.accessToken, "ur_b")).json()) as { entryId: string };
    expect((await enter(authorC.accessToken, "ur_c")).status).toBe(201);

    // B's entry is reported (queued case); C's publication is reported, so C's entry is in_review.
    expect(
      (await app.handle(new Request("https://api.test/v1/reports", { ...authed(viewer.accessToken, jsonInit("POST", { targetType: "challengeEntry", targetId: entryB.entryId, reason: "spam" })) })))
        .status,
    ).toBe(202);
    expect(
      (await app.handle(new Request("https://api.test/v1/reports", { ...authed(viewer.accessToken, jsonInit("POST", { targetType: "recipe", targetId: pubC, reason: "rights" })) }))).status,
    ).toBe(202);

    const list = (await (await app.handle(new Request("https://api.test/v1/challenges", { ...authed(viewer.accessToken) }))).json()) as {
      challenges: { challengeId: string; entryCount: number }[];
    };
    const listed = list.challenges.find((c) => c.challengeId === challenge.challengeId);
    expect(listed?.entryCount).toBe(1); // 015fc30: 3 — the viewer is advertised entries that vanish on open

    const detail = (await (await app.handle(new Request(`https://api.test/v1/challenges/${challenge.challengeId}`, { ...authed(viewer.accessToken) }))).json()) as {
      challenge: { entryCount: number };
      entries: unknown[];
    };
    expect(detail.entries).toHaveLength(1);
    expect(detail.challenge.entryCount).toBe(1); // 015fc30: 2 — in_review entries of others were counted

    // The author of the in_review entry still sees their own.
    const cDetail = (await (await app.handle(new Request(`https://api.test/v1/challenges/${challenge.challengeId}`, { ...authed(authorC.accessToken) }))).json()) as {
      challenge: { entryCount: number };
      entries: unknown[];
    };
    expect(cDetail.entries).toHaveLength(2);
    expect(cDetail.challenge.entryCount).toBe(2);
  });

  test("a saved entry replays after entries close instead of entries_closed (challenges:199)", async () => {
    const store = new MemoryStore();
    const { clock, advanceHours } = fakeClock(T0);
    const app = await buildApp({ apple: stubApple, store, clock });
    const challenge = await createChallengeDocument(store, {
      type: "battle",
      name: "Replay test",
      brief: "b",
      opensAt: iso(clock.now().getTime() - 3600_000),
      entryClosesAt: iso(clock.now().getTime() + 48 * 3600_000),
      votingClosesAt: iso(clock.now().getTime() + 96 * 3600_000),
      resolvedItems: null,
      packId: null,
    });
    const author = await signUp(app, "sub-gp-replay", { adult: true });
    await publish(app, author.accessToken, { source: "user", id: "ur_1", revision: 1 });
    const operationId = crypto.randomUUID();
    const init = jsonInit("POST", { operationId, recipeRef: { source: "user", id: "ur_1", revision: 1 } });
    const first = await app.handle(new Request(`https://api.test/v1/challenges/${challenge.challengeId}/entries`, { ...authed(author.accessToken, init) }));
    expect(first.status).toBe(201);
    const saved = (await first.json()) as { entryId: string };

    // Past the entry window: the retry rides the saved operationId response.
    advanceHours(50);
    const fresh = await signUp(app, "sub-gp-replay", { adult: true }); // fresh token, same account
    const replay = await app.handle(new Request(`https://api.test/v1/challenges/${challenge.challengeId}/entries`, { ...authed(fresh.accessToken, init) }));
    expect(replay.status).toBe(201); // 015fc30: 409 entries_closed
    expect(((await replay.json()) as { entryId: string }).entryId).toBe(saved.entryId);
  });
});
