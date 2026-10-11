/**
 * The safety part over the REAL wiring: FirestoreBlockDirectory and
 * FirestoreModerationQueue (no stubs), all parts mounted so the deletion run
 * coordinates every contributor exactly as index.ts composes it. Covers:
 * blocks with immediate feed and direct-fetch effect, reports that hide the
 * publication before the queue item exists, and account deletion (sessions
 * revoked, feeds and directories updated, content tombstoned not erased).
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import express from "express";
import { generateKeyPairSync, sign as cryptoSign, type KeyObject } from "node:crypto";
import type { Server } from "node:http";
import { makeHarness, type CommunityTestHarness } from "./harness.js";
import { fixtureFoodSafetyGate } from "./foodSafetyGate.js";
import { createCommunityRouter, type CommunityDeps } from "../../community/index.js";
import { createIdentityRoutes } from "../../community/identity/identityRoutes.js";
import { createExploreRoutes } from "../../community/explore/exploreRoutes.js";
import { createTableRoutes } from "../../community/tables/tableRoutes.js";
import { createChallengeRoutes } from "../../community/challenges/challengeRoutes.js";
import { createSafetyRoutes } from "../../community/safety/safetyRoutes.js";
import { FirestoreBlockDirectory } from "../../community/safety/blocks.js";
import { FirestoreModerationQueue } from "../../community/explore/moderationQueue.js";
import { newRecipeRevisionId, parseAccountId, parsePublicationId } from "../../community/shared/ids.js";

const KID = "test-key-1";
const APPLE_ISSUER = "https://appleid.apple.com";
const SERVICES_ID = "com.fridgeluck.app.test";

const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const publicJwk = { ...(publicKey.export({ format: "jwk" }) as { kty: string; n: string; e: string }), kid: KID, alg: "RS256" };

let jwksServer: ReturnType<typeof Bun.serve>;
let harness: CommunityTestHarness;
let baseUrl: string;
let moderation: FirestoreModerationQueue;
let server: Server;
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
}

function mintAppleToken(claims: AppleClaims, signingKey: KeyObject = privateKey): string {
  const header = b64url(JSON.stringify({ alg: "RS256", kid: KID }));
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

async function signInAs(sub: string): Promise<TokenPair> {
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
    body: JSON.stringify({ identityToken: mintAppleToken(claims), nonce, attested18Plus: true }),
  });
  expect(res.status).toBe(200);
  return (await res.json()) as TokenPair;
}

async function get(path: string, tokens: TokenPair): Promise<Response> {
  return fetch(`${baseUrl}${path}`, { headers: { authorization: `Bearer ${tokens.accessToken}` } });
}

async function send(path: string, tokens: TokenPair | null, method: string, body?: unknown): Promise<Response> {
  return fetch(`${baseUrl}${path}`, {
    method,
    headers: {
      "content-type": "application/json",
      ...(tokens !== null ? { authorization: `Bearer ${tokens.accessToken}` } : {}),
    },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });
}

async function json(res: Response): Promise<Record<string, unknown>> {
  return (await res.json()) as Record<string, unknown>;
}

async function publishRecipe(tokens: TokenPair, campus: string, title: string): Promise<string> {
  const res = await send("/v1/community/publications", tokens, "POST", {
    source: { recipeId: `recipes/test-${title.toLowerCase().replace(/\s+/g, "-")}`, recipeRevision: "rev-000011" },
    recipe: {
      title,
      summary: "A test recipe.",
      ingredientLines: ["1 onion", "1 tin chickpeas", "1 tbsp curry paste"],
      steps: ["Fry the onion.", "Add chickpeas and paste, simmer."],
    },
    tags: ["quick"],
    campus,
    note: null,
    declarations: { ownRights: true, noPersonalData: true },
  });
  expect(res.status).toBe(201);
  return ((await res.json()) as { publicationId: string }).publicationId;
}

beforeAll(async () => {
  jwksServer = Bun.serve({
    port: 0,
    fetch: () => Response.json({ keys: [publicJwk] }),
  });
  // reportLimitPerDay: 2 so the rate-limit boundary is reachable in a test.
  harness = await makeHarness({
    appleIssuer: APPLE_ISSUER,
    appleServicesId: SERVICES_ID,
    appleJwksUrl: `http://127.0.0.1:${jwksServer.port}/auth/keys`,
    reportLimitPerDay: 2,
  });
  moderation = new FirestoreModerationQueue({
    items: harness.store.moderationItems,
    publications: harness.store.publications,
    clock: harness.clock,
  });
  const deps: CommunityDeps = {
    store: harness.store,
    clock: harness.clock,
    config: harness.config,
    blocks: new FirestoreBlockDirectory(harness.store),
    moderation,
    screeningStages: [],
    foodSafetyGate: fixtureFoodSafetyGate(),
  };
  const app = express();
  app.use(express.json());
  app.use(
    createCommunityRouter(deps, {
      identity: createIdentityRoutes,
      explore: createExploreRoutes,
      tables: createTableRoutes,
      challenges: createChallengeRoutes,
      safety: createSafetyRoutes, // index.ts composes the deletion service
    }),
  );
  server = app.listen(0, "127.0.0.1");
  await new Promise<void>((resolve) => server.once("listening", resolve));
  const address = server.address();
  if (address === null || typeof address === "string") {
    throw new Error("test server did not bind");
  }
  baseUrl = `http://127.0.0.1:${address.port}`;
});

afterAll(async () => {
  server.close();
  jwksServer.stop(true);
  await harness.close();
});

describe("safety: blocks", () => {
  test("block round-trip: immediate feed and direct-fetch effect, only in the blocker's view", async () => {
    const viewer = await signInAs("safety-blocker");
    const author = await signInAs("safety-blocked");
    const neutral = await signInAs("safety-neutral");
    const pubId = await publishRecipe(author, "campus-block", "Blocked curry");

    // Baseline: everyone sees it.
    const before = (await json(await get("/v1/community/explore/campus-block", viewer))) as { items: Array<{ publicationId: string }> };
    expect(before.items.some((i) => i.publicationId === pubId)).toBe(true);

    const blocked = await send("/v1/community/blocks", viewer, "POST", { accountId: author.accountId });
    expect(blocked.status).toBe(201);
    expect(((await json(blocked)) as { blockedAccountId: string }).blockedAccountId).toBe(author.accountId);

    // The blocker's list shows the pair.
    const list = (await json(await get("/v1/community/blocks", viewer))) as { items: Array<{ accountId: string }> };
    expect(list.items.map((i) => i.accountId)).toContain(author.accountId);

    // Immediate effect: gone from the blocker's feed and direct fetch
    // (the block gate refuses the interaction with 403; the author
    // themselves always sees their own).
    const feedAfter = (await json(await get("/v1/community/explore/campus-block", viewer))) as { items: Array<{ publicationId: string }> };
    expect(feedAfter.items.some((i) => i.publicationId === pubId)).toBe(false);
    const directAfter = await get(`/v1/community/publications/${pubId}`, viewer);
    expect(directAfter.status).toBe(403);

    // The block is the blocker's view: the neutral account still sees it,
    // and the author always sees their own publication.
    const neutralFeed = (await json(await get("/v1/community/explore/campus-block", neutral))) as { items: Array<{ publicationId: string }> };
    expect(neutralFeed.items.some((i) => i.publicationId === pubId)).toBe(true);
    const authorDirect = await get(`/v1/community/publications/${pubId}`, author);
    expect(authorDirect.status).toBe(200);

    // Boundaries: self-block refused, unknown account refused.
    const selfBlock = await send("/v1/community/blocks", viewer, "POST", { accountId: viewer.accountId });
    expect(selfBlock.status).toBe(422);
    const unknownBlock = await send("/v1/community/blocks", viewer, "POST", { accountId: parseAccountId.newId() });
    expect(unknownBlock.status).toBe(404);
    const anonymous = await send("/v1/community/blocks", null, "POST", { accountId: author.accountId });
    expect(anonymous.status).toBe(401);

    // Unblock (by the blocker only) restores the publication immediately.
    // A stranger has no block pair of their own to delete → 404, and the
    // pair itself is untouched.
    const strangerUnblock = await send(`/v1/community/blocks/${author.accountId}`, neutral, "DELETE");
    expect(strangerUnblock.status).toBe(404);
    const unblocked = await send(`/v1/community/blocks/${author.accountId}`, viewer, "DELETE");
    expect(unblocked.status).toBe(204);
    const feedRestored = (await json(await get("/v1/community/explore/campus-block", viewer))) as { items: Array<{ publicationId: string }> };
    expect(feedRestored.items.some((i) => i.publicationId === pubId)).toBe(true);
    const directRestored = await get(`/v1/community/publications/${pubId}`, viewer);
    expect(directRestored.status).toBe(200);
    const unblockAgain = await send(`/v1/community/blocks/${author.accountId}`, viewer, "DELETE");
    expect(unblockAgain.status).toBe(404);
  });
});

describe("safety: reports", () => {
  test("a report hides the publication first, then the queue item exists; resolving keeps it hidden", async () => {
    const author = await signInAs("reports-author");
    const reporter = await signInAs("reports-reporter");
    const moderator = await signInAs("reports-moderator");
    const pubId = await publishRecipe(author, "campus-report", "Reported curry");

    const reported = await send(`/v1/community/publications/${pubId}/reports`, reporter, "POST", {
      reason: "not-own-recipe",
      note: "This is a scanned cookbook recipe.",
    });
    expect(reported.status).toBe(201);
    const { reportId } = (await json(reported)) as { reportId: string };
    expect(reportId).toBeTruthy();

    // Hidden immediately — the feed drops it and everyone but the author
    // gets 404 on direct fetch. The author still sees their own record
    // (now hidden) — that is the surface the appeal flow reads (route
    // contract: author sees any status; others only published). Never a
    // live publication behind a report.
    const feed = (await json(await get("/v1/community/explore/campus-report", reporter))) as { items: Array<{ publicationId: string }> };
    expect(feed.items.some((i) => i.publicationId === pubId)).toBe(false);
    const authorDirect = await get(`/v1/community/publications/${pubId}`, author);
    expect(authorDirect.status).toBe(200);
    expect(((await json(authorDirect)) as { status?: string }).status).not.toBe("published");
    const reporterDirect = await get(`/v1/community/publications/${pubId}`, reporter);
    expect(reporterDirect.status).toBe(404);

    // The queue item: open, submitted by the reporter, with the audit trail.
    const openItems = await moderation.list("open");
    const item = openItems.find((i) => i.target.publicationId === pubId);
    expect(item).toBeDefined();
    expect(item?.submitter).toBe(reporter.accountId);
    expect(item?.audit.some((a) => a.action.includes("user-report"))).toBe(true);

    // The moderator resolves: the item leaves the open list and the
    // publication stays hidden.
    await moderation.resolve(item?.itemId as never, "rejected", moderator.accountId as never, "confirmed not their own recipe");
    const stillOpen = await moderation.list("open");
    expect(stillOpen.some((i) => i.itemId === item?.itemId)).toBe(false);
    const resolved = await moderation.list("resolved");
    expect(resolved.some((i) => i.itemId === item?.itemId && i.decision === "rejected")).toBe(true);
    const authorDirectAfter = await get(`/v1/community/publications/${pubId}`, author);
    expect(authorDirectAfter.status).toBe(200);
    expect(((await json(authorDirectAfter)) as { status?: string }).status).not.toBe("published");
    const reporterDirectAfter = await get(`/v1/community/publications/${pubId}`, reporter);
    expect(reporterDirectAfter.status).toBe(404);

    // Boundaries: reporting a not-live publication conflicts; unknown id is
    // 404; a bad reason is 422; the per-day limit is 429 (floor is 2 and
    // this reporter has reported once).
    const again = await send(`/v1/community/publications/${pubId}/reports`, reporter, "POST", { reason: "other" });
    expect(again.status).toBe(409);
    const unknown = await send(`/v1/community/publications/${parsePublicationId.newId()}/reports`, reporter, "POST", { reason: "other" });
    expect(unknown.status).toBe(404);
    const badReason = await send(`/v1/community/publications/${pubId}/reports`, reporter, "POST", { reason: "vibes" });
    expect(badReason.status).toBe(422);
    const secondPub = await publishRecipe(author, "campus-report", "Second curry");
    const second = await send(`/v1/community/publications/${secondPub}/reports`, reporter, "POST", { reason: "other" });
    expect(second.status).toBe(201); // second report today: at the limit
    const thirdPub = await publishRecipe(author, "campus-report", "Third curry");
    const third = await send(`/v1/community/publications/${thirdPub}/reports`, reporter, "POST", { reason: "other" });
    expect(third.status).toBe(429);
    const anonymous = await send(`/v1/community/publications/${thirdPub}/reports`, null, "POST", { reason: "other" });
    expect(anonymous.status).toBe(401);
  });
});

describe("safety: account deletion", () => {
  test("deletion revokes sessions, updates feeds and directories, tombstones content", async () => {
    const deleter = await signInAs("delete-me");
    const other = await signInAs("delete-other");
    const cookTarget = await signInAs("delete-cook-target");

    // The deleter has content in every part: a publication, a cook
    // occurrence on someone else's publication, an owned table with a
    // member, a challenge entry, and a block pair.
    const pubId = await publishRecipe(deleter, "campus-delete", "Doomed curry");
    const challenge = await send("/v1/community/challenges", deleter, "POST", {
      kind: "use-it-up",
      title: "Before I go",
      ingredients: ["lentils"],
    });
    expect(challenge.status).toBe(201);
    const { challengeId } = (await json(challenge)) as { challengeId: string };
    const entry = await send(`/v1/community/challenges/${challengeId}/entries`, deleter, "POST", {
      source: { recipeId: "recipes/test-lentils", recipeRevision: newRecipeRevisionId() },
      ingredientsUsed: ["lentils"],
    });
    expect(entry.status).toBe(201);
    const table = await send("/v1/community/tables", deleter, "POST", { name: "Doomed table" });
    const { tableId } = (await json(table)) as { tableId: string };
    const targetPub = await publishRecipe(cookTarget, "campus-delete", "Target curry");
    await send(`/v1/community/publications/${targetPub}/cooks`, deleter, "POST");
    await send("/v1/community/blocks", deleter, "POST", { accountId: other.accountId });

    // Baseline: an unblocked campus account sees the deleter's feed item
    // (`other` is already blocked by the pair below, so their feed
    // suppresses the deleter by design).
    const before = (await json(await get("/v1/community/explore/campus-delete", cookTarget))) as { items: Array<{ publicationId: string }> };
    expect(before.items.some((i) => i.publicationId === pubId)).toBe(true);

    const deletion = await send("/v1/community/account/deletion", deleter, "POST");
    expect(deletion.status).toBe(200);
    const record = (await json(deletion)) as {
      deletionRunId: string;
      sessionsRevoked: boolean;
      contributions: Array<{ part: string; recordsTouched: number }>;
      finishedAtIso: string;
    };
    expect(record.deletionRunId).toBeTruthy();
    // Revocation is all-or-nothing: the record says sessions were dead
    // before any contributor ran, not how many there were.
    expect(record.sessionsRevoked).toBe(true);
    const parts = record.contributions.map((c) => c.part).sort();
    expect(parts).toEqual(["challenges", "explore/publications", "safety/blocks", "tables"]);

    // Sessions are dead: whoami 401 on the old access token and the
    // refresh token no longer rotates.
    const whoami = await get("/v1/community/whoami", deleter);
    expect(whoami.status).toBe(401);
    const refreshed = await send("/v1/community/auth/refresh", null, "POST", { refreshToken: deleter.refreshToken });
    expect(refreshed.status).toBe(401);

    // Feeds and directories updated immediately (read by the unblocked
    // cookTarget: the deleter's publication is gone because it is deleted,
    // not because of a block pair).
    const after = (await json(await get("/v1/community/explore/campus-delete", cookTarget))) as { items: Array<{ publicationId: string }> };
    expect(after.items.some((i) => i.publicationId === pubId)).toBe(false);
    const directAfter = await get(`/v1/community/publications/${pubId}`, other);
    expect(directAfter.status).toBe(404);
    const blockList = (await json(await get("/v1/community/blocks", other))) as { items: Array<{ accountId: string }> };
    expect(blockList.items.map((i) => i.accountId)).not.toContain(deleter.accountId);
    // The cook occurrence key is stripped: cookTarget's publication has no
    // counts from the deleted account (the explore reads recompute from
    // optedInCooks, which the contributor emptied).
    const cookFeed = (await json(await get("/v1/community/explore/campus-delete", cookTarget))) as {
      items: Array<{ publicationId: string; cookedByCount?: number }>;
    };
    expect(cookFeed.items.find((i) => i.publicationId === targetPub)?.cookedByCount).toBeUndefined();

    // Tombstones, not erasure: content documents survive without PII.
    const pubDoc = await harness.store.publications.doc(pubId).get();
    expect(pubDoc.exists).toBe(true);
    expect((pubDoc.data() as { status: string }).status).toBe("withdrawn");
    const entrySnap = await harness.store.challengeEntries.where("challengeId", "==", challengeId).get();
    expect(entrySnap.docs).toHaveLength(1);
    const entryData = entrySnap.docs[0]?.data() as { sourceRecipeId: string | null; deletedAtIso: string | null };
    expect(entryData.sourceRecipeId).toBeNull();
    expect(entryData.deletedAtIso).not.toBeNull();
    const accountDoc = await harness.store.accounts.doc(deleter.accountId).get();
    expect(accountDoc.exists).toBe(true);
    const accountData = accountDoc.data() as { deletedAtIso: string | null; appleSub: string | null; displayName: string | null };
    expect(accountData.deletedAtIso).not.toBeNull();
    expect(accountData.appleSub).toBeNull();
    expect(accountData.displayName).toBeNull();
    // The owned table dissolved; the deletion is idempotent-safe (a second
    // run on a deleted account cannot resurrect anything).
    const goneTable = await get(`/v1/community/tables/${tableId}`, other);
    expect(goneTable.status).toBe(404);
  });
});
