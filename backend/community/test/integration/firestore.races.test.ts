/**
 * The three PR #166 overlapping-request findings plus the member-cap claim,
 * raced over real HTTP against the production app on the Firestore adapter
 * (integration tier — `bun run test:integration`). The requests are genuine
 * concurrent `fetch` calls into Bun.serve: both handlers run in the server at
 * the same time (the in-flight probe below asserts that), and the two
 * emulator round trips each request makes mean their transactions genuinely
 * interleave at the emulator. Each test asserts the single outcome the
 * finding demands — one 202 invite claim, one active entry, one card per
 * operationId, one approved member at the cap — which holds through Firestore
 * transaction conflict detection and SDK retries.
 */

import { describe, test, expect, afterAll } from "bun:test";
import { buildApp, type App } from "../../src/app.js";
import { openFirestoreStore } from "../../src/core/store/firestore.js";
import { createChallengeDocument, ENTRIES_COLLECTION } from "../../src/modules/challenges/views.js";
import type { DocumentStore } from "../../src/core/store/documentStore.js";
import type { AppleIdentityTokenClaims } from "../../src/core/appleVerify.js";
import type { Clock } from "../../src/core/time.js";

const withEmulator = process.env.FIRESTORE_EMULATOR_HOST !== undefined ? describe : describe.skip;

// Two transactions that read and then write the same document make the emulator hold one
// until it fails with "Transaction lock timeout" (firestore-debug.log); the SDK then retries.
// That wait, not the code under test, sets these tests' wall time: they ran 0.3-7.5 s on
// 2026-10-22, and bun's 5 s default failed 2 of 3 runs of this file. 30 s still catches a hang.
const CONTENDED_TIMEOUT_MS = 30_000;

const stubApple = {
  verify: async (identityToken: string, nonce: string, _nowMs: number): Promise<AppleIdentityTokenClaims> => {
    if (!identityToken.startsWith("stub-jwt-")) {
      throw new Error("rejected by Apple");
    }
    return { appleSub: identityToken.slice(9), nonce, email: "nobody@privaterelay.appleid.com" };
  },
};

const T0 = Date.UTC(2026, 9, 15, 12, 0, 0);
const iso = (ms: number): string => new Date(ms).toISOString();
const fakeClock = (startMs: number): { clock: Clock; now: () => number } => ({ clock: { now: () => new Date(startMs) }, now: () => startMs });

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

interface Served {
  readonly base: string;
  readonly app: App;
  /** Highest number of request handlers that were inside the server at once. */
  maxInFlight(): number;
  stop(): void;
}

/** Boots the real app behind a real HTTP server on an ephemeral port. */
async function serve(store: DocumentStore, clock?: Clock): Promise<Served> {
  const app = await buildApp({ apple: stubApple, store, ...(clock ? { clock } : {}) });
  let inFlight = 0;
  let max = 0;
  const server = Bun.serve({
    port: 0,
    fetch: (request) => {
      inFlight += 1;
      max = Math.max(max, inFlight);
      return app.handle(request).finally(() => {
        inFlight -= 1;
      });
    },
  });
  return { base: `http://127.0.0.1:${server.port}`, app, maxInFlight: () => max, stop: () => server.stop(true) };
}

interface HttpUser {
  readonly token: string;
  readonly accountId: string;
}

async function call(base: string, method: string, path: string, token?: string, body?: unknown): Promise<Response> {
  return fetch(`${base}/v1${path}`, {
    method,
    headers: {
      ...(token === undefined ? {} : { authorization: `Bearer ${token}` }),
      ...(body === undefined ? {} : { "content-type": "application/json" }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

async function signUp(base: string, sub: string): Promise<HttpUser> {
  const response = await call(base, "POST", "/auth/apple", undefined, { identityToken: `stub-jwt-${sub}`, nonce: crypto.randomUUID(), attest18Plus: { birthYear: 1990 } });
  expect(response.status).toBe(200);
  const data = (await response.json()) as { accessToken: string; account: { accountId: string } };
  return { token: data.accessToken, accountId: data.account.accountId };
}

async function createTable(base: string, token: string): Promise<string> {
  const created = await call(base, "POST", "/tables", token, { name: "Sunday crew" });
  expect(created.status).toBe(201);
  return ((await created.json()) as { tableId: string }).tableId;
}

async function mintInvite(base: string, token: string, tableId: string): Promise<{ inviteId: string; joinCode: string }> {
  const minted = await call(base, "POST", `/tables/${tableId}/invites`, token, {});
  expect(minted.status).toBe(201);
  return (await minted.json()) as { inviteId: string; joinCode: string };
}

async function publish(base: string, token: string, recipeId: string): Promise<string> {
  const published = await call(base, "POST", "/publications", token, {
    operationId: crypto.randomUUID(),
    recipeRef: { source: "user", id: recipeId, revision: 1 },
    content: cleanRecipe,
    declaration: { ownRights: true, noPersonalData: true },
  });
  expect(published.status).toBe(201);
  return ((await published.json()) as { publicationId: string }).publicationId;
}

withEmulator("community races over HTTP on Firestore", () => {
  // A fresh project id per run: the emulator persists data, and the suites
  // assume fresh accounts and rate-limit counters.
  const runTag = Date.now().toString(36);
  const projectId = `fridgeluck-races-it-${runTag}`;
  const sub = (name: string): string => `races-${runTag}-${name}`;

  const servers: Served[] = [];
  const track = (server: Served): Served => {
    servers.push(server);
    return server;
  };
  afterAll(() => {
    for (const server of servers) {
      server.stop();
    }
  });

  test("two people presenting the same unused code over HTTP: exactly one request is accepted (tables:346-350)", async () => {
    const store = await openFirestoreStore(projectId);
    const server = track(await serve(store));
    const owner = await signUp(server.base, sub("join-owner"));
    const tableId = await createTable(server.base, owner.token);
    const { inviteId, joinCode } = await mintInvite(server.base, owner.token, tableId);
    const first = await signUp(server.base, sub("join-a"));
    const second = await signUp(server.base, sub("join-b"));

    // Both joiners are inside the server at the same time; their claim
    // transactions interleave at the emulator.
    const [r1, r2] = await Promise.all([
      call(server.base, "POST", `/invites/${joinCode}/join`, first.token, {}),
      call(server.base, "POST", `/invites/${joinCode}/join`, second.token, {}),
    ]);
    expect(server.maxInFlight()).toBeGreaterThanOrEqual(2);
    const statuses = [r1.status, r2.status].sort();
    expect(statuses).toEqual([202, 409]); // 015fc30: [202, 202] — both overwrite the request

    const winner = r1.status === 202 ? first : second;
    const loser = r1.status === 202 ? second : first;
    const approve = await call(server.base, "POST", `/tables/${tableId}/invites/${inviteId}/approve`, owner.token, {});
    expect(approve.status).toBe(200);
    const winnerView = await call(server.base, "GET", `/tables/${tableId}`, winner.token);
    expect(winnerView.status).toBe(200);
    const loserView = await call(server.base, "GET", `/tables/${tableId}`, loser.token);
    expect(loserView.status).toBe(404);
  }, CONTENDED_TIMEOUT_MS);

  test("two concurrent entries from one account over HTTP: exactly one active entry (challenges:258-261)", async () => {
    const store = await openFirestoreStore(projectId);
    const { clock } = fakeClock(T0);
    const challenge = await createChallengeDocument(store, {
      type: "battle",
      name: "HTTP race",
      brief: "b",
      opensAt: iso(clock.now().getTime() - 3600_000),
      entryClosesAt: iso(clock.now().getTime() + 48 * 3600_000),
      votingClosesAt: iso(clock.now().getTime() + 96 * 3600_000),
      resolvedItems: null,
      packId: null,
    });
    const server = track(await serve(store, clock));
    const author = await signUp(server.base, sub("entry-author"));
    await publish(server.base, author.token, "ur_1");

    const enter = (note: string): Promise<Response> =>
      call(server.base, "POST", `/challenges/${challenge.challengeId}/entries`, author.token, {
        operationId: crypto.randomUUID(),
        recipeRef: { source: "user", id: "ur_1", revision: 1 },
        note,
      });
    const [r1, r2] = await Promise.all([enter("first plating"), enter("second plating")]);
    expect(server.maxInFlight()).toBeGreaterThanOrEqual(2);
    expect(r1.status).toBe(201);
    expect(r2.status).toBe(201);

    const detail = (await (await call(server.base, "GET", `/challenges/${challenge.challengeId}`, author.token)).json()) as {
      challenge: { entryCount: number };
      entries: { entryId: string }[];
    };
    expect(detail.entries).toHaveLength(1); // 015fc30: two active entries
    expect(detail.challenge.entryCount).toBe(1);

    const stored = await store.collection(ENTRIES_COLLECTION).where("challengeId", challenge.challengeId).get();
    const active = stored.filter((d) => d.data !== null && d.data["removed"] !== true);
    expect(active).toHaveLength(1);
  }, CONTENDED_TIMEOUT_MS);

  test("two concurrent card retries with one operationId over HTTP: one card, same saved response (tables:475-481)", async () => {
    const store = await openFirestoreStore(projectId);
    const server = track(await serve(store));
    const owner = await signUp(server.base, sub("card-owner"));
    const tableId = await createTable(server.base, owner.token);
    const operationId = crypto.randomUUID();
    const body = { operationId, cook: cook() };

    const [r1, r2] = await Promise.all([
      call(server.base, "POST", `/tables/${tableId}/cards`, owner.token, body),
      call(server.base, "POST", `/tables/${tableId}/cards`, owner.token, body),
    ]);
    expect(server.maxInFlight()).toBeGreaterThanOrEqual(2);
    expect(r1.status).toBe(201);
    expect(r2.status).toBe(201);
    const id1 = ((await r1.json()) as { cardId: string }).cardId;
    const id2 = ((await r2.json()) as { cardId: string }).cardId;
    expect(id2).toBe(id1); // 015fc30: two different cards, both claiming 201

    const feed = (await (await call(server.base, "GET", `/tables/${tableId}/cards`, owner.token)).json()) as { cards: { cardId: string }[] };
    expect(feed.cards).toHaveLength(1); // 015fc30: the feed shows the duplicate
  }, CONTENDED_TIMEOUT_MS);

  test("two concurrent approvals at the member cap over HTTP: exactly one claims the last slot (table cap)", async () => {
    const store = await openFirestoreStore(projectId);
    const server = track(await serve(store));
    const owner = await signUp(server.base, sub("cap-owner"));
    const tableId = await createTable(server.base, owner.token);

    // Owner + 6 members = 7; the cap is 8, so exactly one slot remains.
    const joiners: HttpUser[] = [];
    for (let i = 0; i < 8; i += 1) {
      joiners.push(await signUp(server.base, sub(`cap-joiner-${i}`)));
    }
    for (let i = 0; i < 6; i += 1) {
      const { inviteId, joinCode } = await mintInvite(server.base, owner.token, tableId);
      const joined = await call(server.base, "POST", `/invites/${joinCode}/join`, joiners[i]?.token, {});
      expect(joined.status).toBe(202);
      const approved = await call(server.base, "POST", `/tables/${tableId}/invites/${inviteId}/approve`, owner.token, {});
      expect(approved.status).toBe(200);
    }

    // The last two joiners present their codes (sequential: each claims its own
    // invite pending slot), then the owner approves both invites at once.
    const lastInvites = [await mintInvite(server.base, owner.token, tableId), await mintInvite(server.base, owner.token, tableId)];
    for (let i = 0; i < 2; i += 1) {
      const joined = await call(server.base, "POST", `/invites/${lastInvites[i]?.joinCode}/join`, joiners[6 + i]?.token, {});
      expect(joined.status).toBe(202);
    }
    const [a1, a2] = await Promise.all([
      call(server.base, "POST", `/tables/${tableId}/invites/${lastInvites[0]?.inviteId}/approve`, owner.token, {}),
      call(server.base, "POST", `/tables/${tableId}/invites/${lastInvites[1]?.inviteId}/approve`, owner.token, {}),
    ]);
    expect(server.maxInFlight()).toBeGreaterThanOrEqual(2);
    const statuses = [a1.status, a2.status].sort();
    expect(statuses).toEqual([200, 409]); // one member takes the last slot; table_full for the other

    const view = (await (await call(server.base, "GET", `/tables/${tableId}`, owner.token)).json()) as { members: { accountId: string }[] };
    expect(view.members).toHaveLength(8); // owner + 7, not 9 — the loser never became a member
  }, CONTENDED_TIMEOUT_MS);
});
