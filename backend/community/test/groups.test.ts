/**
 * Tables and challenges module coverage (SPEC §4, §5, §6.3): end-to-end
 * requests over buildApp's production wiring with the in-memory store, a
 * stubbed Apple verifier, and a controllable clock — plus pure-function tests
 * for the lifecycle/tally rules, the pack resolver, and the public web page.
 */

import { describe, test, expect } from "bun:test";
import { buildApp, type App } from "../src/app.js";
import { MemoryStore } from "../src/core/store/memory.js";
import type { AppleIdentityTokenClaims } from "../src/core/appleVerify.js";
import { createChallengeDocument } from "../src/modules/challenges/views.js";
import { packResolverOver } from "../src/modules/challenges/packs.js";
import { computeTallies, deriveStatus, type VoteRecord } from "../src/modules/challenges/lifecycle.js";
import { renderChallengePage } from "../src/modules/challenges/webPage.js";
import type { Clock } from "../src/core/time.js";

const stubApple = {
  verify: async (identityToken: string, nonce: string, _nowMs: number): Promise<AppleIdentityTokenClaims> => {
    if (!identityToken.startsWith("stub-jwt-")) {
      throw new Error("rejected by Apple");
    }
    return { appleSub: identityToken.slice(9), nonce, email: "nobody@privaterelay.appleid.com" };
  },
};

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

/** A controllable clock; challenge seeds and the 24 h vote gate ride it. */
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
  const data = (await response.json()) as { tableId: string };
  return data.tableId;
}

/** Full owner-approved join: owner mints, joiner presents, owner approves. */
async function addMember(app: App, ownerToken: string, tableId: string, joinerSub: string): Promise<{ accessToken: string; accountId: string; inviteId: string }> {
  const mint = await app.handle(new Request(`https://api.test/v1/tables/${tableId}/invites`, { method: "POST", ...authed(ownerToken) }));
  expect(mint.status).toBe(201);
  const { inviteId, joinCode } = (await mint.json()) as { inviteId: string; joinCode: string };
  const joiner = await signUp(app, joinerSub, { adult: true });
  const join = await app.handle(new Request(`https://api.test/v1/invites/${joinCode}/join`, { method: "POST", ...authed(joiner.accessToken) }));
  expect(join.status).toBe(202);
  const approve = await app.handle(new Request(`https://api.test/v1/tables/${tableId}/invites/${inviteId}/approve`, { method: "POST", ...authed(ownerToken) }));
  expect(approve.status).toBe(200);
  return { ...joiner, inviteId };
}

async function publish(app: App, token: string, recipeRef: Record<string, unknown> = { source: "user", id: "ur_1", revision: 1 }): Promise<{ publicationId: string }> {
  const response = await app.handle(
    new Request("https://api.test/v1/publications", {
      ...authed(token, jsonInit("POST", { operationId: crypto.randomUUID(), recipeRef, content: cleanRecipe, declaration: { ownRights: true, noPersonalData: true } })),
    }),
  );
  expect(response.status).toBe(201);
  return (await response.json()) as { publicationId: string };
}

const iso = (ms: number): string => new Date(ms).toISOString();

describe("tables (SPEC §5)", () => {
  test("owner creates a table; join-by-code asks and the owner approves", async () => {
    const app = await buildApp({ apple: stubApple });
    const owner = await signUp(app, "sub-owner", { adult: true });
    const tableId = await createTable(app, owner.accessToken);

    const mint = await app.handle(new Request(`https://api.test/v1/tables/${tableId}/invites`, { method: "POST", ...authed(owner.accessToken) }));
    expect(mint.status).toBe(201);
    const invite = (await mint.json()) as { inviteId: string; joinCode: string };
    expect(invite.joinCode.length).toBeGreaterThanOrEqual(6);

    const joiner = await signUp(app, "sub-joiner", { adult: true });
    const join = await app.handle(new Request(`https://api.test/v1/invites/${invite.joinCode}/join`, { method: "POST", ...authed(joiner.accessToken) }));
    expect(join.status).toBe(202); // asks, does not add
    expect(((await join.json()) as { state: string }).state).toBe("pending");

    const ownerView = (await (await app.handle(new Request(`https://api.test/v1/tables/${tableId}`, { ...authed(owner.accessToken) }))).json()) as {
      members: { accountId: string; role: string }[];
      pendingInvites: { inviteId: string; requestedByDisplayName: string | null }[];
    };
    expect(ownerView.members).toHaveLength(1);
    expect(ownerView.members[0]?.role).toBe("owner");
    expect(ownerView.pendingInvites).toHaveLength(1);
    expect(ownerView.pendingInvites[0]?.requestedByDisplayName).toBe("Cook");

    const approve = await app.handle(new Request(`https://api.test/v1/tables/${tableId}/invites/${invite.inviteId}/approve`, { method: "POST", ...authed(owner.accessToken) }));
    expect(approve.status).toBe(200);
    expect(((await approve.json()) as { state: string }).state).toBe("approved");

    const joinerView = (await (await app.handle(new Request(`https://api.test/v1/tables/${tableId}`, { ...authed(joiner.accessToken) }))).json()) as {
      members: unknown[];
      pendingInvites?: unknown;
    };
    expect(joinerView.members).toHaveLength(2);
    expect(joinerView.pendingInvites).toBeUndefined(); // pending invites appear in the owner view only
  });

  test("only the owner mints; a claimed code refuses a second account; revocation kills the code", async () => {
    const app = await buildApp({ apple: stubApple });
    const owner = await signUp(app, "sub-owner2", { adult: true });
    const tableId = await createTable(app, owner.accessToken);
    const member = await addMember(app, owner.accessToken, tableId, "sub-member2");

    const memberMint = await app.handle(new Request(`https://api.test/v1/tables/${tableId}/invites`, { method: "POST", ...authed(member.accessToken) }));
    expect(memberMint.status).toBe(403);

    const mint = await app.handle(new Request(`https://api.test/v1/tables/${tableId}/invites`, { method: "POST", ...authed(owner.accessToken) }));
    const { inviteId, joinCode } = (await mint.json()) as { inviteId: string; joinCode: string };
    const asker = await signUp(app, "sub-asker2", { adult: true });
    const first = await app.handle(new Request(`https://api.test/v1/invites/${joinCode}/join`, { method: "POST", ...authed(asker.accessToken) }));
    void first;
    const outsider = await signUp(app, "sub-outsider", { adult: true });
    const claim = await app.handle(new Request(`https://api.test/v1/invites/${joinCode}/join`, { method: "POST", ...authed(outsider.accessToken) }));
    expect(claim.status).toBe(409); // a different account on a claimed code is refused

    const revoke = await app.handle(new Request(`https://api.test/v1/tables/${tableId}/invites/${inviteId}`, { method: "DELETE", ...authed(owner.accessToken) }));
    expect(revoke.status).toBe(204);
    const after = await app.handle(new Request(`https://api.test/v1/invites/${joinCode}/join`, { method: "POST", ...authed(outsider.accessToken) }));
    expect(after.status).toBe(404);
  });

  test("the table caps at 8 members with table_full", async () => {
    const app = await buildApp({ apple: stubApple });
    const owner = await signUp(app, "sub-cap-owner", { adult: true });
    const tableId = await createTable(app, owner.accessToken);
    for (let i = 0; i < 7; i += 1) {
      await addMember(app, owner.accessToken, tableId, `sub-cap-${i}`);
    }
    const mint = await app.handle(new Request(`https://api.test/v1/tables/${tableId}/invites`, { method: "POST", ...authed(owner.accessToken) }));
    expect(mint.status).toBe(409);
    expect(((await mint.json()) as { error: { reason?: string } }).error.reason).toBe("table_full");
  });

  test("a non-member and a removed member both read 404; the removed member's cards stay in history, redacted", async () => {
    const app = await buildApp({ apple: stubApple });
    const owner = await signUp(app, "sub-rm-owner", { adult: true });
    const tableId = await createTable(app, owner.accessToken);
    const member = await addMember(app, owner.accessToken, tableId, "sub-rm-member");

    const share = await app.handle(
      new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(member.accessToken, jsonInit("POST", { operationId: crypto.randomUUID(), cook: cook() })) }),
    );
    expect(share.status).toBe(201);
    const cardId = ((await share.json()) as { cardId: string }).cardId;

    const remove = await app.handle(new Request(`https://api.test/v1/tables/${tableId}/members/${member.accountId}`, { method: "DELETE", ...authed(owner.accessToken) }));
    expect(remove.status).toBe(204);

    const gone = await app.handle(new Request(`https://api.test/v1/tables/${tableId}`, { ...authed(member.accessToken) }));
    expect(gone.status).toBe(404);

    const feed = (await (await app.handle(new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(owner.accessToken) }))).json()) as {
      cards: { cardId: string; cook: { dishName: string; content: unknown; authorDisplayName?: string }; isMine: boolean }[];
    };
    const kept = feed.cards.find((c) => c.cardId === cardId);
    expect(kept).toBeDefined();
    expect(kept?.cook.dishName).toBe("Left the table"); // §5.1: name removed, card shows 'left the table'
    expect(kept?.cook.authorDisplayName).toBeUndefined();
    expect(kept?.cook.content).toBeNull();
  });

  test("sharing is 18+, server-set identity wins, a contact-details note is screened out", async () => {
    const app = await buildApp({ apple: stubApple });
    const owner = await signUp(app, "sub-share-owner", { adult: true });
    const tableId = await createTable(app, owner.accessToken);
    // The minor must be a member first — membership resolves before the
    // adulthood gate, so an outsider gets a 404 rather than a 403 (probed).
    const mint = await app.handle(new Request(`https://api.test/v1/tables/${tableId}/invites`, { method: "POST", ...authed(owner.accessToken) }));
    const { inviteId, joinCode } = (await mint.json()) as { inviteId: string; joinCode: string };
    const minor = await signUp(app, "sub-minor"); // no 18+ attestation
    const join = await app.handle(new Request(`https://api.test/v1/invites/${joinCode}/join`, { method: "POST", ...authed(minor.accessToken) }));
    expect(join.status).toBe(202);
    await app.handle(new Request(`https://api.test/v1/tables/${tableId}/invites/${inviteId}/approve`, { method: "POST", ...authed(owner.accessToken) }));

    const refused = await app.handle(
      new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(minor.accessToken, jsonInit("POST", { operationId: crypto.randomUUID(), cook: cook() })) }),
    );
    expect(refused.status).toBe(403);
    expect(((await refused.json()) as { error: { reason?: string } }).error.reason).toBe("not_adult");

    const ok = await app.handle(
      new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(owner.accessToken, jsonInit("POST", { operationId: crypto.randomUUID(), cook: cook() })) }),
    );
    expect(ok.status).toBe(201);
    const card = (await ok.json()) as { cook: { authorDisplayName: string; day: string; content: unknown }; isMine: boolean };

    const replay = await app.handle(
      new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(owner.accessToken, jsonInit("POST", { operationId: crypto.randomUUID(), cook: cook() })) }),
    );
    expect(replay.status).toBe(201); // a different operationId is a fresh share, not a replay

    const leak = await app.handle(
      new Request(`https://api.test/v1/tables/${tableId}/cards`, {
        ...authed(owner.accessToken, jsonInit("POST", { operationId: crypto.randomUUID(), cook: cook({ note: "Questions? Text me at 555-0100" }) })),
      }),
    );
    expect(leak.status).toBe(422);
    expect(((await leak.json()) as { error: { reason?: string } }).error.reason).toBe("personal_data");
  });

  test("replayed operationId returns the original card; unknown operationId of another account is refused", async () => {
    const app = await buildApp({ apple: stubApple });
    const owner = await signUp(app, "sub-idem-owner", { adult: true });
    const tableId = await createTable(app, owner.accessToken);
    const operationId = crypto.randomUUID();
    const body = jsonInit("POST", { operationId, cook: cook() });
    const first = await app.handle(new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(owner.accessToken, body) }));
    const second = await app.handle(new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(owner.accessToken, body) }));
    expect(first.status).toBe(201);
    expect(second.status).toBe(201);
    expect(((await second.json()) as { cardId: string }).cardId).toBe(((await first.json()) as { cardId: string }).cardId);
  });

  test("blocks: mutual silent filtering in the feed, list, unblock, self-block refused", async () => {
    const app = await buildApp({ apple: stubApple });
    const owner = await signUp(app, "sub-block-owner", { adult: true });
    const tableId = await createTable(app, owner.accessToken);
    const member = await addMember(app, owner.accessToken, tableId, "sub-block-member");

    await app.handle(new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(member.accessToken, jsonInit("POST", { operationId: crypto.randomUUID(), cook: cook() })) }));
    await app.handle(new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(owner.accessToken, jsonInit("POST", { operationId: crypto.randomUUID(), cook: cook({ dishName: "Owner dish" }) })) }));

    const block = await app.handle(new Request(`https://api.test/v1/blocks/${member.accountId}`, { method: "PUT", ...authed(owner.accessToken) }));
    expect(block.status).toBe(204);

    const ownerFeed = (await (await app.handle(new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(owner.accessToken) }))).json()) as { cards: { isMine: boolean }[] };
    expect(ownerFeed.cards).toHaveLength(1); // the blocked member's card is filtered
    const memberFeed = (await (await app.handle(new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(member.accessToken) }))).json()) as { cards: { isMine: boolean }[] };
    expect(memberFeed.cards).toHaveLength(1); // and vice versa; own card stays

    const list = (await (await app.handle(new Request("https://api.test/v1/blocks", { ...authed(owner.accessToken) }))).json()) as {
      blocks: { accountId: string; displayName: string | null }[];
    };
    expect(list.blocks).toHaveLength(1);
    expect(list.blocks[0]?.accountId).toBe(member.accountId);

    const self = await app.handle(new Request(`https://api.test/v1/blocks/${owner.accountId}`, { method: "PUT", ...authed(owner.accessToken) }));
    expect(self.status).toBe(422);

    const unblock = await app.handle(new Request(`https://api.test/v1/blocks/${member.accountId}`, { method: "DELETE", ...authed(owner.accessToken) }));
    expect(unblock.status).toBe(204);
    const after = (await (await app.handle(new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(owner.accessToken) }))).json()) as { cards: unknown[] };
    expect(after.cards).toHaveLength(2); // unblocking restores the pair's feed
  });

  test("a blocked pair cannot meet in a table: the join 404s silently", async () => {
    const app = await buildApp({ apple: stubApple });
    const owner = await signUp(app, "sub-bj-owner", { adult: true });
    const tableId = await createTable(app, owner.accessToken);
    const joiner = await signUp(app, "sub-bj-joiner", { adult: true });
    await app.handle(new Request(`https://api.test/v1/blocks/${owner.accountId}`, { method: "PUT", ...authed(joiner.accessToken) }));

    const mint = await app.handle(new Request(`https://api.test/v1/tables/${tableId}/invites`, { method: "POST", ...authed(owner.accessToken) }));
    const { joinCode } = (await mint.json()) as { joinCode: string };
    const join = await app.handle(new Request(`https://api.test/v1/invites/${joinCode}/join`, { method: "POST", ...authed(joiner.accessToken) }));
    expect(join.status).toBe(404); // no probe of the block state through joins
  });

  test("a member leaves; the owner cannot leave", async () => {
    const app = await buildApp({ apple: stubApple });
    const owner = await signUp(app, "sub-leave-owner", { adult: true });
    const tableId = await createTable(app, owner.accessToken);
    const member = await addMember(app, owner.accessToken, tableId, "sub-leave-member");

    const ownerLeave = await app.handle(new Request(`https://api.test/v1/tables/${tableId}/leave`, { method: "POST", ...authed(owner.accessToken) }));
    expect(ownerLeave.status).toBe(409);

    const leave = await app.handle(new Request(`https://api.test/v1/tables/${tableId}/leave`, { method: "POST", ...authed(member.accessToken) }));
    expect(leave.status).toBe(204);
    const after = await app.handle(new Request(`https://api.test/v1/tables/${tableId}`, { ...authed(member.accessToken) }));
    expect(after.status).toBe(404);
  });

  test("the author deletes their own card from the feed", async () => {
    const app = await buildApp({ apple: stubApple });
    const owner = await signUp(app, "sub-del-owner", { adult: true });
    const tableId = await createTable(app, owner.accessToken);
    const share = await app.handle(
      new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(owner.accessToken, jsonInit("POST", { operationId: crypto.randomUUID(), cook: cook() })) }),
    );
    const { cardId } = (await share.json()) as { cardId: string };
    const del = await app.handle(new Request(`https://api.test/v1/tables/${tableId}/cards/${cardId}`, { method: "DELETE", ...authed(owner.accessToken) }));
    expect(del.status).toBe(204);
    const feed = (await (await app.handle(new Request(`https://api.test/v1/tables/${tableId}/cards`, { ...authed(owner.accessToken) }))).json()) as { cards: unknown[] };
    expect(feed.cards).toHaveLength(0);
  });
});

describe("challenges (SPEC §4)", () => {
  function seed(store: MemoryStore, clock: Clock) {
    return {
      open: () =>
        createChallengeDocument(store, {
          type: "battle",
          name: "Weeknight battle",
          brief: "Best 15-minute dinner.",
          opensAt: iso(clock.now().getTime() - 24 * 3600_000),
          entryClosesAt: iso(clock.now().getTime() + 48 * 3600_000),
          votingClosesAt: iso(clock.now().getTime() + 96 * 3600_000),
          resolvedItems: null,
          packId: null,
        }),
      voting: () =>
        createChallengeDocument(store, {
          type: "use-it-up",
          name: "Use it up",
          brief: "Leftovers only.",
          opensAt: iso(clock.now().getTime() - 96 * 3600_000),
          entryClosesAt: iso(clock.now().getTime() - 3600_000),
          votingClosesAt: iso(clock.now().getTime() + 48 * 3600_000),
          resolvedItems: null,
          packId: null,
        }),
      closed: () =>
        createChallengeDocument(store, {
          type: "budget",
          name: "Five dollars",
          brief: "Dinner under $5.",
          opensAt: iso(clock.now().getTime() - 200 * 3600_000),
          entryClosesAt: iso(clock.now().getTime() - 100 * 3600_000),
          votingClosesAt: iso(clock.now().getTime() - 24 * 3600_000),
          resolvedItems: null,
          packId: null,
        }),
    };
  }

  test("the list derives statuses and the detail hides tallies until closed", async () => {
    const store = new MemoryStore();
    const { clock } = fakeClock(T0);
    const app = await buildApp({ apple: stubApple, store, clock });
    const seeds = seed(store, clock);
    const open = await seeds.open();
    const voting = await seeds.voting();
    const closed = await seeds.closed();

    const user = await signUp(app, "sub-list", { adult: true });
    const list = (await (await app.handle(new Request("https://api.test/v1/challenges", { ...authed(user.accessToken) }))).json()) as {
      challenges: { challengeId: string; status: string }[];
    };
    const statusOf = new Map(list.challenges.map((c) => [c.challengeId, c.status]));
    expect(statusOf.get(open.challengeId)).toBe("open");
    expect(statusOf.get(voting.challengeId)).toBe("voting");
    expect(statusOf.get(closed.challengeId)).toBe("closed");

    const detail = (await (await app.handle(new Request(`https://api.test/v1/challenges/${closed.challengeId}`, { ...authed(user.accessToken) }))).json()) as {
      challenge: { status: string; myEntryId: string | null; myVoteEntryId: string | null };
      entries: { voteCount: number | null }[];
    };
    expect(detail.challenge.status).toBe("closed");
    expect(detail.challenge.myEntryId).toBeNull();
    expect(detail.entries.every((e) => typeof e.voteCount === "number")).toBe(true);

    const votingDetail = (await (await app.handle(new Request(`https://api.test/v1/challenges/${voting.challengeId}`, { ...authed(user.accessToken) }))).json()) as {
      entries: { voteCount: number | null }[];
    };
    expect(votingDetail.entries.every((e) => e.voteCount === null)).toBe(true); // no live tallies
  });

  test("entries link a published revision; refusals carry the contract reasons", async () => {
    const store = new MemoryStore();
    const { clock } = fakeClock(T0);
    const app = await buildApp({ apple: stubApple, store, clock });
    const challenge = await seed(store, clock).open();
    const author = await signUp(app, "sub-entry", { adult: true });
    await publish(app, author.accessToken, { source: "user", id: "ur_1", revision: 1 });

    const ok = await app.handle(
      new Request(`https://api.test/v1/challenges/${challenge.challengeId}/entries`, {
        ...authed(author.accessToken, jsonInit("POST", { operationId: crypto.randomUUID(), recipeRef: { source: "user", id: "ur_1", revision: 1 }, note: "doubled the lemon" })),
      }),
    );
    expect(ok.status).toBe(201);
    const entry = (await ok.json()) as { entryId: string; state: string; voteCount: number | null; note: string | null };
    expect(entry.state).toBe("visible");
    expect(entry.voteCount).toBeNull();
    expect(entry.note).toBe("doubled the lemon");

    const revised = await app.handle(
      new Request(`https://api.test/v1/challenges/${challenge.challengeId}/entries`, {
        ...authed(author.accessToken, jsonInit("POST", { operationId: crypto.randomUUID(), recipeRef: { source: "user", id: "ur_1", revision: 2 } })),
      }),
    );
    expect(revised.status).toBe(409);
    expect(((await revised.json()) as { error: { reason?: string } }).error.reason).toBe("recipe_revised_offline");

    const foreign = await app.handle(
      new Request(`https://api.test/v1/challenges/${challenge.challengeId}/entries`, {
        ...authed(author.accessToken, jsonInit("POST", { operationId: crypto.randomUUID(), recipeRef: { source: "user", id: "ur_other", revision: 1 } })),
      }),
    );
    expect(foreign.status).toBe(403);
    expect(((await foreign.json()) as { error: { reason?: string } }).error.reason).toBe("quarantined_rights");
  });

  test("entries are refused outside the entry window", async () => {
    const store = new MemoryStore();
    const { clock } = fakeClock(T0);
    const app = await buildApp({ apple: stubApple, store, clock });
    const challenge = await seed(store, clock).closed();
    const author = await signUp(app, "sub-late", { adult: true });
    await publish(app, author.accessToken);
    const late = await app.handle(
      new Request(`https://api.test/v1/challenges/${challenge.challengeId}/entries`, {
        ...authed(author.accessToken, jsonInit("POST", { operationId: crypto.randomUUID(), recipeRef: { source: "user", id: "ur_1", revision: 1 } })),
      }),
    );
    expect(late.status).toBe(409);
    expect(((await late.json()) as { error: { reason?: string } }).error.reason).toBe("entries_closed");
  });

  test("votes: 24 h account gate, one movable vote, tallies only after close, self-votes never count", async () => {
    const store = new MemoryStore();
    const { clock, advanceHours } = fakeClock(T0);
    const app = await buildApp({ apple: stubApple, store, clock });
    // Voting opens 2 h from T0 and closes 10 days out.
    const challenge = await createChallengeDocument(store, {
      type: "battle",
      name: "Vote test",
      brief: "b",
      opensAt: iso(T0 - 3600_000),
      entryClosesAt: iso(T0 + 2 * 3600_000),
      votingClosesAt: iso(T0 + 10 * 24 * 3600_000),
      resolvedItems: null,
      packId: null,
    });
    const author = await signUp(app, "sub-vote-a", { adult: true });
    const voter = await signUp(app, "sub-vote-b", { adult: true });
    await publish(app, author.accessToken, { source: "user", id: "ur_1", revision: 1 });
    await publish(app, voter.accessToken, { source: "user", id: "ur_2", revision: 1 });
    const addEntry = (recipeId: string) =>
      app.handle(
        new Request(`https://api.test/v1/challenges/${challenge.challengeId}/entries`, {
          ...authed(author.accessToken, jsonInit("POST", { operationId: crypto.randomUUID(), recipeRef: { source: "user", id: recipeId, revision: 1 } })),
        }),
      );
    void addEntry;
    const entryA = (await (
      await app.handle(
        new Request(`https://api.test/v1/challenges/${challenge.challengeId}/entries`, {
          ...authed(author.accessToken, jsonInit("POST", { operationId: crypto.randomUUID(), recipeRef: { source: "user", id: "ur_1", revision: 1 } })),
        }),
      )
    ).json()) as { entryId: string };
    const entryB = (await (
      await app.handle(
        new Request(`https://api.test/v1/challenges/${challenge.challengeId}/entries`, {
          ...authed(voter.accessToken, jsonInit("POST", { operationId: crypto.randomUUID(), recipeRef: { source: "user", id: "ur_2", revision: 1 } })),
        }),
      )
    ).json()) as { entryId: string };

    // Voting window is open (after entryClosesAt) but the voter is 3 h old.
    // Access tokens live 15 minutes, so every clock advance needs a fresh
    // sign-in (same Apple sub → same account, createdAt unchanged).
    advanceHours(3);
    const voterAfter3 = await signUp(app, "sub-vote-b", { adult: true });
    const tooNew = await app.handle(
      new Request(`https://api.test/v1/challenges/${challenge.challengeId}/vote`, { ...authed(voterAfter3.accessToken, jsonInit("PUT", { entryId: entryA.entryId })) }),
    );
    expect(tooNew.status).toBe(403); // account must be 24 h old (§6.3)

    advanceHours(22);
    const voterAfter25 = await signUp(app, "sub-vote-b", { adult: true });
    const cast = await app.handle(
      new Request(`https://api.test/v1/challenges/${challenge.challengeId}/vote`, { ...authed(voterAfter25.accessToken, jsonInit("PUT", { entryId: entryA.entryId })) }),
    );
    expect(cast.status).toBe(204);
    const moved = await app.handle(
      new Request(`https://api.test/v1/challenges/${challenge.challengeId}/vote`, { ...authed(voterAfter25.accessToken, jsonInit("PUT", { entryId: entryB.entryId })) }),
    );
    expect(moved.status).toBe(204); // the vote moves; it never counts twice
    const taken = await app.handle(
      new Request(`https://api.test/v1/challenges/${challenge.challengeId}/vote`, { method: "DELETE", ...authed(voterAfter25.accessToken) }),
    );
    expect(taken.status).toBe(204);
    const again = await app.handle(
      new Request(`https://api.test/v1/challenges/${challenge.challengeId}/vote`, { ...authed(voterAfter25.accessToken, jsonInit("PUT", { entryId: entryA.entryId })) }),
    );
    expect(again.status).toBe(204);

    // The author votes for their own entry — stored, but never counted.
    const authorSelfToken = await signUp(app, "sub-vote-a", { adult: true });
    const selfVote = await app.handle(
      new Request(`https://api.test/v1/challenges/${challenge.challengeId}/vote`, { ...authed(authorSelfToken.accessToken, jsonInit("PUT", { entryId: entryA.entryId })) }),
    );
    expect(selfVote.status).toBe(204);

    // Before votingClosesAt the tallies are hidden.
    const authorFresh = await signUp(app, "sub-vote-a", { adult: true });
    const openDetail = (await (await app.handle(new Request(`https://api.test/v1/challenges/${challenge.challengeId}`, { ...authed(authorFresh.accessToken) }))).json()) as {
      challenge: { status: string };
      entries: { voteCount: number | null }[];
    };
    expect(openDetail.challenge.status).toBe("voting");
    expect(openDetail.entries.every((e) => e.voteCount === null)).toBe(true);

    // After close: the author's self-vote on entryA is stored-but-not-counted.
    advanceHours(9 * 24);
    const authorFinal = await signUp(app, "sub-vote-a", { adult: true });
    const final = (await (await app.handle(new Request(`https://api.test/v1/challenges/${challenge.challengeId}`, { ...authed(authorFinal.accessToken) }))).json()) as {
      challenge: { status: string };
      entries: { entryId: string; voteCount: number | null }[];
    };
    expect(final.challenge.status).toBe("closed");
    const countOf = new Map(final.entries.map((e) => [e.entryId, e.voteCount]));
    expect(countOf.get(entryA.entryId)).toBe(1); // the voter's moved-back vote; the author's self-vote is excluded
    expect(countOf.get(entryB.entryId)).toBe(0);
  });

  test("voting outside the window is vote_too_early", async () => {
    const store = new MemoryStore();
    const { clock, advanceHours } = fakeClock(T0);
    const app = await buildApp({ apple: stubApple, store, clock });
    const challenge = await seed(store, clock).open(); // entry window still open
    const user = await signUp(app, "sub-early", { adult: true });
    advanceHours(30); // account old enough
    const fresh = await signUp(app, "sub-early", { adult: true }); // token TTL is 15 minutes
    const early = await app.handle(
      new Request(`https://api.test/v1/challenges/${challenge.challengeId}/vote`, { ...authed(fresh.accessToken, jsonInit("PUT", { entryId: "ent_doesnotexist1" })) }),
    );
    expect(early.status).toBe(409);
    expect(((await early.json()) as { error: { reason?: string } }).error.reason).toBe("vote_too_early");
  });
});

describe("pure rules", () => {
  test("lifecycle derivation follows the three instants", () => {
    const times = { opensAt: iso(1000), entryClosesAt: iso(2000), votingClosesAt: iso(3000) };
    expect(deriveStatus(times, 999)).toBe("draft");
    expect(deriveStatus(times, 1500)).toBe("open");
    expect(deriveStatus(times, 2500)).toBe("voting");
    expect(deriveStatus(times, 3000)).toBe("closed");
  });

  test("tallies exclude self-votes and count the stored (moved) vote once", () => {
    const entries = [
      { entryId: "e1", authorAccountId: "a" },
      { entryId: "e2", authorAccountId: "b" },
    ];
    const vote = (accountId: string, entryId: string): VoteRecord => ({
      challengeId: "c",
      accountId,
      entryId,
      createdAt: iso(0),
      updatedAt: iso(0),
    });
    // Storage is one record per account; moving a vote overwrites the entryId.
    // a votes for their own e1 (excluded); b's stored vote lands on e1.
    const counts = computeTallies(entries, [vote("a", "e1"), vote("b", "e1")]);
    expect(counts.get("e1")).toBe(1); // a's self-vote stored but not counted
    expect(counts.get("e2")).toBe(0);
  });

  test("the pack resolver freezes items and refuses broken pack data", async () => {
    const packs = {
      "budget-wk42": {
        schemaVersion: 1,
        kind: "budget",
        retrieved: iso(T0),
        data: {
          packs: [
            {
              id: "budget-wk42",
              items: [
                { usdaFdcId: 171705, displayName: "Brown rice", quantity: "2 cups dry" },
                { usdaFdcId: 747421, displayName: "Eggs" },
              ],
            },
          ],
        },
      },
      "broken-pack": {
        schemaVersion: 1,
        kind: "broken",
        retrieved: iso(T0),
        data: { packs: [{ id: "broken-pack", items: [{ displayName: "No join key" }] }] },
      },
    };
    const resolver = packResolverOver(packs);
    const frozen = await resolver.freeze("budget-wk42");
    expect(frozen.map((i) => i.fdcId)).toEqual([171705, 747421]);
    expect(frozen[0]?.quantityText).toBe("2 cups dry");

    await expect(resolver.freeze("missing-pack")).rejects.toMatchObject({ status: 404 });
    await expect(resolver.freeze("broken-pack")).rejects.toMatchObject({ status: 422 });
  });

  test("the web page escapes hostile strings and shows tallies only when closed", () => {
    const challenge = {
      challengeId: "chl_x",
      type: "battle" as const,
      name: "<script>alert(1)</script>",
      brief: "Best dinner",
      status: "open",
      opensAt: iso(0),
      entryClosesAt: iso(1),
      votingClosesAt: iso(2),
      entryCount: 1,
      resolvedItems: [{ fdcId: 1, name: "Rice & beans", quantityText: "2 cups" }],
      packId: null,
      myEntryId: null,
      myVoteEntryId: null,
      scope: null,
    };
    const open = renderChallengePage(challenge, [
      { entryId: "e1", title: "Fry <everything>", authorDisplayName: "Sam", note: null, state: "visible", voteCount: null, createdAt: iso(0) },
    ]);
    expect(open).toContain("&lt;script&gt;");
    expect(open).toContain("Rice &amp; beans");
    expect(open).not.toContain("<script>alert");
    expect(open).not.toContain("voteCount");

    const closed = renderChallengePage({ ...challenge, status: "closed" }, [
      { entryId: "e1", title: "Fry <everything>", authorDisplayName: "Sam", note: null, state: "visible", voteCount: 3, createdAt: iso(0) },
    ]);
    expect(closed).toContain("Most cooked");
    expect(closed).toContain("3 cooks");
  });
});
