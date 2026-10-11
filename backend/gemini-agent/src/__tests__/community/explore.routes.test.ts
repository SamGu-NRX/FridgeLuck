/**
 * The explore part over HTTP: publication with automated screening, the
 * Explore feed with its two count floors, the human moderation queue with its
 * audit trail, author withdrawal, and blocked-pair invisibility. Runs against
 * the Firestore emulator with the REAL FirestoreModerationQueue; screening is
 * deterministic text hygiene plus injected stub stages — no LLM anywhere.
 */
import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import express from "express";
import { generateKeyPairSync, randomUUID, sign as cryptoSign, type KeyObject } from "node:crypto";
import type { Server } from "node:http";
import { makeHarness, type CommunityTestHarness } from "./harness.js";
import { createCommunityRouter, type CommunityDeps } from "../../community/index.js";
import { createIdentityRoutes } from "../../community/identity/identityRoutes.js";
import { createExploreRoutes } from "../../community/explore/exploreRoutes.js";
import { FirestoreModerationQueue } from "../../community/explore/moderationQueue.js";
import { stubBlockDirectory, stubScreeningFail } from "../../community/shared/testing/stubs.js";

const KID = "test-key-1";
const APPLE_ISSUER = "https://appleid.apple.com";
const SERVICES_ID = "com.fridgeluck.app.test";

const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const publicJwk = { ...(publicKey.export({ format: "jwk" }) as { kty: string; n: string; e: string }), kid: KID, alg: "RS256" };

let jwksServer: ReturnType<typeof Bun.serve>;
let harness: CommunityTestHarness;
let blocks: ReturnType<typeof stubBlockDirectory>;
let baseUrl: string;
let strictUrl: string;
let servers: Server[] = [];
let nonceCounter = 0;

function b64url(input: Buffer | string): string {
  return Buffer.from(input).toString("base64url");
}

interface AppleClaims {
  iss?: string;
  aud?: string;
  exp?: number;
  iat?: number;
  sub: string;
  nonce: string;
  email?: string;
}

function mintAppleToken(claims: AppleClaims, signingKey: KeyObject = privateKey, kid: string = KID): string {
  const header = b64url(JSON.stringify({ alg: "RS256", kid }));
  const payload = b64url(JSON.stringify(claims));
  const signature = cryptoSign("RSA-SHA256", Buffer.from(`${header}.${payload}`), signingKey);
  return `${header}.${payload}.${b64url(signature)}`;
}

interface TokenPair {
  accessToken: string;
  refreshToken: string;
  accountId: string;
  isNewAccount: boolean;
}

async function signInAs(sub: string, attested18Plus = true): Promise<TokenPair> {
  nonceCounter += 1;
  const nonce = `nonce-${String(nonceCounter).padStart(4, "0")}`;
  const now = Date.now();
  const claims: AppleClaims = {
    iss: APPLE_ISSUER,
    aud: SERVICES_ID,
    exp: Math.floor(now / 1000) + 600,
    iat: Math.floor(now / 1000),
    sub,
    nonce,
  };
  const res = await fetch(`${baseUrl}/v1/community/auth/apple`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ identityToken: mintAppleToken(claims), nonce, attested18Plus }),
  });
  expect(res.status).toBe(200);
  return (await res.json()) as TokenPair;
}

/** Moderator permissions come from server-owned roles; tests seed the role the way an operator would. */
async function makeModerator(sub: string): Promise<TokenPair> {
  const tokens = await signInAs(sub);
  await harness.store.accounts.doc(tokens.accountId).set({ role: "moderator" }, { merge: true });
  return tokens;
}

function publishBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    source: { recipeId: "recipes/test-rice-1", recipeRevision: "rev-000001" },
    recipe: {
      title: "Weeknight tomato rice",
      summary: "A simple tomato rice for two.",
      ingredientLines: ["200 g rice", "2 tomatoes", "1 tbsp tahini"],
      steps: ["Cook the rice.", "Fry the tomatoes, stir in the tahini, fold through the rice."],
    },
    tags: ["quick", "vegetarian"],
    campus: "campus-north",
    note: "Made this all last week.",
    declarations: { ownRights: true, noPersonalData: true },
    ...overrides,
  };
}

async function publish(url: string, tokens: TokenPair, body: Record<string, unknown>): Promise<Response> {
  return fetch(`${url}/v1/community/publications`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${tokens.accessToken}` },
    body: JSON.stringify(body),
  });
}

/** opted-in cooks map account id → the UTC day they cooked; the week window is trailing 7 UTC days. */
function todayDay(): string {
  return new Date().toISOString().slice(0, 10);
}

async function feed(tokens: TokenPair, campus: string, query = ""): Promise<Response> {
  return fetch(`${baseUrl}/v1/community/explore/${campus}${query}`, {
    headers: { authorization: `Bearer ${tokens.accessToken}` },
  });
}

interface PublicationJson {
  publicationId: string;
  revisionId: string;
  status: string;
  title: string;
  screeningFailures: ReadonlyArray<{ stage: string; reasons: readonly string[] }>;
  publishedAtIso: string | null;
}

interface FeedItem {
  publicationId: string;
  title: string;
  authorDisplayName: string | null;
  allergenTags?: readonly string[];
  cookedByCount?: number;
  rank?: { cookableNow?: boolean; matchedIngredients?: number; totalIngredients?: number; tasteTags?: readonly string[] } | null;
}

interface FeedJson {
  campus: string;
  items: FeedItem[];
  cookedThisWeekDistinctPeople?: number;
}

interface QueueItemJson {
  itemId: string;
  target: { publicationId: string; revisionId: string };
  submitter: string | null;
  reason: string;
  note: string | null;
  status: string;
  decision: string | null;
  resolvedBy: string | null;
  resolvedAt: string | null;
  audit: ReadonlyArray<{ at: string; actor: string | null; action: string; detail: string | null }>;
}

async function json(res: Response): Promise<Record<string, unknown>> {
  return (await res.json()) as Record<string, unknown>;
}

beforeAll(async () => {
  jwksServer = Bun.serve({
    port: 0,
    fetch: () => Response.json({ keys: [publicJwk] }),
  });
  harness = await makeHarness({
    appleIssuer: APPLE_ISSUER,
    appleServicesId: SERVICES_ID,
    appleJwksUrl: `http://127.0.0.1:${jwksServer.port}/auth/keys`,
    minCookedCountFloor: 2,
    minDistinctPeopleForCampusCounts: 3,
  });
  blocks = stubBlockDirectory();
  const moderation = new FirestoreModerationQueue({
    items: harness.store.moderationItems,
    publications: harness.store.publications,
    clock: harness.clock,
  });
  const base = {
    store: harness.store,
    clock: harness.clock,
    config: harness.config,
    blocks,
    moderation,
  };
  const apps: Array<{ deps: CommunityDeps; setUrl: (url: string) => void }> = [
    { deps: { ...base, screeningStages: [] }, setUrl: (u) => (baseUrl = u) },
    { deps: { ...base, screeningStages: [stubScreeningFail(["remove the branded mention"], "stub-linter")] }, setUrl: (u) => (strictUrl = u) },
  ];
  for (const { deps, setUrl } of apps) {
    const app = express();
    app.use(express.json());
    app.use(createCommunityRouter(deps, { identity: createIdentityRoutes, explore: createExploreRoutes }));
    const server = app.listen(0, "127.0.0.1");
    await new Promise<void>((resolve) => server.once("listening", resolve));
    const address = server.address();
    if (address === null || typeof address === "string") {
      throw new Error("test server did not bind");
    }
    setUrl(`http://127.0.0.1:${address.port}`);
    servers.push(server);
  }
});

afterAll(async () => {
  for (const server of servers) {
    server.close();
  }
  jwksServer.stop(true);
  await harness.close();
});

afterEach(() => {
  blocks.reset();
});

describe("publish flow", () => {
  test("a clean publication clears screening, is visible in the campus feed, and carries allergen tags", async () => {
    const alice = await signInAs("explore-alice-1");
    const res = await publish(baseUrl, alice, publishBody());
    expect(res.status).toBe(201);
    const created = (await json(res)) as unknown as PublicationJson;
    expect(created.status).toBe("published");
    expect(created.screeningFailures).toHaveLength(0);
    expect(created.publishedAtIso).not.toBeNull();

    const bob = await signInAs("explore-bob-1");
    const feedRes = await feed(bob, "campus-north");
    expect(feedRes.status).toBe(200);
    const body = (await json(feedRes)) as unknown as FeedJson;
    expect(body.campus).toBe("campus-north");
    expect(body.items).toHaveLength(1);
    const item = body.items[0] as FeedItem & { ingredientLines?: readonly string[] };
    expect(item.title).toBe("Weeknight tomato rice");
    expect(item.authorDisplayName).toBeNull();
    expect(item.allergenTags).toEqual(["allergen-sesame"]);
    expect("cookedByCount" in item).toBe(false);
    expect("cookedThisWeekDistinctPeople" in body).toBe(false);
  });

  test("an account without the 18+ attestation cannot publish", async () => {
    const teen = await signInAs("explore-teen-1", false);
    const res = await publish(baseUrl, teen, publishBody());
    expect(res.status).toBe(403);
    expect(((await json(res)) as { code: string }).code).toBe("forbidden");
  });

  test("declarations must be explicit and true; notes are single-line", async () => {
    const alice = await signInAs("explore-alice-2");
    const noRights = await publish(baseUrl, alice, publishBody({ declarations: { ownRights: false, noPersonalData: true } }));
    expect(noRights.status).toBe(422);
    const noData = await publish(baseUrl, alice, publishBody({ declarations: { ownRights: true } }));
    expect(noData.status).toBe(422);
    const multiline = await publish(baseUrl, alice, publishBody({ note: "line one\nline two" }));
    expect(multiline.status).toBe(422);
    expect(((await json(multiline)) as { code: string }).code).toBe("validation");
  });

  test("contact details fail text hygiene into the queue, not the feed", async () => {
    const carol = await signInAs("explore-carol-1");
    const res = await publish(baseUrl, carol, publishBody({
      source: { recipeId: "recipes/test-soup-1", recipeRevision: "rev-000002" },
      recipe: { title: "Cheap soup", ingredientLines: ["1 l water", "3 carrots"], steps: ["Simmer for 20 minutes.", "Email me at chef@example.com for the full trick."] },
    }));
    expect(res.status).toBe(201);
    const created = (await json(res)) as unknown as PublicationJson;
    expect(created.status).toBe("queued");
    expect(created.screeningFailures[0]?.stage).toBe("text-hygiene");
    expect(created.screeningFailures[0]?.reasons.join(" ")).toContain("email address");

    const bob = await signInAs("explore-bob-2");
    const feedRes = await feed(bob, "campus-north");
    const body = (await json(feedRes)) as unknown as FeedJson;
    expect(body.items.map((i) => i.title)).not.toContain("Cheap soup");
  });

  test("an author can withdraw; a withdrawal is a tombstone and idempotent", async () => {
    const alice = await signInAs("explore-alice-3");
    const res = await publish(baseUrl, alice, publishBody({
      source: { recipeId: "recipes/test-stew-1", recipeRevision: "rev-000003" },
      recipe: { title: "Withdrawn stew", ingredientLines: ["400 g beef"], steps: ["Stew it."] },
      campus: "withdraw-test",
    }));
    const created = (await json(res)) as unknown as PublicationJson;

    const bob = await signInAs("explore-bob-3");
    const other = await publish(baseUrl, bob, publishBody({
      source: { recipeId: "recipes/test-stew-2", recipeRevision: "rev-000004" },
      recipe: { title: "Bob stew", ingredientLines: ["300 g beef"], steps: ["Stew it too."] },
      campus: "withdraw-test",
    }));
    expect(other.status).toBe(201);

    const forbidden = await fetch(`${baseUrl}/v1/community/publications/${created.publicationId}`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${bob.accessToken}` },
    });
    expect(forbidden.status).toBe(403);

    const gone = await fetch(`${baseUrl}/v1/community/publications/${created.publicationId}`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${alice.accessToken}` },
    });
    expect(gone.status).toBe(204);
    const again = await fetch(`${baseUrl}/v1/community/publications/${created.publicationId}`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${alice.accessToken}` },
    });
    expect(again.status).toBe(204);

    const viewer = await fetch(`${baseUrl}/v1/community/publications/${created.publicationId}`, {
      headers: { authorization: `Bearer ${bob.accessToken}` },
    });
    expect(viewer.status).toBe(404);
    const mine = await fetch(`${baseUrl}/v1/community/publications/mine`, {
      headers: { authorization: `Bearer ${alice.accessToken}` },
    });
    const mineBody = (await json(mine)) as { items: Array<{ publicationId: string; status: string }> };
    expect(mineBody.items.find((i) => i.publicationId === created.publicationId)?.status).toBe("withdrawn");

    const bobFeed = (await json(await feed(bob, "withdraw-test"))) as unknown as FeedJson;
    expect(bobFeed.items.map((i) => i.title)).toEqual(["Bob stew"]);
  });
});

describe("explore feed floors and ranking", () => {
  test("cookedByCount appears only at or above the distinct-cook floor", async () => {
    const alice = await signInAs("explore-alice-4");
    const low = await publish(baseUrl, alice, publishBody({
      source: { recipeId: "recipes/test-low-1", recipeRevision: "rev-000005" },
      recipe: { title: "One cook salad", ingredientLines: ["1 cucumber"], steps: ["Slice."] },
      campus: "floor-test",
    }));
    const high = await publish(baseUrl, alice, publishBody({
      source: { recipeId: "recipes/test-high-1", recipeRevision: "rev-000006" },
      recipe: { title: "Two cook salad", ingredientLines: ["2 cucumbers"], steps: ["Slice both."] },
      campus: "floor-test",
    }));
    const lowPub = (await json(low)) as unknown as PublicationJson;
    const highPub = (await json(high)) as unknown as PublicationJson;
    const bob = await signInAs("explore-bob-4");
    const carol = await signInAs("explore-carol-4");

    await harness.store.publications.doc(lowPub.publicationId).update({ optedInCooks: { [bob.accountId]: todayDay() } });
    await harness.store.publications.doc(highPub.publicationId).update({ optedInCooks: { [bob.accountId]: todayDay(), [carol.accountId]: todayDay() } });

    const body = (await json(await feed(bob, "floor-test"))) as unknown as FeedJson;
    expect(body.items).toHaveLength(2);
    const byTitle = new Map(body.items.map((i) => [i.title as string, i]));
    expect("cookedByCount" in (byTitle.get("One cook salad") as FeedItem)).toBe(false);
    expect((byTitle.get("Two cook salad") as FeedItem).cookedByCount).toBe(2);

    const direct = await fetch(`${baseUrl}/v1/community/publications/${lowPub.publicationId}`, {
      headers: { authorization: `Bearer ${carol.accessToken}` },
    });
    expect(direct.status).toBe(200);
    expect("cookedByCount" in ((await json(direct)) as FeedItem)).toBe(false);
  });

  test("the campus weekly counter appears only at or above the distinct-people floor", async () => {
    const alice = await signInAs("explore-alice-5");
    const carol = await signInAs("explore-carol-5");
    const dave = await signInAs("explore-dave-5");
    const first = (await json(await publish(baseUrl, alice, publishBody({
      source: { recipeId: "recipes/test-count-1", recipeRevision: "rev-000007" },
      recipe: { title: "Counter one", ingredientLines: ["1 potato"], steps: ["Boil."] },
      campus: "counter-test",
    })))) as unknown as PublicationJson;
    const second = (await json(await publish(baseUrl, carol, publishBody({
      source: { recipeId: "recipes/test-count-2", recipeRevision: "rev-000008" },
      recipe: { title: "Counter two", ingredientLines: ["2 potatoes"], steps: ["Boil both."] },
      campus: "counter-test",
    })))) as unknown as PublicationJson;
    const bob = await signInAs("explore-bob-5");

    await harness.store.publications.doc(first.publicationId).update({ optedInCooks: { [bob.accountId]: todayDay() } });
    await harness.store.publications.doc(second.publicationId).update({ optedInCooks: { [carol.accountId]: todayDay() } });

    const below = (await json(await feed(bob, "counter-test"))) as unknown as FeedJson;
    expect("cookedThisWeekDistinctPeople" in below).toBe(false);

    await harness.store.publications.doc(second.publicationId).update({ optedInCooks: { [carol.accountId]: todayDay(), [dave.accountId]: todayDay() } });
    const above = (await json(await feed(bob, "counter-test"))) as unknown as FeedJson;
    expect(above.cookedThisWeekDistinctPeople).toBe(3);
  });

  test("the feed ranks by what the viewer can cook now, then taste, then newest; rank fields match the query", async () => {
    const alice = await signInAs("explore-alice-6");
    const carol = await signInAs("explore-carol-6");
    await publish(baseUrl, alice, publishBody({
      source: { recipeId: "recipes/test-stew-3", recipeRevision: "rev-000009" },
      recipe: { title: "Rich beef stew", ingredientLines: ["500 g beef", "3 carrots", "4 potatoes"], steps: ["Brown, then stew."] },
      tags: ["hearty"],
      campus: "rank-test",
    }));
    await publish(baseUrl, carol, publishBody({
      source: { recipeId: "recipes/test-rice-2", recipeRevision: "rev-000010" },
      recipe: { title: "Quick tomato rice", ingredientLines: ["200 g rice", "2 tomatoes"], steps: ["Cook, fold."] },
      tags: ["quick", "vegetarian"],
      campus: "rank-test",
    }));
    const bob = await signInAs("explore-bob-6");

    const plain = (await json(await feed(bob, "rank-test"))) as unknown as FeedJson;
    expect(plain.items.map((i) => i.title)).toEqual(["Quick tomato rice", "Rich beef stew"]);
    expect("rank" in (plain.items[0] as FeedItem)).toBe(false);

    const have = (await json(await feed(bob, "rank-test", "?have=rice")) as unknown as FeedJson);
    expect(have.items.map((i) => i.title)).toEqual(["Quick tomato rice", "Rich beef stew"]);
    const riceRank = (have.items[0] as FeedItem).rank;
    expect(riceRank?.cookableNow).toBe(false);
    expect(riceRank?.matchedIngredients).toBe(1);
    expect(riceRank?.totalIngredients).toBe(2);
    expect("tasteTags" in (riceRank ?? {})).toBe(false);
    expect((have.items[1] as FeedItem).rank?.cookableNow).toBe(false);

    const both = (await json(await feed(bob, "rank-test", "?have=rice&have=tomatoes"))) as unknown as FeedJson;
    expect((both.items[0] as FeedItem).title).toBe("Quick tomato rice");
    expect((both.items[0] as FeedItem).rank?.cookableNow).toBe(true);

    const taste = (await json(await feed(bob, "rank-test", "?tastes=vegetarian"))) as unknown as FeedJson;
    const tasteRank = (taste.items[0] as FeedItem).rank;
    expect(tasteRank?.tasteTags).toEqual(["vegetarian"]);
  });
});

describe("blocked pairs", () => {
  test("a blocked author's publications are invisible in the feed and behind a 403 on direct fetch", async () => {
    const alice = await signInAs("explore-alice-7");
    const bob = await signInAs("explore-bob-7");
    const carol = await signInAs("explore-carol-7");
    const pub = (await json(await publish(baseUrl, alice, publishBody({
      source: { recipeId: "recipes/test-block-1", recipeRevision: "rev-000011" },
      recipe: { title: "Blocked stew", ingredientLines: ["1 beet"], steps: ["Roast."] },
      campus: "block-test",
    })))) as unknown as PublicationJson;

    blocks.block(bob.accountId, alice.accountId);

    const bobFeed = (await json(await feed(bob, "block-test"))) as unknown as FeedJson;
    expect(bobFeed.items).toHaveLength(0);
    const carolFeed = (await json(await feed(carol, "block-test"))) as unknown as FeedJson;
    expect(carolFeed.items.map((i) => i.title)).toEqual(["Blocked stew"]);

    const direct = await fetch(`${baseUrl}/v1/community/publications/${pub.publicationId}`, {
      headers: { authorization: `Bearer ${bob.accessToken}` },
    });
    expect(direct.status).toBe(403);
    expect(((await json(direct)) as { code: string }).code).toBe("forbidden");

    const aliceFeed = (await json(await feed(alice, "block-test"))) as unknown as FeedJson;
    expect(aliceFeed.items.map((i) => i.title)).toEqual(["Blocked stew"]);
  });
});

describe("screening queue and moderation", () => {
  test("a failing optional stage queues the publication and an approval makes it live", async () => {
    const dave = await signInAs("explore-dave-8");
    const res = await publish(strictUrl, dave, publishBody({
      source: { recipeId: "recipes/test-strict-1", recipeRevision: "rev-000012" },
      recipe: { title: "Branded stir fry", ingredientLines: ["200 g rice", "soy sauce"], steps: ["Fry everything."] },
      campus: "queue-test",
    }));
    expect(res.status).toBe(201);
    const created = (await json(res)) as unknown as PublicationJson;
    expect(created.status).toBe("queued");
    expect(created.screeningFailures.map((f) => f.stage)).toContain("stub-linter");

    const bob = await signInAs("explore-bob-8");
    const before = (await json(await feed(bob, "queue-test"))) as unknown as FeedJson;
    expect(before.items).toHaveLength(0);

    const mod = await makeModerator("explore-mod-1");
    const queueRes = await fetch(`${baseUrl}/v1/community/moderation/queue`, {
      headers: { authorization: `Bearer ${mod.accessToken}` },
    });
    expect(queueRes.status).toBe(200);
    const queue = (await json(queueRes)) as { items: QueueItemJson[] };
    const item = queue.items.find((i) => i.target.publicationId === created.publicationId);
    expect(item).toBeDefined();
    expect(item?.reason).toBe("automated-screening");
    expect(item?.note ?? "").toContain("stub-linter");

    const resolveRes = await fetch(`${baseUrl}/v1/community/moderation/items/${item?.itemId}/resolve`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${mod.accessToken}` },
      body: JSON.stringify({ decision: "approved", note: "Branded mention removed by author on call." }),
    });
    expect(resolveRes.status).toBe(200);
    const resolved = (await json(resolveRes)) as unknown as QueueItemJson;
    expect(resolved.status).toBe("resolved");
    expect(resolved.decision).toBe("approved");

    const after = (await json(await feed(bob, "queue-test"))) as unknown as FeedJson;
    expect(after.items.map((i) => i.title)).toEqual(["Branded stir fry"]);
  });

  test("a rejection keeps the publication hidden; the author sees the status", async () => {
    const eve = await signInAs("explore-eve-8");
    const res = await publish(strictUrl, eve, publishBody({
      source: { recipeId: "recipes/test-strict-2", recipeRevision: "rev-000013" },
      recipe: { title: "Spam promo", ingredientLines: ["1 l cola"], steps: ["Mix."] },
      campus: "queue-test",
    }));
    const created = (await json(res)) as unknown as PublicationJson;
    expect(created.status).toBe("queued");

    const mod = await makeModerator("explore-mod-2");
    const queue = (await json(await fetch(`${baseUrl}/v1/community/moderation/queue`, {
      headers: { authorization: `Bearer ${mod.accessToken}` },
    }))) as { items: QueueItemJson[] };
    const item = queue.items.find((i) => i.target.publicationId === created.publicationId);
    expect(item).toBeDefined();

    const resolved = await fetch(`${baseUrl}/v1/community/moderation/items/${item?.itemId}/resolve`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${mod.accessToken}` },
      body: JSON.stringify({ decision: "rejected", note: "Promotional content" }),
    });
    expect(resolved.status).toBe(200);

    const bob = await signInAs("explore-bob-9");
    const bobFeed = (await json(await feed(bob, "queue-test"))) as unknown as FeedJson;
    expect(bobFeed.items.map((i) => i.title)).not.toContain("Spam promo");

    const mine = await fetch(`${baseUrl}/v1/community/publications/${created.publicationId}`, {
      headers: { authorization: `Bearer ${eve.accessToken}` },
    });
    expect(mine.status).toBe(200);
    expect(((await json(mine)) as unknown as PublicationJson).status).toBe("rejected");
  });

  test("the queue keeps an audit trail; a second decision is a 409; non-moderators are 403", async () => {
    const mod = await makeModerator("explore-mod-3");
    const queue = (await json(await fetch(`${baseUrl}/v1/community/moderation/queue?status=resolved`, {
      headers: { authorization: `Bearer ${mod.accessToken}` },
    }))) as { items: QueueItemJson[] };
    expect(queue.items.length).toBeGreaterThanOrEqual(2);
    const item = queue.items[0] as QueueItemJson;
    expect(item.audit.length).toBeGreaterThanOrEqual(2);
    expect(item.audit[0]?.action).toBe("submitted:automated-screening");
    expect(item.audit[item.audit.length - 1]?.action).toBe(`decision:${item.decision}`);
    expect(item.audit[item.audit.length - 1]?.actor).toBe(item.resolvedBy);
    expect(typeof item.audit[item.audit.length - 1]?.at).toBe("string");

    const replay = await fetch(`${baseUrl}/v1/community/moderation/items/${item.itemId}/resolve`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${mod.accessToken}` },
      body: JSON.stringify({ decision: "rejected" }),
    });
    expect(replay.status).toBe(409);
    expect(((await json(replay)) as { code: string }).code).toBe("conflict");

    const bob = await signInAs("explore-bob-10");
    const forbidden = await fetch(`${baseUrl}/v1/community/moderation/queue`, {
      headers: { authorization: `Bearer ${bob.accessToken}` },
    });
    expect(forbidden.status).toBe(403);
    const forbiddenResolve = await fetch(`${baseUrl}/v1/community/moderation/items/${item.itemId}/resolve`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${bob.accessToken}` },
      body: JSON.stringify({ decision: "approved" }),
    });
    expect(forbiddenResolve.status).toBe(403);
  });
});

describe("boundaries", () => {
  test("routes require an account; ids and query values validate through the module envelope", async () => {
    const noAuth = await fetch(`${baseUrl}/v1/community/publications`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(publishBody()),
    });
    expect(noAuth.status).toBe(401);
    expect(((await json(noAuth)) as { code: string }).code).toBe("unauthorized");

    const noAuthFeed = await fetch(`${baseUrl}/v1/community/explore/campus-north`);
    expect(noAuthFeed.status).toBe(401);

    const alice = await signInAs("explore-alice-11");
    const badLimit = await feed(alice, "campus-north", "?limit=abc");
    expect(badLimit.status).toBe(422);
    expect(((await json(badLimit)) as { code: string }).code).toBe("validation");

    const badCampus = await feed(alice, "campus_north");
    expect(badCampus.status).toBe(422);

    const badId = await fetch(`${baseUrl}/v1/community/publications/pub_nope`, {
      headers: { authorization: `Bearer ${alice.accessToken}` },
    });
    expect(badId.status).toBe(422);

    const missing = await fetch(`${baseUrl}/v1/community/publications/pub_${randomUUID()}`, {
      headers: { authorization: `Bearer ${alice.accessToken}` },
    });
    expect(missing.status).toBe(404);
    expect(((await json(missing)) as { code: string }).code).toBe("not_found");
  });
});
